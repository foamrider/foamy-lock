//! `studio login-screen stage` on the command line: one JSON line on stdout
//! and the exit status, with a cleared environment and temporary HOME,
//! cache and runtime folders.

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
            std::env::temp_dir().join(format!("foamy-lock-stage-cli-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        for dir in ["home", "cache", "run", "plugin"] {
            fs::create_dir_all(path.join(dir)).unwrap();
        }
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(path.join("plugin/LockView.qml"), "").unwrap();
        for (rel, text) in [
            ("plugin/sddm/Main.qml", "Item {}\n"),
            ("plugin/sddm/kit/FoamyI18n.qml", "QtObject {}\n"),
            ("plugin/Layout.js", "// layout\n"),
            ("plugin/i18n/en.json", "{\"lock.password\": \"Password\"}"),
            (
                "plugin/sddm/bundle.txt",
                "# greeter\nsddm/Main.qml\nsddm/kit/FoamyI18n.qml\nLayout.js\n",
            ),
        ] {
            fs::create_dir_all(path.join(rel).parent().unwrap()).unwrap();
            fs::write(path.join(rel), text).unwrap();
        }
        fs::write(
            path.join("plugin/manifest.json"),
            "{\"id\": \"foamy.lock\", \"version\": \"1.4.1\"}",
        )
        .unwrap();
        Home(path)
    }

    fn path(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }

    fn run(&self, stdin: &[u8], runtime: Option<&Path>) -> (Value, i32) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_foamy-lock-helper"));
        command
            .args(["studio", "login-screen", "stage"])
            .env_clear()
            .env("HOME", self.path("home"))
            .env("XDG_CACHE_HOME", self.path("cache"))
            .env("PATH", "/usr/bin:/bin")
            .env("FOAMY_LOCK_PLUGIN_DIR", self.path("plugin"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(runtime) = runtime {
            command.env("XDG_RUNTIME_DIR", runtime);
        }
        let mut child = command.spawn().unwrap();
        // The helper may stop reading early (a request too large).
        let _ = child.stdin.take().unwrap().write_all(stdin);
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

/// A PNG header (the helper never decodes it).
fn png(width: u32, height: u32) -> Vec<u8> {
    let mut data = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    data.extend_from_slice(&width.to_be_bytes());
    data.extend_from_slice(&height.to_be_bytes());
    data.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
    data
}

fn request(look: Value, shows_picture: bool, background: Option<&Path>) -> Vec<u8> {
    let keys = [
        "background",
        "foreground",
        "accent",
        "muted",
        "urgent",
        "lockBackground",
        "lockBorder",
        "lockBorderError",
        "lockPlaceholder",
        "lockSelection",
        "lockText",
        "lockTextError",
        "popupsBackground",
        "popupsBorder",
        "popupsText",
        "warning",
        "success",
        "error",
        "info",
    ];
    let colors: serde_json::Map<String, Value> = keys
        .iter()
        .map(|key| ((*key).to_string(), json!("#1a1b26")))
        .collect();
    serde_json::to_vec(&json!({
        "look": look, "showsPicture": shows_picture, "timeFormat": "12h", "showUserInfo": false, "language": "en",
        "formatLocale": "en-GB", "rightToLeft": false, "colors": colors, "lockThemed": [],
        "background": background, "avatar": null}))
    .unwrap()
}

#[test]
fn a_stage_exits_0_with_its_folder() {
    let home = Home::new("ok");
    let background = home.path(&format!(
        "cache/omarchy/foamy.lock/background/{}.png",
        "0f".repeat(32)
    ));
    fs::create_dir_all(background.parent().unwrap()).unwrap();
    fs::write(&background, png(2560, 1440)).unwrap();
    let runtime = home.path("run");
    let look = json!({"preset": "foamy", "layout": {"weather": {"hidden": false}}});
    let (reply, code) = home.run(
        &request(look.clone(), true, Some(&background)),
        Some(&runtime),
    );
    assert_eq!((reply["ok"].as_bool(), code), (Some(true), 0), "{reply}");
    assert_eq!(
        reply["files"],
        json!([
            "snapshot.json",
            "background.png",
            "Layout.js",
            "Main.qml",
            "kit/FoamyI18n.qml"
        ])
    );
    let dir = PathBuf::from(reply["dir"].as_str().unwrap());
    assert_eq!(
        dir.parent(),
        Some(runtime.join("foamy-lock/login-screen").as_path())
    );
    let snapshot: Value =
        serde_json::from_slice(&fs::read(dir.join("snapshot.json")).unwrap()).unwrap();
    assert_eq!(
        snapshot["look"]["layout"]["weather"],
        json!({"hidden": true})
    );
    assert_eq!(
        snapshot["files"],
        json!({"background": "background.png", "avatar": null})
    );
    // "en" from the request's language.
    assert_eq!(snapshot["strings"], json!({"lock.password": "Password"}));
    assert_eq!(
        fs::read_to_string(dir.join("kit/FoamyI18n.qml")).unwrap(),
        "QtObject {}\n"
    );
    let mode = |rel: &str| {
        fs::symlink_metadata(dir.join(rel))
            .unwrap()
            .permissions()
            .mode()
            & 0o7777
    };
    assert_eq!((mode("kit"), mode("kit/FoamyI18n.qml")), (0o700, 0o600));
    let manifest: Value =
        serde_json::from_slice(&fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["hash"], reply["hash"]);
    assert_eq!(manifest["plugin"], "1.4.1");
    // The same request again: one folder, the same hash.
    let (again, code) = home.run(&request(look, true, Some(&background)), Some(&runtime));
    assert_eq!((again["hash"].clone(), code), (reply["hash"].clone(), 0));
    assert!(!dir.exists());
    assert_eq!(
        fs::read_dir(runtime.join("foamy-lock/login-screen"))
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().starts_with("stage-"))
            .count(),
        1
    );
}

#[test]
fn failures_exit_1_with_a_code() {
    let home = Home::new("fail");
    let runtime = home.path("run");
    let (reply, code) = home.run(b"[]", Some(&runtime));
    assert_eq!(
        (reply["ok"].as_bool(), reply["code"].as_str(), code),
        (Some(false), Some("INVALID_REQUEST"), 1)
    );
    // A user path in a key the helper doesn't know.
    let look = json!({"preset": "zen", "layout": {"clock": {"font": "/home/me/a.ttf"}}});
    let (reply, code) = home.run(&request(look, false, None), Some(&runtime));
    assert_eq!((reply["code"].as_str(), code), (Some("INVALID_REQUEST"), 1));
    assert!(
        reply["error"]
            .as_str()
            .unwrap()
            .starts_with("look.layout.clock.font"),
        "{reply}"
    );
    let (reply, code) = home.run(
        &request(json!({"preset": "foamy"}), true, None),
        Some(&runtime),
    );
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("BACKGROUND_MISSING"), 1)
    );
    let (reply, code) = home.run(&request(json!({"preset": "zen"}), false, None), None);
    assert_eq!((reply["code"].as_str(), code), (Some("NO_RUNTIME_DIR"), 1));
    // A broken plugin: a listed file that isn't there.
    fs::write(
        home.path("plugin/sddm/bundle.txt"),
        "sddm/Main.qml\nsddm/Gone.qml\n",
    )
    .unwrap();
    let (reply, code) = home.run(
        &request(json!({"preset": "zen"}), false, None),
        Some(&runtime),
    );
    assert_eq!((reply["code"].as_str(), code), (Some("BUNDLE_INVALID"), 1));
    assert_eq!(reply["error"], "sddm/Gone.qml is missing", "{reply}");
    let (reply, code) = home.run(&vec![b' '; 300 * 1024], Some(&runtime));
    assert_eq!(
        (reply["code"].as_str(), code),
        (Some("REQUEST_TOO_LARGE"), 1)
    );
    // Nothing was staged.
    assert!(!runtime.join("foamy-lock/login-screen").exists());
}
