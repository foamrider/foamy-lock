//! The placement cases: scale, opacity, offset, glass and screens on one
//! view: the geometry codes they produce, mirrored offsets, a primary-only
//! element on a secondary view, decorations that keep fitting the un-offset
//! zones, and `latchFallback: false` reporting without switching. Shapes
//! too: module shapes follow their modules, and each PLACEMENT_PIXELS pair
//! (a module alone, then under a zero-padding box that absorbs it) must be
//! the same picture, pixel for pixel.

use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::{app, host, studio, styles};

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
    let pixels = if success {
        same_pixels(&dir, &output)
    } else {
        Ok(0)
    };
    if let (true, Ok(count)) = (success, &pixels) {
        println!("placement ok: {count} absorbed surfaces drawn exactly as their own");
    }
    if !success || !output.contains("PLACEMENT_PASS") || !warnings.is_empty() || pixels.is_err() {
        return Err(format!(
            "placement failed ({name} {}){}; log: {}",
            shell.display(),
            warnings
                .iter()
                .map(|line| format!("\n  {line}"))
                .chain(pixels.err().map(|error| format!("\n  {error}")))
                .collect::<String>(),
            base.display()
        ));
    }
    Ok(())
}

/// Every PLACEMENT_PIXELS pair is the same image; how many pairs there were.
fn same_pixels(dir: &Path, output: &str) -> Result<usize, String> {
    let mut pairs = 0;
    for line in output.lines() {
        let Some(at) = line.find("PLACEMENT_PIXELS ") else {
            continue;
        };
        let fields: Vec<&str> = line[at + 17..].split_whitespace().collect();
        let [first, second, ..] = fields[..] else {
            return Err(format!("a bad PLACEMENT_PIXELS line: {line}"));
        };
        let read = |name: &str| fs::read(dir.join(name)).map_err(app::io(name));
        let (a, b) = (read(first)?, read(second)?);
        let (aw, ah, ap) = studio::read_ppm(&a).ok_or(format!("{first} isn't a P6 PPM"))?;
        let (bw, bh, bp) = studio::read_ppm(&b).ok_or(format!("{second} isn't a P6 PPM"))?;
        if (aw, ah) != (bw, bh) {
            return Err(format!("{first} is {aw}x{ah}, {second} {bw}x{bh}"));
        }
        if let Some(index) = (0..ap.len()).find(|&i| ap[i] != bp[i]) {
            let pixel = index / 3;
            let differing = (0..ap.len() / 3)
                .filter(|&p| ap[p * 3..p * 3 + 3] != bp[p * 3..p * 3 + 3])
                .count();
            return Err(format!(
                "{second} differs from {first} ({}): {differing} pixels, the first at {}, {}",
                fields[2..].join(" "),
                pixel % aw,
                pixel / aw
            ));
        }
        pairs += 1;
    }
    if pairs == 0 {
        return Err("no PLACEMENT_PIXELS pairs".to_string());
    }
    Ok(pairs)
}
