//! Sources and the cache: artwork.py's `read_local`, `read_avatar`,
//! `prepare` and `prepare_avatar`. Files are read as bounded snapshots;
//! thumbnails are staged in a private job directory and renamed into the
//! cache, which keeps at most `MAX_CACHE` thumbnails.

use std::ffi::{OsStr, OsString};
use std::fs::{self, File};
use std::io::{self, ErrorKind, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use foamy_helper::lock::FileLock;
use rustix::fs::{FileType, Mode, OFlags};
use rustix::process::getuid;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{Fail, MAX_AVATAR_INPUT, MAX_INPUT, fetch, image, state, url};

const MAX_CACHE: usize = 16;
const NAME_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789_";

/// `str(pathlib.Path(text))`: repeated and trailing slashes and `.`
/// components dropped, a leading `//` (exactly two) kept.
fn pathlib(text: &[u8]) -> PathBuf {
    let root: &[u8] = if text.starts_with(b"//") && !text.starts_with(b"///") {
        b"//"
    } else if text.starts_with(b"/") {
        b"/"
    } else {
        b""
    };
    let parts: Vec<&[u8]> = text
        .split(|&b| b == b'/')
        .filter(|p| !p.is_empty() && *p != b".")
        .collect();
    let mut out = root.to_vec();
    out.extend_from_slice(&parts.join(&b'/'));
    if out.is_empty() {
        out.push(b'.');
    }
    PathBuf::from(OsString::from_vec(out))
}

/// `$XDG_CACHE_HOME/omarchy/foamy.lock`, or `$HOME/.cache/…` when
/// `XDG_CACHE_HOME` is unset or empty (Python's `Path.home()`: `HOME`, else
/// the passwd entry).
fn lock_cache() -> PathBuf {
    let base = match std::env::var_os("XDG_CACHE_HOME").filter(|v| !v.is_empty()) {
        Some(base) => base.into_vec(),
        None => {
            let mut home = std::env::home_dir()
                .unwrap_or_default()
                .into_os_string()
                .into_vec();
            home.extend_from_slice(b"/.cache");
            home
        }
    };
    let mut path = base;
    path.extend_from_slice(b"/omarchy/foamy.lock");
    pathlib(&path)
}

/// `Path.mkdir(mode, parents=True, exist_ok=True)`: missing parents with
/// the default mode, an existing directory (also through a symlink) is fine.
fn make_dirs(path: &Path, mode: u32) -> io::Result<()> {
    match rustix::fs::mkdir(path, Mode::from_raw_mode(mode)) {
        Ok(()) => Ok(()),
        Err(error) if error == rustix::io::Errno::NOENT => {
            match path.parent() {
                Some(parent) if parent != path && !parent.as_os_str().is_empty() => {
                    make_dirs(parent, 0o777)?
                }
                _ => return Err(error.into()),
            }
            match rustix::fs::mkdir(path, Mode::from_raw_mode(mode)) {
                Ok(()) => Ok(()),
                Err(_) if path.is_dir() => Ok(()),
                Err(error) => Err(error.into()),
            }
        }
        Err(_) if path.is_dir() => Ok(()),
        Err(error) => Err(error.into()),
    }
}

/// The cache directory after `make_dirs`: a real directory (not a
/// symlink), owned by this user, and for artwork without group or other
/// access.
fn checked_dir(path: &Path, private: bool) -> Result<(), Fail> {
    make_dirs(path, 0o700)?;
    let meta = fs::symlink_metadata(path)?;
    if !meta.file_type().is_dir()
        || meta.uid() != getuid().as_raw()
        || (private && meta.mode() & 0o077 != 0)
    {
        return Err(Fail("unsafe-cache"));
    }
    Ok(())
}

fn random_name(prefix: &str) -> io::Result<String> {
    let mut bytes = [0u8; 8];
    let mut filled = 0;
    while filled < bytes.len() {
        filled +=
            rustix::rand::getrandom(&mut bytes[filled..], rustix::rand::GetRandomFlags::empty())?;
    }
    let mut name = prefix.to_string();
    name.extend(
        bytes
            .iter()
            .map(|&b| NAME_CHARS[b as usize % NAME_CHARS.len()] as char),
    );
    Ok(name)
}

fn absolute(path: &Path) -> io::Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

/// A private job directory (`tempfile.TemporaryDirectory(prefix, dir)`):
/// mode 0700, eight random characters from `[a-z0-9_]`. It is registered
/// with the cancel handler, which removes it if the job is cancelled, and
/// it is removed when dropped. Writes into it and renames out of it hold
/// the same lock, so a cancel never races them.
pub struct Staging {
    path: Option<PathBuf>,
}

impl Staging {
    fn create(parent: &Path, prefix: &str) -> Result<Staging, Fail> {
        let parent = absolute(parent)?;
        let mut guard = state();
        for _ in 0..1000 {
            let path = parent.join(random_name(prefix)?);
            match fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => {
                    guard.staging = Some(path.clone());
                    return Ok(Staging { path: Some(path) });
                }
                Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        }
        Err(Fail("source-unavailable"))
    }

    fn path(&self) -> &Path {
        self.path.as_deref().expect("staging directory in use")
    }

    /// Writes a new file (`O_EXCL`, no symlinks, mode 0600) in the job
    /// directory and returns its path.
    pub fn write(&self, name: &str, data: &[u8]) -> Result<PathBuf, Fail> {
        let path = self.path().join(name);
        let _guard = state();
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        file.write_all(data)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        Ok(path)
    }

    /// Writes `data` as `name` in the job directory and renames it to
    /// `target` (`os.replace`).
    fn publish(&self, name: &str, data: &[u8], target: &Path) -> Result<(), Fail> {
        let staged = self.write(name, data)?;
        let _guard = state();
        fs::rename(&staged, target)?;
        Ok(())
    }

    /// Removes the job directory; an error is the job's error (as Python's
    /// `TemporaryDirectory` cleanup).
    fn finish(mut self) -> Result<(), Fail> {
        let path = self.path.take().expect("staging directory in use");
        let mut guard = state();
        guard.staging = None;
        fs::remove_dir_all(&path)?;
        Ok(())
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let mut guard = state();
            guard.staging = None;
            let _ = fs::remove_dir_all(&path);
        }
    }
}

