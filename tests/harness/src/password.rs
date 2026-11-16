//! The password test: the real LockView's password field with real key and
//! mouse events (password.qml), and paste through kit/clipboard.sh against a
//! wl-paste stand-in on PATH. Typing and editing keys, Ctrl+V, Shift+Insert
//! and middle-click paste, an endless and a stalled clipboard, a reply that
//! arrives after an edit, and authentication starting mid-read (the read
//! stops, and its wl-paste, which ignores TERM, must be gone).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use crate::{app, host};

const SHELL: &str = include_str!("password.qml");

/// wl-paste and clipboard-fixture in one script (bash builtins only, so it
/// starts fast): `clipboard-fixture MODE` sets what the next paste does;
/// each paste writes its argv and pid next to the mode file.
const STAND_IN: &str = r#"#!/bin/bash
state=$TEST_CLIPBOARD_STATE
if [[ ${0##*/} == clipboard-fixture ]]; then
  printf '%s' "$1" >"$state"
  exit 0
fi
mode=$(<"$state")
printf '%s' "$$" >"$state.pid"
printf '%s ' "$@" >"$state.args"
case $mode in
  stream) while :; do printf '%4096s' ''; done ;;
  stall) exec sleep 30 ;;
  ignore) trap '' TERM; exec sleep 30 ;;
  delayed) sleep 0.4; printf late ;;
  *) printf s3cret ;;
esac
"#;

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--host" => choice = rest.next().cloned().ok_or("--host needs a value")?,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        if let Err(message) = run_host(name, shell) {
            eprintln!("{message}");
            failed.push(name.clone());
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("password failed on host {}", failed.join(", ")))
    }
}

/// True once `pid` is gone or a zombie, within two seconds.
fn gone(pid: &str) -> bool {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let state = fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|stat| {
                stat.rsplit_once(')')
                    .map(|(_, rest)| rest.trim().to_string())
            });
        match state {
            None => return true,
            Some(rest) if rest.starts_with('Z') => return true,
            Some(_) if Instant::now() >= deadline => return false,
            Some(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

fn run_host(name: &str, shell: &Path) -> Result<(), String> {
    let base = app::temp_dir("foamy-lock-password")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    fs::write(dir.join("shell.qml"), SHELL).map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let bin = base.join("clipboard-bin");
    fs::create_dir(&bin).map_err(app::io("clipboard-bin"))?;
    for command in ["wl-paste", "clipboard-fixture"] {
        let path = bin.join(command);
        fs::write(&path, STAND_IN).map_err(app::io(command))?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).map_err(app::io(command))?;
    }
    let state = base.join("clipboard-mode");
    fs::write(&state, "normal").map_err(app::io("clipboard-mode"))?;
    // The stand-ins go in front of the hermetic PATH.
    let hermetic = app::quickshell_env(&base, shell)
        .into_iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value)
        .ok_or("the hermetic environment has no PATH")?;
    let path = format!("{}:{hermetic}", bin.display());
    let state_text = state.display().to_string();
    let extra = [
        ("PATH", path.as_str()),
        ("TEST_CLIPBOARD_STATE", state_text.as_str()),
        ("QML_XHR_ALLOW_FILE_READ", "1"),
    ];
    let (success, output) = app::run_quickshell_with(
        &base,
        &dir,
        shell,
        "en",
        Duration::from_secs(90),
        &extra,
        &mut |_, _| Ok(()),
    )?;
    print!(
        "{}",
        output
            .lines()
            .filter(|line| line.contains("PASS:") || line.contains("FOAMY"))
            .map(|line| format!("{line}\n"))
            .collect::<String>()
    );
    let failed = output.contains("FOAMY FAIL") || !output.contains("FOAMY DONE");
    if !success || failed {
        return Err(format!(
            "password failed ({name} {}); log: {}",
            shell.display(),
            base.display()
        ));
    }
    let pids: Vec<&str> = output
        .lines()
        .filter_map(|line| {
            line.split_once("FOAMY PASTE PID ")
                .map(|(_, pid)| pid.trim())
        })
        .collect();
    if pids.len() != 1 || !pids[0].bytes().all(|b| b.is_ascii_digit()) || !gone(pids[0]) {
        return Err(format!(
            "the cancelled paste's wl-paste is still running ({pids:?}); log: {}",
            base.display()
        ));
    }
    println!("Password ({name} {}): ok", shell.display());
    Ok(())
}
