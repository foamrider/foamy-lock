//! The preset thumbnails: every selectable preset rendered at 1920×1080 with
//! the synthetic data and a fixed theme, scaled to 480×270 into
//! `previews/presets/<name>.png` (the catalog IPC points there).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::{app, host, png};

const SHELL: &str = include_str!("thumbnails.qml");
const SIZE: (u32, u32) = (480, 270);

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut out = app::plugin_root().join("previews/presets");
    let mut only: Vec<String> = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = || rest.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--host" => choice = value()?,
            "--out" => out = PathBuf::from(value()?),
            "--preset" => only.push(value()?),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let presets = app::selectable_presets()?;
    if let Some(unknown) = only.iter().find(|name| !presets.contains(name)) {
        return Err(format!(
            "unknown preset {unknown:?}; use {}",
            presets.join(", ")
        ));
    }
    let chosen: Vec<String> = if only.is_empty() { presets } else { only };
    // One host only: the thumbnails are one set of files.
    let hosts = host::selected(&choice)?;
    let (name, shell) = hosts.first().ok_or("no host shell")?;
    let full = app::render_out("thumbnails");
    let dir = render(name, shell, &chosen, full.is_some())?;
    fs::create_dir_all(&out).map_err(app::io(out.display()))?;
    let out = out.canonicalize().unwrap_or(out);
    for preset in &chosen {
        let source = dir.join(format!("thumb-{preset}.png"));
        let bytes = fs::read(&source).map_err(app::io(source.display()))?;
        if png::size(&bytes) != Some(SIZE) {
            return Err(format!(
                "{preset}: thumbnail is {:?}, not {SIZE:?}",
                png::size(&bytes)
            ));
        }
        let target = out.join(format!("{preset}.png"));
        fs::write(&target, &bytes).map_err(app::io(target.display()))?;
    }
    if let Some(full) = full {
        app::copy_captures(&dir, &full)?;
    }
    println!(
        "thumbnails: {} presets into {}",
        chosen.len(),
        out.display()
    );
    Ok(())
}

fn render(name: &str, shell: &Path, presets: &[String], full: bool) -> Result<PathBuf, String> {
    let base = app::temp_dir("foamy-lock-thumbnails")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    let list = format!(
        "[{}]",
        presets
            .iter()
            .map(|p| format!("\"{p}\""))
            .collect::<Vec<_>>()
            .join(", ")
    );
    let qml = SHELL
        .replace("__PRESETS__", &list)
        .replace("__FULL__", if full { "true" } else { "false" });
    fs::write(dir.join("shell.qml"), qml).map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    app::install_theme(&base)?;
    let timeout = Duration::from_secs(30 + 2 * presets.len() as u64);
    let (success, output) = app::run_quickshell(&base, &dir, shell, "en", timeout)?;
    for line in output.lines().filter(|line| {
        line.contains("THUMBNAILS_") || line.contains("thumbnails:") || line.contains("ERROR")
    }) {
        println!("{line}");
    }
    if !success || !output.contains("THUMBNAILS_PASS") {
        return Err(format!(
            "thumbnails failed ({name} {}); log: {}",
            shell.display(),
            base.display()
        ));
    }
    Ok(dir)
}
