//! The layout test: every selectable preset through sizes, clock formats,
//! typing and primary/non-primary states, plus the geometry fallback chain;
//! without `--preset` it also runs the style sweep (styles.rs).

use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::{app, host, styles};

const SHELL: &str = include_str!("layout.qml");
/// Mirrors Layout.SELECTABLE_PRESETS.
const PRESETS: [&str; 4] = ["foamy", "corner", "editorial", "zen"];

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
    if let Some(name) = &only
        && !PRESETS.contains(&name.as_str())
    {
        return Err(format!(
            "unknown preset {name:?}; use {}",
            PRESETS.join(", ")
        ));
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        for preset in PRESETS
            .iter()
            .filter(|preset| only.as_deref().is_none_or(|o| o == **preset))
        {
            if let Err(message) = run_preset(name, shell, preset) {
                eprintln!("{message}");
                failed.push(format!("{name} {preset}"));
            }
        }
        // The whole run also sweeps every style (see styles.rs).
        if only.is_none()
            && let Err(message) = styles::run_host(name, shell)
        {
            eprintln!("{message}");
            failed.push(format!("{name} styles"));
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("layout failed: {}", failed.join(", ")))
    }
}

fn run_preset(name: &str, shell: &Path, preset: &str) -> Result<(), String> {
    let base = app::temp_dir("foamy-lock-layout")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    fs::write(dir.join("shell.qml"), SHELL.replace("__PRESET__", preset))
        .map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let (success, output) = app::run_quickshell(&base, &dir, shell, "en", Duration::from_secs(45))?;
    for line in output.lines().filter(|line| {
        line.contains("layout ok") || line.contains("LAYOUT_") || line.contains("ERROR")
    }) {
        println!("{line}");
    }
    if !success || !output.contains("LAYOUT_PASS") {
        return Err(format!(
            "layout {preset} failed ({name} {}); log: {}",
            shell.display(),
            base.display()
        ));
    }
    if let Some(out) = app::render_out("layout") {
        app::copy_captures(&dir, &out)?;
    }
    Ok(())
}
