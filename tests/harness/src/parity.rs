//! Geometry parity of the current LockView with a baseline revision.

use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::{app, host};

/// foamy-lock 1.2.0, the last release before the layout engine.
const BASELINE: &str = "8ad7ccc";
const SHELL: &str = include_str!("parity.qml");
/// Items compared in both views.
const NAMES: [&str; 20] = [
    "lockWallpaper",
    "dateLabel",
    "clockLabel",
    "identityBlock",
    "avatar",
    "nameLabel",
    "inputField",
    "unlockHint",
    "unlockHintText",
    "passwordInput",
    "submitArrow",
    "fingerprintNotice",
    "mediaRow",
    "albumArt",
    "artworkImage",
    "artworkFallback",
    "mediaControls",
    "statusFooter",
    "networkStatus",
    "batteryStatus",
];
/// 1.2.0 named only some items; these get the same objectName through their
/// id, which doesn't change the layout. (id, objectName)
const BASELINE_IDS: [(&str, &str); 8] = [
    ("dateLabel", "dateLabel"),
    ("clockLabel", "clockLabel"),
    ("identityBlock", "identityBlock"),
    ("avatar", "avatar"),
    ("nameLabel", "nameLabel"),
    ("albumArt", "albumArt"),
    ("networkPill", "networkStatus"),
    ("batteryPill", "batteryStatus"),
];

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut baseline = BASELINE.to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = || rest.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--host" => choice = value()?,
            "--baseline" => baseline = value()?,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        if let Err(message) = run_host(name, shell, &baseline) {
            eprintln!("{message}");
            failed.push(name.clone());
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("parity failed on host {}", failed.join(", ")))
    }
}

fn git_show(revision: &str, path: &str) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(app::plugin_root())
        .args(["show", &format!("{revision}:{path}")])
        .output()
        .map_err(app::io("git"))?;
    if !output.status.success() {
        return Err(format!(
            "git show {revision}:{path}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout).map_err(|error| format!("{revision}:{path}: {error}"))
}

/// The baseline view with objectNames for its unnamed items, importing the
/// app's kit and fixtures: another import path would make separate singleton
/// instances, and the baseline would miss the states set on them.
fn baseline_view(revision: &str) -> Result<String, String> {
    let mut view = app::patch_view(&git_show(revision, "LockView.qml")?);
    for (id, name) in BASELINE_IDS {
        let mut count = 0;
        let mut out = String::with_capacity(view.len() + 64);
        for line in view.split_inclusive('\n') {
            out.push_str(line);
            if line.trim() == format!("id: {id}") {
                let indent = &line[..line.len() - line.trim_start().len()];
                out.push_str(&format!("{indent}objectName: \"{name}\"\n"));
                count += 1;
            }
        }
        if count != 1 {
            return Err(format!(
                "baseline {revision}: expected one `id: {id}`, found {count}"
            ));
        }
        view = out;
    }
    for module in ["\"kit\"", "\"fixtures\" as Fixture"] {
        let import = format!("import {module}");
        if !view.contains(&import) {
            return Err(format!("baseline {revision}: no `{import}`"));
        }
        view = view.replace(&import, &format!("import \"../{}", &module[1..]));
    }
    Ok(view)
}

fn run_host(name: &str, shell: &Path, revision: &str) -> Result<(), String> {
    let base = app::temp_dir("foamy-lock-parity")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    let baseline = dir.join("baseline");
    fs::create_dir(&baseline).map_err(app::io("baseline"))?;
    fs::write(baseline.join("LockView.qml"), baseline_view(revision)?)
        .map_err(app::io("baseline view"))?;
    fs::write(baseline.join("Model.js"), git_show(revision, "Model.js")?)
        .map_err(app::io("baseline model"))?;
    let names = format!("[{}]", NAMES.map(|name| format!("\"{name}\"")).join(", "));
    fs::write(dir.join("shell.qml"), SHELL.replace("__NAMES__", &names))
        .map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let (success, output) = app::run_quickshell(&base, &dir, shell, "en", Duration::from_secs(30))?;
    // Progress lines, then the differences after a failure (and any QML
    // errors, which end a run without a PARITY line).
    let mut failing = false;
    for line in output.lines() {
        failing |= line.contains("PARITY_FAIL");
        let shown = line.to_lowercase().contains("parity")
            || line.contains("ERROR")
            || (failing && line.starts_with("  ") && !line.contains("WARN"));
        if shown {
            println!("{line}");
        }
    }
    if !success || !output.contains("PARITY_PASS") {
        return Err(format!(
            "parity with {revision} failed ({name} {}); log: {}",
            shell.display(),
            base.display()
        ));
    }
    println!(
        "Parity with {revision} ({name} {}): {}",
        shell.display(),
        dir.display()
    );
    Ok(())
}
