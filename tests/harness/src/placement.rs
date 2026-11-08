//! The placement cases: scale, opacity, offset, glass and screens on one
//! view: the geometry codes they produce, mirrored offsets, a primary-only
//! element on a secondary view, decorations that keep fitting the un-offset
//! zones, and `latchFallback: false` reporting without switching.

use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::{app, host, styles};

const SHELL: &str = include_str!("placement.qml");

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--host" => choice = rest.next().cloned().ok_or(format!("{arg} needs a value"))?,
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
        Err(format!("placement failed: {}", failed.join(", ")))
    }
}

/// The cases on one host shell; plugin QML warnings fail them.
pub fn run_host(name: &str, shell: &Path) -> Result<(), String> {
    let base = app::temp_dir("foamy-lock-placement")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    fs::write(dir.join("shell.qml"), SHELL).map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let (success, output) =
        app::run_quickshell(&base, &dir, shell, "en", Duration::from_secs(120))?;
    for line in output.lines().filter(|line| {
        line.contains("placement ok") || line.contains("PLACEMENT_") || line.contains("ERROR")
    }) {
        println!("{line}");
    }
    let warnings = styles::qml_warnings(&output);
    if !success || !output.contains("PLACEMENT_PASS") || !warnings.is_empty() {
        return Err(format!(
            "placement failed ({name} {}){}; log: {}",
            shell.display(),
            warnings
                .iter()
                .map(|line| format!("\n  {line}"))
                .collect::<String>(),
            base.display()
        ));
    }
    Ok(())
}
