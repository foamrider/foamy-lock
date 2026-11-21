//! `studio login-screen status`: whether Lock Studio shows its login-screen
//! section, and in which state. Read-only: no stdin, nothing written.
//!
//! Reply (exit 0): `{"ok": true, "state": <state>, "theme": <effective
//! [Theme] Current, "" when unset>, "themeSetIn": <the file that set it, as
//! the system sees it ("/etc/sddm.conf.d/10-theme.conf"), or null>,
//! "themeDir": <the folder SDDM looks for themes in, see below>,
//! "autologin": <[Autologin] User is set>, "installed": {"plugin": …,
//! "hash": …} | null}`, plus `"reason"` for `unavailable` and `"detail"`
//! (English) for `broken`.
//!
//! - `unavailable` (`reason`): `not-sddm` when
//!   `/etc/systemd/system/display-manager.service` isn't a symlink to an
//!   `sddm.service` (the alias `systemctl enable` makes), `greeter-missing`
//!   when `/usr/bin/sddm-greeter-qt6` isn't an executable file. Nothing
//!   else is read, so `theme` is `""`, `themeSetIn` null, `themeDir`
//!   SDDM's default and `autologin` false.
//! - `not-installed`: no theme folder, and the effective theme isn't ours.
//! - `installed`: the folder is complete and the effective theme is ours.
//! - `overridden`: the folder is complete, but SDDM uses another theme.
//! - `broken`: the effective theme is ours and the folder is missing or
//!   incomplete, or the folder exists and is incomplete.
//!
//! The folder is `foamy-lock` in the effective `[Theme] ThemeDir`, read
//! from the same files, with the same precedence and parsing as `Current`.
//! Unset, it is SDDM's default `/usr/share/sddm/themes`. SDDM 0.21 uses the
//! value as it is (`ConfigEntry<QString>::setValue` only trims it), and
//! `Display::findGreeterTheme` looks for the theme with
//! `QDir(ThemeDir).exists(Current)`
//! (<https://github.com/sddm/sddm/blob/v0.21.0/src/daemon/Display.cpp>,
//! lines 334-351). So an empty or relative value is not the default: Qt
//! resolves it against the daemon's working folder, which is `/` for a
//! systemd service without `WorkingDirectory=` (SDDM's `sddm.service` sets
//! none). `themeDir` reports the folder as SDDM resolves it: an empty value
//! is `/`, a relative one is joined onto `/`.
//!
//! The folder is complete when its `manifest.json` (written by the
//! publisher from `stage`'s manifest) is valid and each file it lists is a
//! regular file of the listed size. The files aren't hashed. Nothing in the
//! folder is followed through a symlink: a symlinked folder (the theme
//! folder or one inside it), manifest or file makes it `broken`. The
//! folders above it (`ThemeDir` itself) are followed, as SDDM does.
//! `installed` is set only for `installed` and `overridden`.
//!
//! A read that fails other than with "not found" is `IO` (exit 1), never
//! `unavailable`: a failed check must not hide the section. So is an SDDM
//! config directory with more than [`MAX_CONFIG_FILES`] entries or a config
//! file over [`MAX_CONFIG_FILE`] bytes.
//!
//! Every system path is joined onto a root: `/`, or the absolute path in
//! `$FOAMY_LOCK_SYSTEM_ROOT` (for tests; relative or empty is ignored).

use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, ErrorKind};
use std::os::fd::OwnedFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use foamy_helper::Failure;
use rustix::fs::{AtFlags, FileType, Mode, OFlags};
use rustix::io::Errno;
use serde_json::{Map, Value, json};

/// Test override of the system root.
pub const ROOT_VAR: &str = "FOAMY_LOCK_SYSTEM_ROOT";
/// The theme name, and the folder under SDDM's theme directory.
pub const THEME: &str = "foamy-lock";
/// Entries read from one SDDM config directory.
pub const MAX_CONFIG_FILES: usize = 64;
/// Bytes read from one SDDM config file.
pub const MAX_CONFIG_FILE: u64 = 64 * 1024;
/// Bytes in the theme's `manifest.json`.
pub const MAX_MANIFEST: u64 = 64 * 1024;
/// Files a manifest lists: the bundle (`stage::MAX_BUNDLE_ENTRIES`), the
/// snapshot, the two pictures and `theme.conf`, with room to spare.
pub const MAX_MANIFEST_FILES: usize = 255;
/// Components in a manifest name (`kit/FoamyStyle.qml` has two).
pub const MAX_LEVELS: usize = 4;
const MANIFEST: &str = "manifest.json";
const MANIFEST_VERSION: u64 = 1;
const MAX_PLUGIN_VERSION: usize = 64;
const MAX_NAME: usize = 255;

const DISPLAY_MANAGER: &str = "etc/systemd/system/display-manager.service";
const GREETER: &str = "usr/bin/sddm-greeter-qt6";
/// SDDM's default `[Theme] ThemeDir` (`DATA_INSTALL_DIR "/themes"` in
/// src/common/Configuration.h, line 53).
pub const DEFAULT_THEME_DIR: &str = "/usr/share/sddm/themes";
/// SDDM 0.21's config locations, lowest precedence first (its CMake
/// defaults `SYSTEM_CONFIG_DIR`, `CONFIG_DIR`, `CONFIG_FILE`).
const SYSTEM_CONFIG_DIR: &str = "usr/lib/sddm/sddm.conf.d";
const CONFIG_DIR: &str = "etc/sddm.conf.d";
const CONFIG_FILE: &str = "etc/sddm.conf";
const LOCALE_CONF: &str = "etc/locale.conf";

/// `studio login-screen status`.
pub fn run() -> Result<Value, Failure> {
    status(&system_root(std::env::var_os(ROOT_VAR)))
}

/// The root that system paths are joined onto: `value` when absolute,
/// else `/`.
pub fn system_root(value: Option<OsString>) -> PathBuf {
    value
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// The status reply for the system under `root`.
pub fn status(root: &Path) -> Result<Value, Failure> {
    if let Some(reason) = unavailable(root)? {
        return Ok(json!({
            "ok": true, "state": "unavailable", "reason": reason,
            "theme": "", "themeSetIn": null, "themeDir": DEFAULT_THEME_DIR,
            "autologin": false, "installed": null,
        }));
    }
    let config = effective_config(root)?;
    let ours = config.theme == THEME;
    let theme_dir = config.theme_dir();
    let folder = theme_dir.join(THEME);
    let (state, installed, detail) = match theme_folder(root, &folder)? {
        Folder::Complete { plugin, hash } => (
            if ours { "installed" } else { "overridden" },
            json!({"plugin": plugin, "hash": hash}),
            None,
        ),
        Folder::Missing if !ours => ("not-installed", Value::Null, None),
        Folder::Missing => (
            "broken",
            Value::Null,
            Some(format!(
                "SDDM uses {THEME}, but {} is missing",
                folder.display()
            )),
        ),
        Folder::Incomplete(why) => ("broken", Value::Null, Some(why)),
    };
    let mut reply = json!({
        "ok": true, "state": state, "theme": config.theme,
        "themeSetIn": config.theme_set_in, "themeDir": theme_dir,
        "autologin": !config.autologin_user.is_empty(),
        "installed": installed,
    });
    if let (Some(detail), Value::Object(reply)) = (detail, &mut reply) {
        reply.insert("detail".into(), detail.into());
    }
    Ok(reply)
}

/// "Not there" as SDDM and `systemctl` see it.
fn absent(error: &io::Error) -> bool {
    matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory)
}

