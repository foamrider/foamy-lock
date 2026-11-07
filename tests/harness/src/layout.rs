//! The layout test: every selectable preset through sizes, clock formats,
//! typing and primary/non-primary states, plus the geometry fallback chain.

use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::{app, host};

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
    if let Some(out) = std::env::var_os("FOAMY_RENDER_OUT").filter(|value| !value.is_empty()) {
        let out = Path::new(&out).join("layout");
        fs::create_dir_all(&out).map_err(app::io(out.display()))?;
        for entry in fs::read_dir(&dir)
            .map_err(app::io(dir.display()))?
            .flatten()
        {
            let file = entry.file_name().to_string_lossy().into_owned();
            if file.starts_with("capture-") && file.ends_with(".png") {
                fs::copy(entry.path(), out.join(&file)).map_err(app::io(&file))?;
            }
        }
    }
    Ok(())
}
