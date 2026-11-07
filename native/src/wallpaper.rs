//! `wallpaper <link>`: where Omarchy's current background points, and a
//! signature that changes when that file does. Replaces the shell's
//! `readlink -f` + `stat -L -c %s:%y:%z` + `jq` probe.
//!
//! The link is resolved like `readlink -f` (every symlink in the chain,
//! relative ones against their own directory, `.` and `..` removed), and the
//! target must then exist, as `stat -L` required. The signature is
//! `<dev>:<inode>:<size>:<mtime>:<ctime>` with nanosecond times: it is the
//! same while the file is unchanged and differs after a rewrite, a touch, a
//! chmod or a replacement at the same path. Only QML compares it.

use std::ffi::OsStr;
use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

use serde_json::{Value, json};

use crate::Fail;

/// The reply to `wallpaper <link>`: `{"ok": true, "path", "signature"}`, or
/// `{"ok": false, "error"}`.
pub fn probe(link: &OsStr) -> Value {
    match resolve(Path::new(link)) {
        Ok((path, signature)) => json!({"ok": true, "path": path, "signature": signature}),
        Err(Fail(code)) => crate::failure(code),
    }
}

/// The resolved absolute path and the target's signature.
pub fn resolve(link: &Path) -> Result<(String, String), Fail> {
    if !link.is_absolute() {
        return Err(Fail("invalid-request"));
    }
    let path = std::fs::canonicalize(link).map_err(missing)?;
    // `canonicalize` follows every link, so this is the target's own stat.
    let metadata = std::fs::metadata(&path).map_err(missing)?;
    if !metadata.is_file() {
        return Err(Fail("not-regular-file"));
    }
    let path = path
        .into_os_string()
        .into_string()
        .map_err(|_| Fail("invalid-path"))?;
    Ok((path, signature(&Stamp::of(&metadata))))
}

/// A dangling link, a missing file or component, a link loop: `wallpaper-missing`.
fn missing(error: std::io::Error) -> Fail {
    // ErrorKind::FilesystemLoop is unstable: ELOOP by number.
    if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory)
        || error.raw_os_error() == Some(libc::ELOOP)
    {
        return Fail("wallpaper-missing");
    }
    error.into()
}

/// What the signature is made of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}

impl Stamp {
    fn of(metadata: &std::fs::Metadata) -> Stamp {
        Stamp {
            dev: metadata.dev(),
            ino: metadata.ino(),
            size: metadata.size(),
            mtime: (metadata.mtime(), metadata.mtime_nsec()),
            ctime: (metadata.ctime(), metadata.ctime_nsec()),
        }
    }
}

