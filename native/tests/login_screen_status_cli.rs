//! `studio login-screen status` as Studio runs it: one JSON line on stdout
//! and the exit status, with a cleared environment and a fake system root
//! (`FOAMY_LOCK_SYSTEM_ROOT`), so the real `/etc` and `/usr` are never read.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::{Value, json};

const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

struct System(PathBuf);

impl System {
    fn new(tag: &str) -> System {
        let path =
            std::env::temp_dir().join(format!("foamy-lock-login-cli-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("plugin")).unwrap();
        fs::write(path.join("plugin/LockView.qml"), "").unwrap();
        System(path)
    }

    fn root(&self) -> PathBuf {
        self.0.join("root")
    }

    fn file(&self, rel: &str, text: &str) -> PathBuf {
        let path = self.root().join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, text).unwrap();
        path
    }

    /// SDDM enabled, its greeter installed and Omarchy's theme selected.
    fn sddm(&self) {
        let unit = self
            .root()
            .join("etc/systemd/system/display-manager.service");
        fs::create_dir_all(unit.parent().unwrap()).unwrap();
        symlink("/usr/lib/systemd/system/sddm.service", unit).unwrap();
        let greeter = self.file("usr/bin/sddm-greeter-qt6", "");
        fs::set_permissions(greeter, fs::Permissions::from_mode(0o755)).unwrap();
        self.file(
            "etc/sddm.conf.d/10-theme.conf",
            "[Theme]\nCurrent=omarchy\n",
        );
    }

    fn theme(&self) {
        let dir = "usr/share/sddm/themes/foamy-lock";
        self.file(&format!("{dir}/Main.qml"), "Item {}\n");
        let manifest = json!({"version": 1, "plugin": "1.4.1", "hash": HASH,
            "files": [{"name": "Main.qml", "size": 8, "sha256": HASH}]});
        self.file(&format!("{dir}/manifest.json"), &manifest.to_string());
    }

    fn run(&self, args: &[&str], root: &Path) -> (Value, i32) {
        let output = Command::new(env!("CARGO_BIN_EXE_foamy-lock-helper"))
            .args(args)
            .env_clear()
            .env("HOME", self.0.join("home"))
            .env("PATH", self.0.join("bin"))
            .env("FOAMY_LOCK_PLUGIN_DIR", self.0.join("plugin"))
            .env("FOAMY_LOCK_SYSTEM_ROOT", root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .unwrap();
        let text = String::from_utf8(output.stdout).unwrap();
        assert_eq!(text.matches('\n').count(), 1, "one line: {text:?}");
        (
            serde_json::from_str(&text).unwrap(),
            output.status.code().unwrap(),
        )
    }

    fn status(&self) -> (Value, i32) {
        self.run(&["studio", "login-screen", "status"], &self.root())
    }
}

impl Drop for System {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn status_follows_the_fake_system() {
    let system = System::new("states");
    fs::create_dir_all(system.root()).unwrap();
    assert_eq!(
        system.status(),
        (
            json!({"ok": true, "state": "unavailable", "reason": "not-sddm", "theme": "",
                   "themeSetIn": null, "autologin": false, "installed": null}),
            0
        )
    );
    system.sddm();
    system.file(
        "etc/sddm.conf.d/autologin.conf",
        "[Autologin]\nUser=me\nSession=omarchy.desktop\n",
    );
    assert_eq!(
        system.status(),
        (
            json!({"ok": true, "state": "not-installed", "theme": "omarchy",
                   "themeSetIn": "/etc/sddm.conf.d/10-theme.conf", "autologin": true,
                   "installed": null}),
            0
        )
    );
    system.theme();
    system.file(
        "etc/sddm.conf.d/50-foamy-lock.conf",
        "[Theme]\nCurrent=foamy-lock\n",
    );
    assert_eq!(
        system.status(),
        (
            json!({"ok": true, "state": "installed", "theme": "foamy-lock",
                   "themeSetIn": "/etc/sddm.conf.d/50-foamy-lock.conf", "autologin": true,
                   "installed": {"plugin": "1.4.1", "hash": HASH}}),
            0
        )
    );
    // A .pacnew drop-in counts, as SDDM reads it.
    system.file(
        "etc/sddm.conf.d/50-foamy-lock.conf.pacnew",
        "[Theme]\nCurrent=omarchy\n",
    );
    let (reply, code) = system.status();
    assert_eq!(
        (reply["state"].as_str(), reply["themeSetIn"].as_str(), code),
        (
            Some("overridden"),
            Some("/etc/sddm.conf.d/50-foamy-lock.conf.pacnew"),
            0
        )
    );
    fs::remove_file(
        system
            .root()
            .join("usr/share/sddm/themes/foamy-lock/Main.qml"),
    )
    .unwrap();
    let (reply, code) = system.status();
    assert_eq!((reply["state"].as_str(), code), (Some("broken"), 0));
}

#[test]
fn a_failed_read_exits_1_with_io() {
    // Root reads through any mode, so the folder can't be made unreadable.
    if rustix::process::geteuid().is_root() {
        return;
    }
    let system = System::new("io");
    system.sddm();
    let dir = system.root().join("etc/sddm.conf.d");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o000)).unwrap();
    let (reply, code) = system.status();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(
        (reply["ok"].as_bool(), reply["code"].as_str(), code),
        (Some(false), Some("IO"), 1)
    );
    assert!(
        reply["error"].as_str().unwrap().contains("sddm.conf.d"),
        "{reply}"
    );
}

#[test]
fn extra_arguments_are_refused() {
    let system = System::new("usage");
    let (reply, code) = system.run(&["studio", "login-screen", "status", "now"], &system.root());
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("INVALID_ARGUMENT"), 1)
    );
}