fn io_error(path: &Path) -> impl FnOnce(io::Error) -> Failure + '_ {
    move |error| Failure::coded("IO", format!("{}: {error}", path.display()))
}

/// The `unavailable` reason, or None when SDDM is the display manager and
/// its Qt 6 greeter is installed.
fn unavailable(root: &Path) -> Result<Option<&'static str>, Failure> {
    let unit = root.join(DISPLAY_MANAGER);
    match fs::symlink_metadata(&unit) {
        Err(error) if absent(&error) => return Ok(Some("not-sddm")),
        Err(error) => return Err(io_error(&unit)(error)),
        Ok(meta) if !meta.file_type().is_symlink() => return Ok(Some("not-sddm")),
        Ok(_) => {}
    }
    let target = fs::read_link(&unit).map_err(io_error(&unit))?;
    if target.file_name().is_none_or(|name| name != "sddm.service") {
        return Ok(Some("not-sddm"));
    }
    let greeter = root.join(GREETER);
    match fs::metadata(&greeter) {
        Err(error) if absent(&error) => Ok(Some("greeter-missing")),
        Err(error) => Err(io_error(&greeter)(error)),
        Ok(meta) if !meta.is_file() || meta.permissions().mode() & 0o111 == 0 => {
            Ok(Some("greeter-missing"))
        }
        Ok(_) => Ok(None),
    }
}

/// The SDDM settings `status` reports, as SDDM ends up with them.
#[derive(Debug, Default, PartialEq)]
pub struct Config {
    /// `[Theme] Current`.
    pub theme: String,
    /// The file whose line set `theme`, as the system sees it.
    pub theme_set_in: Option<String>,
    /// `[Autologin] User`. SDDM logs in automatically when it is set
    /// (`Display::start` in src/daemon/Display.cpp, lines 275-276).
    pub autologin_user: String,
    /// `[Theme] ThemeDir` as written, or None when no file sets it.
    pub theme_dir: Option<String>,
}

impl Config {
    /// The absolute folder SDDM looks for themes in (see the module doc):
    /// the default when unset, else the value resolved against `/`.
    pub fn theme_dir(&self) -> PathBuf {
        match &self.theme_dir {
            None => PathBuf::from(DEFAULT_THEME_DIR),
            Some(dir) => Path::new("/").join(dir),
        }
    }
}

/// Applies one config file to `config` the way SDDM 0.21's
/// `ConfigBase::loadInternal` does (src/common/ConfigReader.cpp, lines
/// 191-227, <https://github.com/sddm/sddm/blob/v0.21.0/src/common/ConfigReader.cpp>):
///
/// - lines are split at `\n`, decoded as UTF-8 (invalid bytes replaced)
///   and trimmed;
/// - everything from the first `#` on is a comment, also after a value;
///   `;` isn't a comment;
/// - a line with `=` is an assignment (even `[a=b]`): name and value are
///   trimmed, and a later assignment replaces an earlier one, an empty
///   value included. Quotes are part of the value;
/// - otherwise `[name]` starts a section; section and key names are
///   case-sensitive, and each file starts in `General`;
/// - each line is decoded with `QString::fromUtf8`, which drops a leading
///   UTF-8 byte-order mark, so a file may start with one.
pub fn apply_config(config: &mut Config, bytes: &[u8], shown: &str) {
    let text = String::from_utf8_lossy(bytes);
    let mut section = "General";
    for line in text.split('\n') {
        let line = line.trim_start_matches('\u{feff}').trim();
        let line = line.find('#').map_or(line, |at| &line[..at]).trim();
        if let Some((name, value)) = line.split_once('=') {
            match (section, name.trim()) {
                ("Theme", "Current") => {
                    config.theme = value.trim().to_string();
                    config.theme_set_in = Some(shown.to_string());
                }
                ("Theme", "ThemeDir") => config.theme_dir = Some(value.trim().to_string()),
                ("Autologin", "User") => config.autologin_user = value.trim().to_string(),
                _ => {}
            }
        } else if line.len() >= 2 && line.starts_with('[') && line.ends_with(']') {
            section = &line[1..line.len() - 1];
        }
    }
}

/// The config files SDDM 0.21 reads, lowest precedence first, relative to
/// the root. `ConfigBase::load` (ConfigReader.cpp lines 143-188) lists each
/// directory with `QDir::Files | QDir::NoDotAndDotDot` sorted by name
/// (`QDir::LocaleAware`): every file whatever its suffix (a `.pacnew` too),
/// symlinks to files included, and hidden files, directories and broken
/// symlinks left out. Then `/etc/sddm.conf`. SDDM skips a file it can't
/// open; here that is an `IO` failure, so the section never hides on a
/// guess.
///
/// The names are sorted in the daemon's collation (see [`collation`]).
fn config_files(root: &Path) -> Result<Vec<PathBuf>, Failure> {
    let collation = collation(root)?;
    let mut files = Vec::new();
    for dir in [SYSTEM_CONFIG_DIR, CONFIG_DIR] {
        let path = root.join(dir);
        let entries = match fs::read_dir(&path) {
            Err(error) if absent(&error) => continue,
            entries => entries.map_err(io_error(&path))?,
        };
        let mut names = Vec::new();
        // Bound the listing itself, not only what is kept.
        for (count, entry) in entries.enumerate() {
            if count == MAX_CONFIG_FILES {
                return Err(Failure::coded(
                    "IO",
                    format!(
                        "{} has more than {MAX_CONFIG_FILES} entries",
                        path.display()
                    ),
                ));
            }
            let name = entry.map_err(io_error(&path))?.file_name();
            if !name.as_encoded_bytes().starts_with(b".") {
                names.push(name);
            }
        }
        names.sort_by(|a, b| compare_names(collation, a.as_encoded_bytes(), b.as_encoded_bytes()));
        files.extend(names.into_iter().map(|name| Path::new(dir).join(name)));
    }
    files.push(PathBuf::from(CONFIG_FILE));
    Ok(files)
}

/// How SDDM's daemon orders the names in a config directory.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Collation {
    /// The C or POSIX locale: byte order.
    Bytes,
    /// Any other locale: Qt's `QDir::LocaleAware` through ICU.
    Root,
}

/// The daemon's collation. systemd gives services the locale in
/// `/etc/locale.conf` (`LC_COLLATE`, else `LANG`); without one they run in
/// the C locale.
fn collation(root: &Path) -> Result<Collation, Failure> {
    let path = root.join(LOCALE_CONF);
    let bytes = match File::open(&path) {
        Err(error) if absent(&error) => return Ok(Collation::Bytes),
        file => {
            let file = file.map_err(io_error(&path))?;
            foamy_helper::io::read_limited(file, MAX_CONFIG_FILE).map_err(|error| {
                if foamy_helper::io::is_over_limit(&error) {
                    Failure::coded(
                        "IO",
                        format!("{} is larger than {MAX_CONFIG_FILE} bytes", path.display()),
                    )
                } else {
                    io_error(&path)(error)
                }
            })?
        }
    };
    Ok(collation_of(&String::from_utf8_lossy(&bytes)))
}

/// The collation a `locale.conf` text selects.
pub fn collation_of(text: &str) -> Collation {
    let (mut lang, mut collate) = (None, None);
    for line in text.lines() {
        let Some((key, value)) = line.trim().split_once('=') else {
            continue;
        };
        let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
        match key.trim() {
            "LANG" => lang = Some(value.to_string()),
            "LC_COLLATE" => collate = Some(value.to_string()),
            _ => {}
        }
    }
    let locale = collate
        .filter(|v| !v.is_empty())
        .or(lang)
        .unwrap_or_default();
    let c_locale = locale.is_empty()
        || locale == "C"
        || locale == "POSIX"
        || locale.starts_with("C.")
        || locale.starts_with("C@");
    if c_locale {
        Collation::Bytes
    } else {
        Collation::Root
    }
}