fn matches_staging(name: &OsStr, prefix: &str) -> bool {
    let name = name.as_bytes();
    name.len() == prefix.len() + 8
        && name.starts_with(prefix.as_bytes())
        && name[prefix.len()..].iter().all(|b| NAME_CHARS.contains(b))
}

fn is_thumbnail_name(name: &OsStr) -> bool {
    let name = name.as_bytes();
    name.len() == 68
        && name.ends_with(b".png")
        && name[..64]
            .iter()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Opens `name` under `dir` with `flags` and `O_NOFOLLOW`.
fn open_at(dir: &OwnedFd, name: &str, flags: OFlags) -> io::Result<OwnedFd> {
    Ok(rustix::fs::openat(
        dir,
        name,
        flags | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?)
}

/// Reads a snapshot of an open file: a regular file (owned by this user
/// when `owned`) of at most `limit` bytes.
fn snapshot(
    fd: OwnedFd,
    limit: usize,
    owned: bool,
    not_regular: &'static str,
) -> Result<Vec<u8>, Fail> {
    let stat = rustix::fs::fstat(&fd)?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile
        || (owned && stat.st_uid != getuid().as_raw())
    {
        return Err(Fail(not_regular));
    }
    if stat.st_size as u64 > limit as u64 {
        return Err(Fail("input-too-large"));
    }
    let mut data = Vec::new();
    File::from(fd)
        .take(limit as u64 + 1)
        .read_to_end(&mut data)?;
    if data.len() > limit {
        return Err(Fail("input-too-large"));
    }
    Ok(data)
}

/// artwork.py's `read_local`: the URL path must lie under one of `roots`
/// (normalised like `os.path.abspath`); the file is opened by walking from
/// the root with `O_NOFOLLOW` descriptors, so no symlink or special file
/// can escape the root during the open.
fn read_local(parts: &url::Parsed, roots: &[String]) -> Result<Vec<u8>, Fail> {
    let path = url::unquote(&parts.split.path).map_err(|_| Fail("source-unavailable"))?;
    if !path.starts_with('/') || path.contains('\0') || path.split('/').any(|p| p == "..") {
        return Err(Fail("invalid-file-path"));
    }
    for root in roots {
        let root = url::normpath(root);
        let trimmed = root.trim_end_matches('/');
        let prefix = format!("{trimmed}/");
        if !path.starts_with(&prefix) {
            continue;
        }
        let mut dir = rustix::fs::open(
            root.as_str(),
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )?;
        let pieces: Vec<&str> = path[prefix.len()..].split('/').collect();
        let (last, parents) = pieces.split_last().expect("split yields one piece");
        for piece in parents {
            dir = open_at(&dir, piece, OFlags::RDONLY | OFlags::DIRECTORY)?;
        }
        let source = open_at(&dir, last, OFlags::RDONLY | OFlags::NONBLOCK)?;
        // Python's fdopen refuses a directory before the type check.
        if FileType::from_raw_mode(rustix::fs::fstat(&source)?.st_mode) == FileType::Directory {
            return Err(Fail("source-unavailable"));
        }
        return snapshot(source, MAX_INPUT, true, "not-owned-regular-file");
    }
    Err(Fail("file-outside-roots"))
}

/// artwork.py's `read_avatar`: the account picture from the user's own
/// AccountsService record or ~/.face, so symlinks and root-owned icons are
/// allowed; special files and inputs over `MAX_AVATAR_INPUT` are not.
fn read_avatar(path: Option<&Value>) -> Result<Vec<u8>, Fail> {
    let path = match path {
        Some(Value::String(path))
            if path.starts_with('/') && path.chars().count() <= 4096 && !path.contains('\0') =>
        {
            path
        }
        _ => return Err(Fail("invalid-avatar-path")),
    };
    let fd = match rustix::fs::open(
        path.as_str(),
        OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(fd) => fd,
        Err(rustix::io::Errno::NOENT) => return Err(Fail("avatar-missing")),
        Err(error) => return Err(io::Error::from(error).into()),
    };
    snapshot(fd, MAX_AVATAR_INPUT, false, "not-regular-file")
}

/// One label of `HOST`: 1-63 of `[a-z0-9-]`, alphanumeric at both ends,
/// and a letter first for the top label.
fn host_label(label: &str, top: bool) -> bool {
    let bytes = label.as_bytes();
    let alnum = |b: &u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    !bytes.is_empty()
        && bytes.len() <= 63
        && (if top {
            bytes[0].is_ascii_lowercase()
        } else {
            alnum(&bytes[0])
        })
        && alnum(&bytes[bytes.len() - 1])
        && bytes.iter().all(|b| alnum(b) || *b == b'-')
}

/// artwork.py's `HOST` pattern: lowercase DNS names with at least two
/// labels, a top label starting with a letter, at most 253 characters.
fn valid_host(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    !host.is_empty()
        && host.len() <= 253
        && labels.len() >= 2
        && labels[..labels.len() - 1]
            .iter()
            .all(|l| host_label(l, false))
        && host_label(labels[labels.len() - 1], true)
}

/// artwork.py's `validate_options`.
fn options(request: &serde_json::Map<String, Value>) -> Result<(Vec<String>, Vec<String>), Fail> {
    let strings = |key: &str,
                   max: usize,
                   valid: &dyn Fn(&str) -> bool,
                   code: &'static str|
     -> Result<Vec<String>, Fail> {
        match request.get(key) {
            None => Ok(Vec::new()),
            Some(Value::Array(items)) if items.len() <= max => items
                .iter()
                .map(|item| {
                    item.as_str()
                        .filter(|s| valid(s))
                        .map(str::to_string)
                        .ok_or(Fail(code))
                })
                .collect(),
            Some(_) => Err(Fail(code)),
        }
    };
    let hosts = strings("hosts", 32, &valid_host, "invalid-hosts")?;
    let valid_root = |p: &str| {
        p.starts_with('/')
            && p.chars().count() <= 4096
            && !p.contains('\0')
            && p != "/"
            && !p.split('/').any(|c| c == "..")
    };
    let roots = strings("roots", 16, &valid_root, "invalid-roots")?;
    Ok((hosts, roots))
}

fn reclaim_jobs(cache: &Path) -> Result<(), Fail> {
    for entry in fs::read_dir(cache)? {
        let entry = entry?;
        if matches_staging(&entry.file_name(), ".job-") && !entry.file_type()?.is_symlink() {
            fs::remove_dir_all(entry.path())?;
        }
    }
    Ok(())
}

fn prune(cache: &Path) -> Result<(), Fail> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(cache)? {
        let entry = entry?;
        if is_thumbnail_name(&entry.file_name()) {
            let meta = fs::symlink_metadata(entry.path())?;
            entries.push(((meta.mtime(), meta.mtime_nsec()), entry.path()));
        }
    }
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (_, path) in entries.iter().skip(MAX_CACHE) {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// artwork.py's `prepare`: a media artwork thumbnail in
/// `<cache>/artwork/<sha256>.png`.
pub fn prepare(request: &serde_json::Map<String, Value>) -> Result<Value, Fail> {
    let (hosts, roots) = options(request)?;
    let url_text = match request.get("url") {
        Some(Value::String(text)) => text.as_str(),
        _ => return Err(Fail("invalid-url")),
    };
    let parts = url::parse(url_text)?;
    let https = parts.scheme() == "https";
    if https && !parts.hostname.as_ref().is_some_and(|h| hosts.contains(h)) {
        return Err(Fail("host-not-allowed"));
    }
    let data = if https {
        fetch::fetch(url_text, &hosts)?
    } else {
        read_local(&parts, &roots)?
    };
    let cache = lock_cache().join("artwork");
    checked_dir(&cache, true)?;
    let _lock = FileLock::try_exclusive(&cache.join(".lock"))?.ok_or(Fail("cache-busy"))?;
    // A forced kill cannot clean up; the lock lets the next job reclaim
    // only abandoned job directories.
    reclaim_jobs(&cache)?;
    // Disk data is never trusted output: each job decodes anew.
    let staging = Staging::create(&cache, ".job-")?;
    let encoded = image::encode_png(&image::decode(&data, &staging)?)?;
    let name = format!("{:x}.png", Sha256::digest(&encoded));
    let target = cache.join(&name);
    staging.publish("thumbnail.png", &encoded, &target)?;
    staging.finish()?;
    prune(&cache)?;
    Ok(json!({"ok": true, "path": path_text(&target)}))
}

/// artwork.py's `prepare_avatar`: the account picture as
/// `<cache>/avatar.png`.
pub fn prepare_avatar(request: &serde_json::Map<String, Value>) -> Result<Value, Fail> {
    let data = read_avatar(request.get("path"))?;
    let directory = lock_cache();
    checked_dir(&directory, false)?;
    // One avatar job runs at a time; a killed job leaves its staging
    // directory, reclaimed once it is clearly abandoned.
    for entry in fs::read_dir(&directory)?.flatten() {
        let Ok(meta) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        let old = SystemTime::now()
            .duration_since(meta.modified().unwrap_or(SystemTime::now()))
            .is_ok_and(|age| age > Duration::from_secs(60));
        if matches_staging(&entry.file_name(), ".avatar-") && meta.file_type().is_dir() && old {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
    let staging = Staging::create(&directory, ".avatar-")?;
    let encoded = image::encode_png(&image::decode(&data, &staging)?)?;
    let target = directory.join("avatar.png");
    staging.publish("avatar.png", &encoded, &target)?;
    staging.finish()?;
    Ok(json!({"ok": true, "path": path_text(&target)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_normalise_like_pathlib() {
        for (text, path) in [
            ("/a//b/./c/", "/a/b/c"),
            ("//a/b", "//a/b"),
            ("///a", "/a"),
            ("rel/./x", "rel/x"),
            ("", "."),
        ] {
            assert_eq!(pathlib(text.as_bytes()), Path::new(path), "{text}");
        }
    }

    #[test]
    fn hosts_follow_the_pattern() {
        for good in [
            "images.example.com",
            "a.b",
            "x1.y",
            "a-b.c-d",
            &format!("{}.com", "a".repeat(63)),
        ] {
            assert!(valid_host(good), "{good}");
        }
        for bad in [
            "localhost",
            "127.0.0.1",
            "EXAMPLE.COM",
            "*.example.com",
            "a..b",
            ".a.b",
            "a.b.",
            "-a.b",
            "a-.b",
            "a.1b",
            "a.b-",
            &format!("{}.com", "a".repeat(64)),
            &format!("{}com", "x.".repeat(126)),
            "a.b\n",
            "é.com",
        ] {
            assert!(!valid_host(bad), "{bad}");
        }
    }

    #[test]
    fn staging_and_thumbnail_names() {
        assert!(matches_staging(OsStr::new(".job-abc_0123"), ".job-"));
        assert!(!matches_staging(OsStr::new(".job-ABCDEFGH"), ".job-"));
        assert!(!matches_staging(OsStr::new(".job-abc"), ".job-"));
        assert!(matches_staging(
            OsStr::new(&random_name(".avatar-").unwrap()),
            ".avatar-"
        ));
        assert!(is_thumbnail_name(OsStr::new(&format!(
            "{}.png",
            "0f".repeat(32)
        ))));
        assert!(!is_thumbnail_name(OsStr::new(&format!(
            "{}.png",
            "0F".repeat(32)
        ))));
        assert!(!is_thumbnail_name(OsStr::new("a.png")));
    }
}
