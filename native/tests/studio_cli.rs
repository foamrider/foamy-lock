//! The `studio` command line as the QML sees it: one JSON line on stdout
//! and the exit status, run in a temporary HOME with a cleared environment.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::{Value, json};

struct Home(PathBuf);

impl Home {
    fn new(tag: &str) -> Home {
        let path =
            std::env::temp_dir().join(format!("foamy-lock-cli-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("bin")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Home(path)
    }

    fn script(&self, rel: &str, body: &str) -> PathBuf {
        let path = self.0.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("#!/bin/bash\nPATH=/usr/bin:/bin\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn run(&self, args: &[&str], stdin: &str) -> (Value, i32) {
        let mut child = Command::new(env!("CARGO_BIN_EXE_foamy-lock-helper"))
            .args(args)
            .env_clear()
            .env("HOME", self.0.join("home"))
            .env("PATH", self.0.join("bin"))
            .env("OMARCHY_PATH", self.0.join("omarchy"))
            .env("FOAMY_LOCK_PLUGIN_DIR", self.0.join("plugin"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        // The helper may stop reading early (a request too large).
        let _ = child.stdin.take().unwrap().write_all(stdin.as_bytes());
        let output = child.wait_with_output().unwrap();
        let text = String::from_utf8(output.stdout).unwrap();
        assert_eq!(text.matches('\n').count(), 1, "one line: {text:?}");
        (
            serde_json::from_str(&text).unwrap(),
            output.status.code().unwrap(),
        )
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn plugin(home: &Path) {
    for name in ["LockView.qml", "Layout.js", "Model.js"] {
        fs::create_dir_all(home.join("plugin")).unwrap();
        fs::write(home.join("plugin").join(name), "").unwrap();
    }
    for dir in ["elements", "kit", "i18n", "studio"] {
        fs::create_dir_all(home.join("plugin").join(dir)).unwrap();
    }
}

#[test]
fn failures_exit_1_with_a_code() {
    let home = Home::new("usage");
    let (reply, code) = home.run(&["studio", "nope"], "");
    assert_eq!(
        (reply["ok"].as_bool(), reply["code"].as_str(), code),
        (Some(false), Some("INVALID_ARGUMENT"), 1)
    );
    let (reply, code) = home.run(&["studio", "apply"], "[]");
    assert_eq!((reply["code"].as_str(), code), (Some("INVALID_REQUEST"), 1));
    let (reply, code) = home.run(&["studio", "draft-save"], &" ".repeat(3 * 1024 * 1024));
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("REQUEST_TOO_LARGE"), 1)
    );
    let (reply, code) = home.run(&["studio"], "");
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("PLUGIN_NOT_FOUND"), 1)
    );
    // The lock's own subcommands keep their contract.
    let (reply, code) = home.run(&[], "");
    assert_eq!(
        (reply, code),
        (json!({"ok": false, "error": "invalid-request"}), 0)
    );
}

#[test]
fn drafts_round_trip_through_the_command_line() {
    let home = Home::new("draft");
    let (reply, code) = home.run(&["studio", "draft-load"], "");
    assert_eq!(
        (reply, code),
        (json!({"ok": true, "status": "none", "draft": null}), 0)
    );
    let (reply, code) = home.run(
        &["studio", "draft-save"],
        "{\"look\": {\"preset\": \"zen\"}, \"history\": [{}]}\n",
    );
    assert_eq!((reply["ok"].as_bool(), code), (Some(true), 0));
    let (reply, _) = home.run(&["studio", "draft-load"], "");
    assert_eq!(reply["draft"]["look"], json!({"preset": "zen"}));
    assert_eq!(reply["draft"]["history"], json!([{}]));
    assert!(
        home.0
            .join("home/.local/state/foamy-lock/studio-draft.json")
            .is_file()
    );
}

#[test]
fn apply_exits_0_with_the_result() {
    let home = Home::new("apply");
    home.script(
        "bin/omarchy-shell",
        "[[ $3 == '{\"preset\":\"zen\"}' ]] && echo unchanged || echo locked",
    );
    let (reply, code) = home.run(&["studio", "apply"], "{\"preset\": \"zen\"}");
    assert_eq!(
        (reply["result"].as_str(), reply["confirmed"].as_bool(), code),
        (Some("unchanged"), Some(true), 0)
    );
    let (reply, code) = home.run(&["studio", "apply"], "{\"preset\": \"foamy\"}");
    assert_eq!(
        (reply["ok"].as_bool(), reply["result"].as_str(), code),
        (Some(false), Some("locked"), 0)
    );
}

#[test]
fn install_and_open_use_the_plugin_dir() {
    let home = Home::new("install");
    plugin(&home.0);
    let helper = home.script(
        &format!("plugin/bin/{}/foamy-lock-helper", std::env::consts::ARCH),
        "exit 0",
    );
    let (reply, code) = home.run(&["studio", "install"], "");
    assert_eq!((reply["exec"].as_str(), code), (helper.to_str(), 0));
    let desktop = home
        .0
        .join("home/.local/share/applications/foamy-lock-studio.desktop");
    let text = fs::read_to_string(&desktop).unwrap();
    assert!(
        text.contains(&format!(" sh {} {} ", helper.display(), desktop.display())),
        "{text}"
    );
    let (reply, code) = home.run(&["studio", "ensure"], "");
    assert_eq!((reply["action"].as_str(), code), (Some("current"), 0));
    let (reply, code) = home.run(&["studio", "uninstall"], "");
    assert_eq!(
        (reply["removed"].as_array().map(Vec::len), code),
        (Some(1), 0)
    );
    let (reply, code) = home.run(&["studio", "ensure"], "");
    assert_eq!((reply["action"].as_str(), code), (Some("declined"), 0));
    assert!(!desktop.exists());
    // No quickshell: the root isn't even built.
    let (reply, code) = home.run(&["studio", "open"], "");
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("QUICKSHELL_MISSING"), 1)
    );
}

#[test]
fn preset_operations_exit_0_with_the_result() {
    let home = Home::new("preset");
    home.script(
        "bin/omarchy-shell",
        "case $2 in savePreset) echo ok ;; renamePreset) echo unknown-preset ;; *) echo unchanged ;; esac",
    );
    let (reply, code) = home.run(
        &["studio", "preset", "save"],
        "{\"id\": \"mine\", \"name\": \"Mine\", \"look\": {\"preset\": \"zen\"}}",
    );
    assert_eq!((reply["result"].as_str(), code), (Some("ok"), 0));
    let (reply, code) = home.run(
        &["studio", "preset", "rename"],
        "{\"id\": \"gone\", \"name\": \"X\"}",
    );
    assert_eq!(
        (reply["ok"].as_bool(), reply["result"].as_str(), code),
        (Some(false), Some("unknown-preset"), 0)
    );
    let (reply, code) = home.run(&["studio", "preset", "delete"], "{\"id\": \"mine\"}");
    assert_eq!((reply["result"].as_str(), code), (Some("unchanged"), 0));
    let (reply, code) = home.run(&["studio", "preset", "delete"], "{\"id\": \"Mine\"}");
    assert_eq!((reply["code"].as_str(), code), (Some("INVALID_REQUEST"), 1));
    let (reply, code) = home.run(&["studio", "preset", "move"], "{}");
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("INVALID_ARGUMENT"), 1)
    );
}