/// ICU's root collation order of printable ASCII (letters folded to lower
/// case), as Qt 6.12's `QDir::LocaleAware` sorted it under `nb_NO.UTF-8` and
/// `en_US.UTF-8`: punctuation, then digits, then letters.
const ROOT_ORDER: &[u8] = b" _-,;:!?.'\"()[]{}@*\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz";

/// The primary weight of a byte: its place in [`ROOT_ORDER`], or after it.
fn primary(byte: u8) -> u16 {
    let folded = byte.to_ascii_lowercase();
    ROOT_ORDER
        .iter()
        .position(|&c| c == folded)
        .map_or(256 + u16::from(byte), |at| at as u16)
}

/// Orders two names as SDDM's daemon lists them. For ASCII names this is
/// ICU's root order: letters compare without case first, then lower case
/// before upper case. Locale tailorings (Norwegian and Danish sort "aa" as
/// "å", after "z") and non-ASCII names aren't modelled; they fall back to
/// the root order and byte values.
pub fn compare_names(collation: Collation, a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    if collation == Collation::Bytes {
        return a.cmp(b);
    }
    let tertiary = |byte: &u8| byte.is_ascii_uppercase();
    a.iter()
        .map(|&byte| primary(byte))
        .cmp(b.iter().map(|&byte| primary(byte)))
        .then_with(|| a.iter().map(tertiary).cmp(b.iter().map(tertiary)))
        .then_with(|| a.cmp(b))
}

/// `[Theme] Current` and `[Autologin] User` after every config file.
fn effective_config(root: &Path) -> Result<Config, Failure> {
    let mut config = Config::default();
    for rel in config_files(root)? {
        let path = root.join(&rel);
        // SDDM follows symlinks here and reads only regular files.
        match fs::metadata(&path) {
            Err(error) if absent(&error) => continue,
            Err(error) => return Err(io_error(&path)(error)),
            Ok(meta) if !meta.is_file() => continue,
            Ok(_) => {}
        }
        let file = File::open(&path).map_err(io_error(&path))?;
        let bytes = foamy_helper::io::read_limited(file, MAX_CONFIG_FILE).map_err(|error| {
            if foamy_helper::io::is_over_limit(&error) {
                Failure::coded(
                    "IO",
                    format!("{} is larger than {MAX_CONFIG_FILE} bytes", path.display()),
                )
            } else {
                io_error(&path)(error)
            }
        })?;
        apply_config(&mut config, &bytes, &format!("/{}", rel.display()));
    }
    Ok(config)
}

/// The installed theme folder.
#[derive(Debug, PartialEq)]
enum Folder {
    Missing,
    /// Why it is incomplete, in English.
    Incomplete(String),
    Complete {
        plugin: String,
        hash: String,
    },
}

/// A valid `manifest.json`: the plugin version, the look's hash and each
/// file's name and size.
#[derive(Debug, PartialEq)]
pub struct Manifest {
    pub plugin: String,
    pub hash: String,
    pub files: Vec<(String, u64)>,
}

fn sha256_text(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str).filter(|text| {
        text.len() == 64
            && text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

fn only_keys(object: &Map<String, Value>, keys: &[&str], what: &str) -> Result<(), String> {
    if let Some(key) = object.keys().find(|key| !keys.contains(&key.as_str())) {
        return Err(format!("{what} has an unknown key {key}"));
    }
    Ok(())
}

/// A relative path of plain components, shared by manifest names and the
/// paths in `sddm/bundle.txt`: 1 to [`MAX_LEVELS`] components separated by
/// `/`, each 1 to 255 of `[A-Za-z0-9._-]` and not starting with `.` (so
/// never `.` or `..`).
pub fn check_path(path: &str) -> Result<(), String> {
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() > MAX_LEVELS {
        return Err(format!("{path:?} has more than {MAX_LEVELS} levels"));
    }
    let plain = |part: &&str| {
        (1..=MAX_NAME).contains(&part.len())
            && !part.starts_with('.')
            && part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    };
    if !parts.iter().all(plain) {
        return Err(format!("{path:?} isn't a relative path of plain names"));
    }
    Ok(())
}

/// A manifest name: a [`check_path`] path other than the manifest.
fn check_name(name: &str) -> Result<(), String> {
    check_path(name)?;
    if name == MANIFEST {
        return Err(format!("{name:?} is the manifest itself"));
    }
    Ok(())
}

/// Checks a manifest (schema version 1, shared with `stage` and the
/// publisher): `{"version": 1, "plugin": <1-64 bytes>, "hash": <64
/// lowercase hex>, "files": [{"name", "size", "sha256"}, …]}`, at most
/// [`MAX_MANIFEST_FILES`] files with distinct [`check_path`] names. Unknown
/// keys are refused.
pub fn parse_manifest(bytes: &[u8]) -> Result<Manifest, String> {
    let manifest: Map<String, Value> = match serde_json::from_slice(bytes) {
        Ok(Value::Object(object)) => object,
        Ok(_) => return Err("the manifest isn't a JSON object".into()),
        Err(error) => return Err(format!("the manifest isn't JSON: {error}")),
    };
    only_keys(
        &manifest,
        &["version", "plugin", "hash", "files"],
        "the manifest",
    )?;
    if manifest.get("version").and_then(Value::as_u64) != Some(MANIFEST_VERSION) {
        return Err("the manifest has an unknown version".into());
    }
    let plugin = manifest
        .get("plugin")
        .and_then(Value::as_str)
        .filter(|plugin| (1..=MAX_PLUGIN_VERSION).contains(&plugin.len()))
        .ok_or("the manifest's plugin isn't a version")?;
    let hash = sha256_text(manifest.get("hash"))
        .ok_or("the manifest's hash isn't 64 lowercase hex digits")?;
    let Some(Value::Array(entries)) = manifest.get("files") else {
        return Err("the manifest's files isn't an array".into());
    };
    if entries.len() > MAX_MANIFEST_FILES {
        return Err(format!(
            "the manifest lists more than {MAX_MANIFEST_FILES} files"
        ));
    }
    let mut files: Vec<(String, u64)> = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let what = format!("files[{index}]");
        let Value::Object(entry) = entry else {
            return Err(format!("{what} isn't an object"));
        };
        only_keys(entry, &["name", "size", "sha256"], &what)?;
        let name = entry
            .get("name")
            .and_then(Value::as_str)
            .ok_or(format!("{what} has no name"))?;
        check_name(name).map_err(|reason| format!("{what}: {reason}"))?;
        let size = entry
            .get("size")
            .and_then(Value::as_u64)
            .ok_or(format!("{what} has no size"))?;
        if sha256_text(entry.get("sha256")).is_none() {
            return Err(format!("{what}'s sha256 isn't 64 lowercase hex digits"));
        }
        if files.iter().any(|(seen, _)| seen == name) {
            return Err(format!("{what}: {name} is listed twice"));
        }
        files.push((name.to_string(), size));
    }
    Ok(Manifest {
        plugin: plugin.to_string(),
        hash: hash.to_string(),
        files,
    })
}

/// The manifest's bytes, or why the folder is incomplete. The manifest
/// isn't followed through a symlink and must be a regular file.
fn read_manifest(path: &Path) -> Result<Result<Vec<u8>, String>, Failure> {
    let opened = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path);
    let file = match opened {
        Ok(file) => file,
        Err(error) if absent(&error) => return Ok(Err(format!("{MANIFEST} is missing"))),
        Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
            return Ok(Err(format!("{MANIFEST} is a symlink")));
        }
        Err(error) => return Err(io_error(path)(error)),
    };
    if !file.metadata().map_err(io_error(path))?.is_file() {
        return Ok(Err(format!("{MANIFEST} isn't a regular file")));
    }
    match foamy_helper::io::read_limited(file, MAX_MANIFEST) {
        Ok(bytes) => Ok(Ok(bytes)),
        Err(error) if foamy_helper::io::is_over_limit(&error) => Ok(Err(format!(
            "{MANIFEST} is larger than {MAX_MANIFEST} bytes"
        ))),
        Err(error) => Err(io_error(path)(error)),
    }
}

