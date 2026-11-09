//! The layout test: every selectable preset through sizes, clock formats,
//! typing, primary/non-primary and right-to-left states, plus the preset
//! cycle and the geometry fallback chain; without `--preset` it also runs
//! the style sweep (styles.rs). Presets run a few at a time, each in its own
//! quickshell. Each state also compares the shapes with the decorations they
//! replaced: elements/Decoration.qml at DECORATION_BASELINE (from git), as
//! OldDecoration.qml beside the view.

use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::{app, host, placement, styles};

const SHELL: &str = include_str!("layout.qml");
/// Quickshell runs at once.
const PARALLEL: usize = 4;
/// The last revision with the fixed decorations (`background.decor`).
const DECORATION_BASELINE: &str = "6efe1fd";

/// The decorations as they were drawn before shapes.
fn old_decoration() -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(app::plugin_root())
        .args([
            "show",
            &format!("{DECORATION_BASELINE}:elements/Decoration.qml"),
        ])
        .output()
        .map_err(app::io("git"))?;
    if !output.status.success() {
        return Err(format!(
            "git show {DECORATION_BASELINE}:elements/Decoration.qml: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout).map_err(|error| format!("old decoration: {error}"))
}

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut only: Option<String> = None;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = || rest.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--host" => choice = value()?,
            "--preset" => only = Some(value()?),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let presets = app::selectable_presets()?;
    if let Some(name) = &only
        && !presets.contains(name)
    {
        return Err(format!(
            "unknown preset {name:?}; use {}",
            presets.join(", ")
        ));
    }
    let chosen: Vec<&str> = presets
        .iter()
        .map(String::as_str)
        .filter(|preset| only.as_deref().is_none_or(|o| o == *preset))
        .collect();
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        for batch in chosen.chunks(PARALLEL) {
            let results: Vec<(&str, Result<String, String>)> = std::thread::scope(|scope| {
                let runs: Vec<_> = batch
                    .iter()
                    .map(|preset| (*preset, scope.spawn(|| run_preset(name, shell, preset))))
                    .collect();
                runs.into_iter()
                    .map(|(preset, run)| {
                        let result = run
                            .join()
                            .unwrap_or_else(|_| Err(format!("layout {preset} panicked")));
                        (preset, result)
                    })
                    .collect()
            });
            for (preset, result) in results {
                match result {
                    Ok(lines) => print!("{lines}"),
                    Err(message) => {
                        eprintln!("{message}");
                        failed.push(format!("{name} {preset}"));
                    }
                }
            }
        }
        // The whole run also sweeps every style (see styles.rs).
        if only.is_none()
            && let Err(message) = styles::run_host(name, shell)
        {
            eprintln!("{message}");
            failed.push(format!("{name} styles"));
        }
        // And the free-placement cases (see placement.rs).
        if only.is_none()
            && let Err(message) = placement::run_host(name, shell)
        {
            eprintln!("{message}");
            failed.push(format!("{name} placement"));
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("layout failed: {}", failed.join(", ")))
    }
}

/// One preset's run; its log lines on success.
fn run_preset(name: &str, shell: &Path, preset: &str) -> Result<String, String> {
    let base = app::temp_dir("foamy-lock-layout")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    fs::write(dir.join("shell.qml"), SHELL.replace("__PRESET__", preset))
        .map_err(app::io("shell.qml"))?;
    fs::write(dir.join("OldDecoration.qml"), old_decoration()?)
        .map_err(app::io("OldDecoration.qml"))?;
    app::register_types(&dir)?;
    // foamy also cycles through every preset.
    let timeout = Duration::from_secs(if preset == "foamy" { 150 } else { 60 });
    let (success, output) = app::run_quickshell(&base, &dir, shell, "en", timeout)?;
    let lines: String = output
        .lines()
        .filter(|line| {
            line.contains("layout ok") || line.contains("LAYOUT_") || line.contains("ERROR")
        })
        .map(|line| format!("{line}\n"))
        .collect();
    if !success || !output.contains("LAYOUT_PASS") {
        return Err(format!(
            "{lines}layout {preset} failed ({name} {}); log: {}",
            shell.display(),
            base.display()
        ));
    }
    if let Some(out) = app::render_out("layout") {
        app::copy_captures(&dir, &out)?;
    }
    Ok(lines)
}