fn signature(stamp: &Stamp) -> String {
    format!(
        "{}:{}:{}:{}.{:09}:{}.{:09}",
        stamp.dev,
        stamp.ino,
        stamp.size,
        stamp.mtime.0,
        stamp.mtime.1,
        stamp.ctime.0,
        stamp.ctime.1
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::{Duration, SystemTime};

    /// A fresh directory under the system temp dir, removed on drop.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Scratch {
            static COUNT: AtomicU32 = AtomicU32::new(0);
            let name = format!(
                "foamy-lock-wallpaper-{}-{}",
                std::process::id(),
                COUNT.fetch_add(1, Ordering::Relaxed)
            );
            let path = std::env::temp_dir().join(name);
            let _ = fs::remove_dir_all(&path);
            fs::create_dir(&path).unwrap();
            // Compare against the resolved form (the temp dir may be a link).
            Scratch(fs::canonicalize(path).unwrap())
        }

        fn file(&self, name: &str, data: &[u8]) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, data).unwrap();
            path
        }

        fn link(&self, name: &str, target: impl AsRef<Path>) -> PathBuf {
            let path = self.0.join(name);
            symlink(target, &path).unwrap();
            path
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn path_of(link: &Path) -> String {
        resolve(link).unwrap().0
    }

    fn signature_of(link: &Path) -> String {
        resolve(link).unwrap().1
    }

    fn error_of(link: &Path) -> &'static str {
        resolve(link).unwrap_err().0
    }

    #[test]
    fn plain_file() {
        let scratch = Scratch::new();
        let file = scratch.file("wall paper.png", b"png");
        assert_eq!(path_of(&file), file.to_str().unwrap());
        // `.` and `..` are removed like readlink -f does.
        fs::create_dir(scratch.0.join("x")).unwrap();
        let dotted = scratch
            .0
            .join(".")
            .join("x")
            .join("..")
            .join("wall paper.png");
        assert_eq!(path_of(&dotted), file.to_str().unwrap());
    }

    #[test]
    fn symlink_chain() {
        let scratch = Scratch::new();
        let file = scratch.file("theme.jpg", b"jpg");
        let middle = scratch.link("middle", &file);
        let background = scratch.link("background", &middle);
        assert_eq!(path_of(&background), file.to_str().unwrap());
        assert_eq!(signature_of(&background), signature_of(&file));
    }

    #[test]
    fn relative_symlink() {
        let scratch = Scratch::new();
        fs::create_dir_all(scratch.0.join("themes/one")).unwrap();
        fs::create_dir_all(scratch.0.join("current")).unwrap();
        let file = scratch.file("themes/one/1.png", b"png");
        let theme = scratch.link("current/theme", "../themes/one");
        let background = scratch.link("current/background", "theme/1.png");
        assert_eq!(path_of(&background), file.to_str().unwrap());
        assert_eq!(path_of(&theme.join("1.png")), file.to_str().unwrap());
    }

    #[test]
    fn dangling_link_and_missing_file() {
        let scratch = Scratch::new();
        let dangling = scratch.link("background", scratch.0.join("gone.png"));
        assert_eq!(error_of(&dangling), "wallpaper-missing");
        assert_eq!(error_of(&scratch.0.join("absent")), "wallpaper-missing");
        let file = scratch.file("file", b"");
        assert_eq!(error_of(&file.join("below")), "wallpaper-missing");
        let a = scratch.0.join("a");
        scratch.link("b", &a);
        symlink(scratch.0.join("b"), &a).unwrap();
        assert_eq!(error_of(&a), "wallpaper-missing");
        // The reply carries the code, never the path.
        let reply = probe(dangling.as_os_str());
        assert_eq!(reply, json!({"ok": false, "error": "wallpaper-missing"}));
    }

    #[test]
    fn directory_is_not_a_wallpaper() {
        let scratch = Scratch::new();
        fs::create_dir(scratch.0.join("dir")).unwrap();
        assert_eq!(error_of(&scratch.0.join("dir")), "not-regular-file");
        let link = scratch.link("background", "dir");
        assert_eq!(error_of(&link), "not-regular-file");
    }

    #[test]
    fn relative_argument_is_refused() {
        assert_eq!(error_of(Path::new("background")), "invalid-request");
        assert_eq!(error_of(Path::new("")), "invalid-request");
    }

    #[test]
    fn signature_is_stable_until_the_file_changes() {
        let scratch = Scratch::new();
        let file = scratch.file("wallpaper.png", b"first");
        let background = scratch.link("background", &file);
        let first = signature_of(&background);
        assert_eq!(signature_of(&background), first, "unchanged file");

        // Rewritten in place (another size).
        fs::write(&file, b"second, longer").unwrap();
        let rewritten = signature_of(&background);
        assert_ne!(rewritten, first);

        // Touched: same bytes, another mtime (and ctime).
        let touched_at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
        fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(touched_at)
            .unwrap();
        let touched = signature_of(&background);
        assert_ne!(touched, rewritten);
        assert!(touched.contains(":1000000000.000000000:"), "{touched}");

        // Replaced at the same path with identical bytes and times.
        let replacement = scratch.file("replacement", b"second, longer");
        fs::File::options()
            .write(true)
            .open(&replacement)
            .unwrap()
            .set_modified(touched_at)
            .unwrap();
        fs::rename(&replacement, &file).unwrap();
        assert_ne!(signature_of(&background), touched);

        let reply = probe(background.as_os_str());
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["path"], file.to_str().unwrap());
        assert_eq!(reply["signature"], signature_of(&file));
    }

    #[test]
    fn signature_covers_size_mtime_and_ctime() {
        let stamp = Stamp {
            dev: 1,
            ino: 2,
            size: 3,
            mtime: (4, 5),
            ctime: (6, 7),
        };
        assert_eq!(signature(&stamp), "1:2:3:4.000000005:6.000000007");
        let changed = [
            Stamp { size: 30, ..stamp },
            Stamp {
                mtime: (4, 6),
                ..stamp
            },
            Stamp {
                mtime: (5, 5),
                ..stamp
            },
            Stamp {
                ctime: (6, 8),
                ..stamp
            },
            Stamp {
                ctime: (7, 7),
                ..stamp
            },
            Stamp { ino: 20, ..stamp },
            Stamp { dev: 10, ..stamp },
        ];
        for other in changed {
            assert_ne!(signature(&other), signature(&stamp), "{other:?}");
        }
        // A real chmod changes only ctime; the stamp picks it up.
        let scratch = Scratch::new();
        let file = scratch.file("mode", b"");
        let before = Stamp::of(&fs::metadata(&file).unwrap());
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        let after = Stamp::of(&fs::metadata(&file).unwrap());
        assert_eq!((before.size, before.mtime), (after.size, after.mtime));
        assert!(after.ctime >= before.ctime);
    }
}