/// The theme folder at `folder` (absolute, as SDDM sees it) under `root`:
/// missing, incomplete (why) or complete.
fn theme_folder(root: &Path, folder: &Path) -> Result<Folder, Failure> {
    let shown = folder.display();
    let dir = root.join(folder.strip_prefix("/").unwrap_or(folder));
    match fs::symlink_metadata(&dir) {
        Err(error) if absent(&error) => return Ok(Folder::Missing),
        Err(error) => return Err(io_error(&dir)(error)),
        Ok(meta) if meta.file_type().is_symlink() => {
            return Ok(Folder::Incomplete(format!("{shown} is a symlink")));
        }
        Ok(meta) if !meta.is_dir() => {
            return Ok(Folder::Incomplete(format!("{shown} isn't a folder")));
        }
        Ok(_) => {}
    }
    let bytes = match read_manifest(&dir.join(MANIFEST))? {
        Ok(bytes) => bytes,
        Err(why) => return Ok(Folder::Incomplete(why)),
    };
    let manifest = match parse_manifest(&bytes) {
        Ok(manifest) => manifest,
        Err(why) => return Ok(Folder::Incomplete(why)),
    };
    // Opened without following a symlink, so a folder swapped for a link
    // after the check above can't lead outside.
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let top = match rustix::fs::open(&dir, flags, Mode::empty()) {
        Ok(fd) => fd,
        Err(Errno::LOOP | Errno::NOTDIR) => {
            return Ok(Folder::Incomplete(format!("{shown} is a symlink")));
        }
        Err(error) => return Err(io_error(&dir)(error.into())),
    };
    for (name, size) in &manifest.files {
        if let Some(why) =
            listed_file(&top, name, *size).map_err(|error| io_error(&dir.join(name))(error))?
        {
            return Ok(Folder::Incomplete(why));
        }
    }
    Ok(Folder::Complete {
        plugin: manifest.plugin,
        hash: manifest.hash,
    })
}

/// Why the listed file `name` (a [`check_path`] path) under `top` isn't a
/// regular file of `size` bytes, or None when it is. No component is
/// followed through a symlink.
fn listed_file(top: &OwnedFd, name: &str, size: u64) -> io::Result<Option<String>> {
    let parts: Vec<&str> = name.split('/').collect();
    let (last, folders) = parts.split_last().expect("split yields one piece");
    let mut owned: Option<OwnedFd> = None;
    let mut seen = String::new();
    for part in folders {
        if !seen.is_empty() {
            seen.push('/');
        }
        seen.push_str(part);
        let dir = owned.as_ref().unwrap_or(top);
        let stat = match rustix::fs::statat(dir, *part, AtFlags::SYMLINK_NOFOLLOW) {
            Err(Errno::NOENT) => return Ok(Some(format!("{name} is missing"))),
            stat => stat?,
        };
        match FileType::from_raw_mode(stat.st_mode) {
            FileType::Directory => {}
            FileType::Symlink => return Ok(Some(format!("{seen} is a symlink"))),
            _ => return Ok(Some(format!("{seen} isn't a folder"))),
        }
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        owned = Some(match rustix::fs::openat(dir, *part, flags, Mode::empty()) {
            // Changed since the stat: a symlink or a file now.
            Err(Errno::LOOP | Errno::NOTDIR) => {
                return Ok(Some(format!("{seen} isn't a folder")));
            }
            fd => fd?,
        });
    }
    let dir = owned.as_ref().unwrap_or(top);
    let stat = match rustix::fs::statat(dir, *last, AtFlags::SYMLINK_NOFOLLOW) {
        Err(Errno::NOENT) => return Ok(Some(format!("{name} is missing"))),
        stat => stat?,
    };
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Ok(Some(format!("{name} isn't a regular file")));
    }
    let len = stat.st_size as u64;
    if len != size {
        return Ok(Some(format!(
            "{name} is {len} bytes, the manifest says {size}"
        )));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::os::unix::fs::symlink;

    const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    /// Our folder in SDDM's default theme folder, relative to the root.
    const THEME_DIR: &str = "usr/share/sddm/themes/foamy-lock";

    /// A change that breaks a fake system.
    type Break<'a> = dyn Fn(&Scratch) + 'a;

    /// SDDM as the display manager, with its greeter.
    fn sddm(scratch: &Scratch) {
        fs::create_dir_all(scratch.path("etc/systemd/system")).unwrap();
        symlink(
            "/usr/lib/systemd/system/sddm.service",
            scratch.path(DISPLAY_MANAGER),
        )
        .unwrap();
        scratch.script(GREETER, "exit 0");
    }

    fn manifest(files: &[(&str, &str)]) -> String {
        let files: Vec<Value> = files
            .iter()
            .map(|(name, text)| json!({"name": name, "size": text.len(), "sha256": HASH}))
            .collect();
        json!({"version": 1, "plugin": "1.4.1", "hash": HASH, "files": files}).to_string()
    }

    /// A complete theme folder, with files in subfolders as the bundle has.
    fn theme(scratch: &Scratch) {
        theme_in(scratch, THEME_DIR);
    }

    fn theme_in(scratch: &Scratch, dir: &str) {
        let files = [
            ("Main.qml", "Item {}\n"),
            ("theme.conf", "[General]\n"),
            ("kit/FoamyStyle.qml", "QtObject {}\n"),
            ("elements/shaders/aurora.frag.qsb", "qsb"),
        ];
        for (name, text) in files {
            scratch.file(&format!("{dir}/{name}"), text);
        }
        scratch.file(&format!("{dir}/{MANIFEST}"), &manifest(&files));
    }

    fn select(scratch: &Scratch, rel: &str, theme: &str) {
        scratch.file(rel, &format!("[Theme]\nCurrent={theme}\n"));
    }

    fn omarchy(scratch: &Scratch) {
        select(scratch, "etc/sddm.conf.d/10-theme.conf", "omarchy");
    }

    fn ours(scratch: &Scratch) {
        omarchy(scratch);
        select(scratch, "etc/sddm.conf.d/50-foamy-lock.conf", THEME);
    }

    /// One fake system: its setup, and the state, the reason (unavailable)
    /// or part of the detail (broken), the theme and where it was set.
    struct Case {
        name: &'static str,
        setup: fn(&Scratch),
        state: &'static str,
        note: &'static str,
        theme: &'static str,
        set_in: Option<&'static str>,
    }

    #[test]
    fn every_state_from_a_fake_system() {
        let cases = [
            Case {
                name: "no display manager",
                setup: |_| {},
                state: "unavailable",
                note: "not-sddm",
                theme: "",
                set_in: None,
            },
            Case {
                name: "another display manager",
                setup: |s| {
                    sddm(s);
                    fs::remove_file(s.path(DISPLAY_MANAGER)).unwrap();
                    symlink(
                        "/usr/lib/systemd/system/gdm.service",
                        s.path(DISPLAY_MANAGER),
                    )
                    .unwrap();
                },
                state: "unavailable",
                note: "not-sddm",
                theme: "",
                set_in: None,
            },
            Case {
                name: "a unit file, not the alias",
                setup: |s| {
                    sddm(s);
                    fs::remove_file(s.path(DISPLAY_MANAGER)).unwrap();
                    s.file(DISPLAY_MANAGER, "[Unit]\n");
                },
                state: "unavailable",
                note: "not-sddm",
                theme: "",
                set_in: None,
            },
            Case {
                name: "no greeter",
                setup: |s| {
                    sddm(s);
                    fs::remove_file(s.path(GREETER)).unwrap();
                    ours(s);
                },
                state: "unavailable",
                note: "greeter-missing",
                theme: "",
                set_in: None,
            },
            Case {
                name: "a greeter that isn't executable",
                setup: |s| {
                    sddm(s);
                    fs::set_permissions(s.path(GREETER), fs::Permissions::from_mode(0o644))
                        .unwrap();
                },
                state: "unavailable",
                note: "greeter-missing",
                theme: "",
                set_in: None,
            },
            Case {
                name: "a greeter that is a folder",
                setup: |s| {
                    sddm(s);
                    fs::remove_file(s.path(GREETER)).unwrap();
                    fs::create_dir(s.path(GREETER)).unwrap();
                },
                state: "unavailable",
                note: "greeter-missing",
                theme: "",
                set_in: None,
            },
            Case {
                name: "Omarchy's theme",
                setup: |s| {
                    sddm(s);
                    omarchy(s);
                },
                state: "not-installed",
                note: "",
                theme: "omarchy",
                set_in: Some("/etc/sddm.conf.d/10-theme.conf"),
            },
            Case {
                name: "no config at all",
                setup: sddm,
                state: "not-installed",
                note: "",
                theme: "",
                set_in: None,
            },
            Case {
                name: "installed",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                },
                state: "installed",
                note: "",
                theme: THEME,
                set_in: Some("/etc/sddm.conf.d/50-foamy-lock.conf"),
            },
            Case {
                name: "installed, not selected",
                setup: |s| {
                    sddm(s);
                    omarchy(s);
                    theme(s);
                },
                state: "overridden",
                note: "",
                theme: "omarchy",
                set_in: Some("/etc/sddm.conf.d/10-theme.conf"),
            },
            Case {
                name: "/etc/sddm.conf wins",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                    select(s, CONFIG_FILE, "breeze");
                },
                state: "overridden",
                note: "",
                theme: "breeze",
                set_in: Some("/etc/sddm.conf"),
            },
            Case {
                name: "a later drop-in wins",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                    select(s, "etc/sddm.conf.d/60-other.conf", "breeze");
                },
                state: "overridden",
                note: "",
                theme: "breeze",
                set_in: Some("/etc/sddm.conf.d/60-other.conf"),
            },
            Case {
                name: "an earlier drop-in loses",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                    select(s, "etc/sddm.conf.d/05-other.conf", "breeze");
                },
                state: "installed",
                note: "",
                theme: THEME,
                set_in: Some("/etc/sddm.conf.d/50-foamy-lock.conf"),
            },
            Case {
                name: "a .pacnew file is read too",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                    select(s, "etc/sddm.conf.d/50-foamy-lock.conf.pacnew", "omarchy");
                },
                state: "overridden",
                note: "",
                theme: "omarchy",
                set_in: Some("/etc/sddm.conf.d/50-foamy-lock.conf.pacnew"),
            },
            Case {
                name: "hidden files, folders and broken symlinks are not read",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                    select(s, "etc/sddm.conf.d/.99-hidden.conf", "omarchy");
                    select(s, "etc/sddm.conf.d/98-folder.conf/x", "omarchy");
                    symlink("/nowhere", s.path("etc/sddm.conf.d/97-broken.conf")).unwrap();
                },
                state: "installed",
                note: "",
                theme: THEME,
                set_in: Some("/etc/sddm.conf.d/50-foamy-lock.conf"),
            },
            Case {
                name: "a symlinked drop-in is followed",
                setup: |s| {
                    sddm(s);
                    ours(s);
                    theme(s);
                    select(s, "elsewhere.conf", "breeze");
                    symlink(
                        s.path("elsewhere.conf"),
                        s.path("etc/sddm.conf.d/70-link.conf"),
                    )
                    .unwrap();
                },
                state: "overridden",
                note: "",
                theme: "breeze",
                set_in: Some("/etc/sddm.conf.d/70-link.conf"),
            },
            Case {
                name: "/etc/sddm.conf.d wins over /usr/lib/sddm/sddm.conf.d",
                setup: |s| {
                    sddm(s);
                    theme(s);
                    select(s, "usr/lib/sddm/sddm.conf.d/99-vendor.conf", THEME);
                    select(s, "etc/sddm.conf.d/00-admin.conf", "breeze");
                },
                state: "overridden",
                note: "",
                theme: "breeze",
                set_in: Some("/etc/sddm.conf.d/00-admin.conf"),
            },
            Case {
                name: "selected in /usr/lib only, no folder",
                setup: |s| {
                    sddm(s);
                    select(s, "usr/lib/sddm/sddm.conf.d/99-vendor.conf", THEME);
                },
                state: "broken",
                note: "is missing",
                theme: THEME,
                set_in: Some("/usr/lib/sddm/sddm.conf.d/99-vendor.conf"),
            },
            Case {
                name: "selected, no folder",
                setup: |s| {
                    sddm(s);
                    ours(s);
                },
                state: "broken",
                note: "is missing",
                theme: THEME,
                set_in: Some("/etc/sddm.conf.d/50-foamy-lock.conf"),
            },
            Case {
                name: "an incomplete folder, not selected",
                setup: |s| {
                    sddm(s);
                    omarchy(s);
                    theme(s);
                    fs::remove_file(s.path(&format!("{THEME_DIR}/Main.qml"))).unwrap();
                },
                state: "broken",
                note: "Main.qml is missing",
                theme: "omarchy",
                set_in: Some("/etc/sddm.conf.d/10-theme.conf"),
            },
        ];
        for case in &cases {
            let name = case.name;
            let scratch = Scratch::new("login-status");
            (case.setup)(&scratch);
            let reply = status(&scratch.0).unwrap_or_else(|failure| panic!("{name}: {failure}"));
            assert_eq!(reply["ok"], json!(true), "{name}");
            assert_eq!(reply["state"], json!(case.state), "{name}: {reply}");
            assert_eq!(reply["theme"], json!(case.theme), "{name}: {reply}");
            assert_eq!(reply["themeSetIn"], json!(case.set_in), "{name}: {reply}");
            assert_eq!(
                reply["themeDir"],
                json!(DEFAULT_THEME_DIR),
                "{name}: {reply}"
            );
            match case.state {
                "unavailable" => assert_eq!(reply["reason"], json!(case.note), "{name}"),
                "broken" => assert!(
                    reply["detail"].as_str().unwrap().contains(case.note),
                    "{name}: {reply}"
                ),
                _ => assert!(
                    reply.get("reason").is_none() && reply.get("detail").is_none(),
                    "{name}: {reply}"
                ),
            }
            let installed = if matches!(case.state, "installed" | "overridden") {
                json!({"plugin": "1.4.1", "hash": HASH})
            } else {
                Value::Null
            };
            assert_eq!(reply["installed"], installed, "{name}");
        }
    }

    #[test]
    fn config_lines_are_read_as_sddm_reads_them() {
        // (file text, theme, autologin user)
        let cases: &[(&str, &str, &str)] = &[
            ("[Theme]\nCurrent=foamy-lock\n", "foamy-lock", ""),
            ("[Theme]\nCurrent = foamy-lock # chosen\n", "foamy-lock", ""),
            ("[Theme]\n#Current=omarchy\n", "", ""),
            ("[Theme]\nCurrent=\"foamy-lock\"\n", "\"foamy-lock\"", ""),
            ("[Theme]\nCurrent=a\nCurrent=b\n", "b", ""),
            ("[Theme]\nCurrent=a\nCurrent=\n", "", ""),
            ("[theme]\nCurrent=a\n", "", ""),
            ("[Theme]\ncurrent=a\n", "", ""),
            ("Current=a\n", "", ""),
            ("  [Theme]  \r\n\tCurrent=a\r\n", "a", ""),
            ("[Theme] # the theme\nCurrent=a\n", "a", ""),
            ("[Theme]\n; Current=a\n", "", ""),
            ("[Theme]\nCurrent=a;b\n", "a;b", ""),
            ("[Theme]\n[General]\nCurrent=a\n", "", ""),
            (
                "[Autologin]\nUser=tomas\nSession=omarchy.desktop\n",
                "",
                "tomas",
            ),
            ("[Autologin]\nUser=tomas\nUser=\n", "", ""),
            ("[Autologin]\n#User=tomas\n", "", ""),
            ("[Theme]\nCurrent=\u{d8}st\n", "\u{d8}st", ""),
            ("\u{feff}[Theme]\nCurrent=breeze\n", "breeze", ""),
        ];
        for (text, theme, user) in cases {
            let mut config = Config::default();
            apply_config(&mut config, text.as_bytes(), "/x.conf");
            assert_eq!(
                (config.theme.as_str(), config.autologin_user.as_str()),
                (*theme, *user),
                "{text:?}"
            );
        }
        // Each file starts in [General]; a later file keeps what it doesn't set.
        let mut config = Config::default();
        apply_config(&mut config, b"[Theme]\nCurrent=a\n", "/a.conf");
        apply_config(&mut config, b"Current=b\n[Autologin]\nUser=me\n", "/b.conf");
        assert_eq!(
            config,
            Config {
                theme: "a".into(),
                theme_set_in: Some("/a.conf".into()),
                autologin_user: "me".into(),
                theme_dir: None,
            }
        );
        // Invalid UTF-8 doesn't stop the file.
        let mut config = Config::default();
        apply_config(&mut config, b"\xff\n[Theme]\nCurrent=a\n", "/c.conf");
        assert_eq!(config.theme, "a");
    }

    #[test]
    fn names_sort_as_sddm_lists_them() {
        // The orders Qt 6.12's QDir::LocaleAware gave for these files.
        let names = [
            "10-theme.conf",
            "100-x.conf",
            "5.conf",
            "50_override.conf",
            "50-foamy-lock.conf",
            "50-Z.conf",
            "50.conf",
            "50.x.conf",
            "50+x.conf",
            "50~x.conf",
            "50a.conf",
            "50A.conf",
            "9-x.conf",
        ];
        let c_order = [
            "10-theme.conf",
            "100-x.conf",
            "5.conf",
            "50+x.conf",
            "50-Z.conf",
            "50-foamy-lock.conf",
            "50.conf",
            "50.x.conf",
            "50A.conf",
            "50_override.conf",
            "50a.conf",
            "50~x.conf",
            "9-x.conf",
        ];
        let ties = ["a_B", "a-b", "a-B", "A-b", "ab", "aB", "Ab"];
        for (collation, input, expected) in [
            (Collation::Root, &names[..], &names[..]),
            (Collation::Bytes, &names[..], &c_order[..]),
            (Collation::Root, &ties[..], &ties[..]),
        ] {
            let mut sorted = input.to_vec();
            sorted.reverse();
            sorted.sort_by(|a, b| compare_names(collation, a.as_bytes(), b.as_bytes()));
            assert_eq!(sorted, expected, "{collation:?}");
        }
        for (text, collation) in [
            ("", Collation::Bytes),
            ("LANG=C.UTF-8\n", Collation::Bytes),
            ("LANG=POSIX\n", Collation::Bytes),
            ("LANG=nb_NO.UTF-8\n", Collation::Root),
            ("LANG=\"en_US.UTF-8\"\n", Collation::Root),
            ("LANG=nb_NO.UTF-8\nLC_COLLATE=C\n", Collation::Bytes),
            ("LANG=C\nLC_COLLATE=nb_NO.UTF-8\n", Collation::Root),
        ] {
            assert_eq!(collation_of(text), collation, "{text:?}");
        }
        // The locale decides which of two drop-ins wins.
        for (locale, state, effective) in [
            ("LANG=nb_NO.UTF-8\n", "installed", THEME),
            ("LANG=C.UTF-8\n", "overridden", "omarchy"),
        ] {
            let scratch = Scratch::new("login-status-order");
            sddm(&scratch);
            theme(&scratch);
            select(&scratch, "etc/sddm.conf.d/50-foamy-lock.conf", THEME);
            select(&scratch, "etc/sddm.conf.d/50_override.conf", "omarchy");
            scratch.file(LOCALE_CONF, locale);
            let reply = status(&scratch.0).unwrap();
            assert_eq!(reply["state"], state, "{locale}");
            assert_eq!(reply["theme"], effective, "{locale}");
        }
    }

    #[test]
    fn autologin_follows_the_effective_user() {
        let scratch = Scratch::new("login-autologin");
        sddm(&scratch);
        omarchy(&scratch);
        assert_eq!(status(&scratch.0).unwrap()["autologin"], json!(false));
        scratch.file(
            "etc/sddm.conf.d/autologin.conf",
            "[Autologin]\nUser=tomas\nSession=omarchy.desktop\n",
        );
        assert_eq!(status(&scratch.0).unwrap()["autologin"], json!(true));
        scratch.file(CONFIG_FILE, "[Autologin]\nUser=\n");
        assert_eq!(status(&scratch.0).unwrap()["autologin"], json!(false));
    }

    #[test]
    fn manifests_are_checked() {
        let good = || {
            json!({"version": 1, "plugin": "1.4.1", "hash": HASH,
                   "files": [{"name": "Main.qml", "size": 3, "sha256": HASH}]})
        };
        assert_eq!(
            parse_manifest(good().to_string().as_bytes()),
            Ok(Manifest {
                plugin: "1.4.1".into(),
                hash: HASH.into(),
                files: vec![("Main.qml".into(), 3)],
            })
        );
        let with = |edit: fn(&mut Value)| {
            let mut manifest = good();
            edit(&mut manifest);
            manifest.to_string()
        };
        let bad = [
            "not json".to_string(),
            "[]".into(),
            with(|m| m["version"] = json!(2)),
            with(|m| m["extra"] = json!(1)),
            with(|m| m["plugin"] = json!("")),
            with(|m| m["plugin"] = json!("1".repeat(65))),
            with(|m| m["hash"] = json!(HASH.to_uppercase())),
            with(|m| m["hash"] = json!(&HASH[1..])),
            with(|m| m["files"] = json!({})),
            with(|m| m["files"][0]["name"] = json!("..")),
            with(|m| m["files"][0]["name"] = json!("a/b/c/d/e.qml")),
            with(|m| m["files"][0]["name"] = json!("/Main.qml")),
            with(|m| m["files"][0]["name"] = json!("kit/")),
            with(|m| m["files"][0]["name"] = json!("kit//a.qml")),
            with(|m| m["files"][0]["name"] = json!("kit/../Main.qml")),
            with(|m| m["files"][0]["name"] = json!("kit/./Main.qml")),
            with(|m| m["files"][0]["name"] = json!(".hidden")),
            with(|m| m["files"][0]["name"] = json!("kit/.x.qml")),
            with(|m| m["files"][0]["name"] = json!("a b.qml")),
            with(|m| m["files"][0]["name"] = json!("kit\\a.qml")),
            with(|m| m["files"][0]["name"] = json!("\u{e5}.qml")),
            with(|m| m["files"][0]["name"] = json!("x".repeat(256))),
            with(|m| m["files"][0]["name"] = json!(".")),
            with(|m| m["files"][0]["name"] = json!("")),
            with(|m| m["files"][0]["name"] = json!("a\u{0}b")),
            with(|m| m["files"][0]["name"] = json!(MANIFEST)),
            with(|m| m["files"][0]["size"] = json!(-1)),
            with(|m| m["files"][0]["size"] = json!("3")),
            with(|m| m["files"][0]["sha256"] = json!("x")),
            with(|m| m["files"][0]["mode"] = json!(420)),
            with(|m| {
                let entry = m["files"][0].clone();
                m["files"].as_array_mut().unwrap().push(entry);
            }),
            with(|m| {
                m["files"] = (0..=MAX_MANIFEST_FILES)
                    .map(|i| json!({"name": format!("f{i}"), "size": 0, "sha256": HASH}))
                    .collect();
            }),
        ];
        for text in bad {
            assert!(parse_manifest(text.as_bytes()).is_err(), "{text}");
        }
        // Nested names of up to four levels, and as many files as allowed.
        let nested = with(|m| {
            m["files"] = (0..MAX_MANIFEST_FILES)
                .map(|i| json!({"name": format!("a/b-{i}/c_d/e.{i}.qml"), "size": 0, "sha256": HASH}))
                .collect();
        });
        let parsed = parse_manifest(nested.as_bytes()).unwrap();
        assert_eq!(parsed.files.len(), MAX_MANIFEST_FILES);
        assert_eq!(parsed.files[0].0, "a/b-0/c_d/e.0.qml");
        for name in ["kit/FoamyStyle.qml", "x".repeat(255).as_str(), "a.b-c_D9"] {
            assert_eq!(check_path(name), Ok(()), "{name}");
        }
    }

    #[test]
    fn incomplete_folders_are_broken() {
        let main = format!("{THEME_DIR}/Main.qml");
        let manifest_path = format!("{THEME_DIR}/{MANIFEST}");
        let cases: &[(&str, &Break<'_>, &str)] = &[
            (
                "a missing file",
                &|s| fs::remove_file(s.path(&main)).unwrap(),
                "Main.qml is missing",
            ),
            (
                "a file of the wrong size",
                &|s| {
                    s.file(&main, "Item { }\n");
                },
                "Main.qml is 9 bytes, the manifest says 8",
            ),
            (
                "a symlinked file",
                &|s| {
                    let target = s.file("elsewhere.qml", "Item {}\n");
                    fs::remove_file(s.path(&main)).unwrap();
                    symlink(target, s.path(&main)).unwrap();
                },
                "Main.qml isn't a regular file",
            ),
            (
                "a folder in a file's place",
                &|s| {
                    fs::remove_file(s.path(&main)).unwrap();
                    fs::create_dir(s.path(&main)).unwrap();
                },
                "Main.qml isn't a regular file",
            ),
            (
                "no manifest",
                &|s| fs::remove_file(s.path(&manifest_path)).unwrap(),
                "manifest.json is missing",
            ),
            (
                "a bad manifest",
                &|s| {
                    s.file(&manifest_path, "{\"version\": 1}");
                },
                "isn't a version",
            ),
            (
                "a manifest too large",
                &|s| {
                    s.file(&manifest_path, &" ".repeat(MAX_MANIFEST as usize + 1));
                },
                "larger than",
            ),
            (
                "a symlinked manifest",
                &|s| {
                    let target = s.file("manifest.json", &manifest(&[]));
                    fs::remove_file(s.path(&manifest_path)).unwrap();
                    symlink(target, s.path(&manifest_path)).unwrap();
                },
                "manifest.json is a symlink",
            ),
            (
                "a folder for a manifest",
                &|s| {
                    fs::remove_file(s.path(&manifest_path)).unwrap();
                    fs::create_dir(s.path(&manifest_path)).unwrap();
                },
                "manifest.json isn't a regular file",
            ),
            (
                "a symlinked theme folder",
                &|s| {
                    fs::rename(s.path(THEME_DIR), s.path("real-theme")).unwrap();
                    symlink(s.path("real-theme"), s.path(THEME_DIR)).unwrap();
                },
                "is a symlink",
            ),
            (
                "a missing file in a subfolder",
                &|s| fs::remove_file(s.path(&format!("{THEME_DIR}/kit/FoamyStyle.qml"))).unwrap(),
                "kit/FoamyStyle.qml is missing",
            ),
            (
                "a missing subfolder",
                &|s| fs::remove_dir_all(s.path(&format!("{THEME_DIR}/elements"))).unwrap(),
                "elements/shaders/aurora.frag.qsb is missing",
            ),
            (
                "a symlinked subfolder",
                &|s| {
                    let kit = s.path(&format!("{THEME_DIR}/kit"));
                    fs::rename(&kit, s.path("real-kit")).unwrap();
                    symlink(s.path("real-kit"), &kit).unwrap();
                },
                "kit is a symlink",
            ),
            (
                "a symlinked folder deeper down",
                &|s| {
                    let shaders = s.path(&format!("{THEME_DIR}/elements/shaders"));
                    fs::rename(&shaders, s.path("real-shaders")).unwrap();
                    symlink(s.path("real-shaders"), &shaders).unwrap();
                },
                "elements/shaders is a symlink",
            ),
            (
                "a file in a subfolder's place",
                &|s| {
                    fs::remove_dir_all(s.path(&format!("{THEME_DIR}/kit"))).unwrap();
                    s.file(&format!("{THEME_DIR}/kit"), "");
                },
                "kit isn't a folder",
            ),
            (
                "a symlinked file in a subfolder",
                &|s| {
                    let style = s.path(&format!("{THEME_DIR}/kit/FoamyStyle.qml"));
                    let target = s.file("style.qml", "QtObject {}\n");
                    fs::remove_file(&style).unwrap();
                    symlink(target, &style).unwrap();
                },
                "kit/FoamyStyle.qml isn't a regular file",
            ),
            (
                "a file in a subfolder of the wrong size",
                &|s| {
                    s.file(&format!("{THEME_DIR}/kit/FoamyStyle.qml"), "");
                },
                "kit/FoamyStyle.qml is 0 bytes, the manifest says 12",
            ),
            (
                "a file for a theme folder",
                &|s| {
                    fs::remove_dir_all(s.path(THEME_DIR)).unwrap();
                    s.file(THEME_DIR, "");
                },
                "isn't a folder",
            ),
        ];
        for (name, break_it, detail) in cases {
            let scratch = Scratch::new("login-broken");
            sddm(&scratch);
            ours(&scratch);
            theme(&scratch);
            assert_eq!(status(&scratch.0).unwrap()["state"], json!("installed"));
            break_it(&scratch);
            let reply = status(&scratch.0).unwrap();
            assert_eq!(reply["state"], json!("broken"), "{name}: {reply}");
            assert!(
                reply["detail"].as_str().unwrap().contains(detail),
                "{name}: {reply}"
            );
            assert_eq!(reply["installed"], Value::Null, "{name}");
        }
    }

    #[test]
    fn read_failures_and_bounds_are_io() {
        fn unreadable(rel: &'static str) -> Box<Break<'static>> {
            Box::new(move |s: &Scratch| {
                fs::set_permissions(s.path(rel), fs::Permissions::from_mode(0o000)).unwrap();
            })
        }
        let cases: Vec<(&str, Box<Break<'static>>, &str)> = vec![
            (
                "an unreadable drop-in folder",
                unreadable(CONFIG_DIR),
                "etc/sddm.conf.d",
            ),
            (
                "an unreadable drop-in",
                unreadable("etc/sddm.conf.d/10-theme.conf"),
                "10-theme.conf",
            ),
            (
                "an unreadable theme folder",
                unreadable(THEME_DIR),
                "manifest.json",
            ),
            (
                "an unreadable /etc/systemd/system",
                unreadable("etc/systemd/system"),
                "display-manager.service",
            ),
            (
                "too many drop-ins",
                Box::new(|s: &Scratch| {
                    for i in 0..MAX_CONFIG_FILES {
                        s.file(&format!("etc/sddm.conf.d/{i:02}-x.conf"), "");
                    }
                }),
                "more than 64 entries",
            ),
            (
                "a drop-in too large",
                Box::new(|s: &Scratch| {
                    s.file(
                        "etc/sddm.conf.d/20-big.conf",
                        &"#".repeat(MAX_CONFIG_FILE as usize + 1),
                    );
                }),
                "larger than 65536 bytes",
            ),
        ];
        let root = rustix::process::geteuid().is_root();
        for (name, break_it, message) in &cases {
            let scratch = Scratch::new("login-io");
            sddm(&scratch);
            ours(&scratch);
            theme(&scratch);
            break_it(&scratch);
            let result = status(&scratch.0);
            // Let Scratch remove the tree.
            for dir in [CONFIG_DIR, THEME_DIR, "etc/systemd/system"] {
                let _ = fs::set_permissions(scratch.path(dir), fs::Permissions::from_mode(0o755));
            }
            if root && name.contains("unreadable") {
                // Root reads through any mode.
                continue;
            }
            let failure = result.unwrap_err();
            assert_eq!(failure.code, "IO", "{name}");
            assert!(failure.message.contains(message), "{name}: {failure}");
        }
        // Exactly the bound is still read.
        let scratch = Scratch::new("login-bound");
        sddm(&scratch);
        for i in 0..MAX_CONFIG_FILES - 1 {
            scratch.file(&format!("etc/sddm.conf.d/{i:02}-x.conf"), "");
        }
        select(&scratch, "etc/sddm.conf.d/99-theme.conf", "omarchy");
        assert_eq!(status(&scratch.0).unwrap()["theme"], json!("omarchy"));
    }

    #[test]
    fn the_theme_dir_follows_the_config() {
        const MOVED: &str = "usr/local/share/sddm/themes";
        /// Drop-ins as (path, text).
        type Files<'a> = &'a [(&'a str, &'a str)];
        // (name, extra drop-ins, folder to install in, state, themeDir)
        let cases: &[(&str, Files<'_>, &str, &str, &str)] = &[
            ("unset", &[], THEME_DIR, "installed", DEFAULT_THEME_DIR),
            (
                "moved by a later drop-in, our folder in the default",
                &[(
                    "etc/sddm.conf.d/99-z-admin.conf",
                    "[Theme]\nThemeDir=/usr/local/share/sddm/themes\n",
                )],
                THEME_DIR,
                "broken",
                "/usr/local/share/sddm/themes",
            ),
            (
                "moved by a later drop-in, our folder there",
                &[(
                    "etc/sddm.conf.d/99-z-admin.conf",
                    "[Theme]\nThemeDir = /usr/local/share/sddm/themes # moved\n",
                )],
                "usr/local/share/sddm/themes/foamy-lock",
                "installed",
                "/usr/local/share/sddm/themes",
            ),
            (
                "moved by an earlier drop-in, set back by ours",
                &[
                    (
                        "etc/sddm.conf.d/10-admin.conf",
                        "[Theme]\nThemeDir=/usr/local/share/sddm/themes\n",
                    ),
                    (
                        "etc/sddm.conf.d/99-zz-foamy-lock.conf",
                        "[Theme]\nCurrent=foamy-lock\nThemeDir=/usr/share/sddm/themes\n",
                    ),
                ],
                THEME_DIR,
                "installed",
                DEFAULT_THEME_DIR,
            ),
            (
                "moved by /etc/sddm.conf",
                &[
                    (
                        "etc/sddm.conf.d/99-zz-foamy-lock.conf",
                        "[Theme]\nCurrent=foamy-lock\nThemeDir=/usr/share/sddm/themes\n",
                    ),
                    (
                        "etc/sddm.conf",
                        "[Theme]\nThemeDir=/usr/local/share/sddm/themes\n",
                    ),
                ],
                "usr/local/share/sddm/themes/foamy-lock",
                "installed",
                "/usr/local/share/sddm/themes",
            ),
            (
                "outside [Theme] it doesn't count",
                &[(
                    "etc/sddm.conf.d/99-z-admin.conf",
                    "[General]\nThemeDir=/usr/local/share/sddm/themes\n",
                )],
                THEME_DIR,
                "installed",
                DEFAULT_THEME_DIR,
            ),
            // SDDM keeps an empty or relative value and resolves it against
            // its working folder, /.
            (
                "empty",
                &[("etc/sddm.conf.d/99-z-admin.conf", "[Theme]\nThemeDir=\n")],
                "foamy-lock",
                "installed",
                "/",
            ),
            (
                "relative",
                &[(
                    "etc/sddm.conf.d/99-z-admin.conf",
                    "[Theme]\nThemeDir=themes\n",
                )],
                "themes/foamy-lock",
                "installed",
                "/themes",
            ),
        ];
        for (name, files, folder, state, theme_dir) in cases {
            let scratch = Scratch::new("login-theme-dir");
            sddm(&scratch);
            ours(&scratch);
            for (rel, text) in *files {
                scratch.file(rel, text);
            }
            theme_in(&scratch, folder);
            let reply = status(&scratch.0).unwrap();
            assert_eq!(reply["state"], json!(state), "{name}: {reply}");
            assert_eq!(reply["themeDir"], json!(theme_dir), "{name}: {reply}");
            if *state == "broken" {
                assert_eq!(
                    reply["detail"],
                    json!(format!(
                        "SDDM uses {THEME}, but /{MOVED}/{THEME} is missing"
                    )),
                    "{name}"
                );
            }
        }
    }

    #[test]
    fn the_root_is_absolute_or_slash() {
        assert_eq!(system_root(None), Path::new("/"));
        assert_eq!(system_root(Some("".into())), Path::new("/"));
        assert_eq!(system_root(Some("fake/root".into())), Path::new("/"));
        assert_eq!(
            system_root(Some("/tmp/fake".into())),
            Path::new("/tmp/fake")
        );
    }
}
