//! The `studio` suite: Lock Studio (`studio/`) run as the app, offscreen.
//!
//! The app root is built the way `foamy-lock-helper studio open` builds it
//! (native/src/studio/root.rs: links to every `studio/` entry, the lock's
//! files and Omarchy's `Commons`, and a generated `qmldir`), in a temporary
//! HOME at `$XDG_CACHE_HOME/foamy-lock-studio/root`. For the test, three
//! entries differ: `LockView.qml` is the fixture-patched copy every suite
//! uses (fixed clock, network and battery), `fixtures/` holds those
//! stand-ins, and `StudioTest.qml` (studio.qml here) is the driver that the
//! real `shell.qml` loads when `FOAMY_LOCK_STUDIO_TEST=1`.
//!
//! The driver checks the window, focus and drawing, drives drags, resizes
//! and keys through the canvas's hooks and compares the look JSON, captures
//! the window (PNG, plus PPM for the pixel check here), and measures costs.
//! Then the harness raises the window with `quickshell ipc -p <root> call
//! studio raise`, as a second launch would. Plugin and studio QML warnings
//! fail it.

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::{app, host, styles};

const DRIVER: &str = include_str!("studio.qml");
/// The root's links into the plugin, and whether they're required (root.rs).
const PLUGIN_LINKS: [(&str, bool); 8] = [
    ("elements", true),
    ("kit", true),
    ("i18n", true),
    ("LockView.qml", true),
    ("Layout.js", true),
    ("Model.js", true),
    ("previews", false),
    ("bin", false),
];
const COMMONS: &str = "Commons";
const QMLDIR: &str = "qmldir";
const CAPTURES: [&str; 5] = [
    "studio-idle",
    "studio-dragging",
    "studio-wrong-password",
    "studio-problem",
    "studio-shortcuts",
];

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut language = "en".to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = || rest.next().cloned().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--host" => choice = value()?,
            "--language" => language = value()?,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    if language.is_empty()
        || !language
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err(format!("not a language code: {language:?}"));
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        if let Err(message) = run_host(name, shell, &language) {
            eprintln!("{message}");
            failed.push(name.clone());
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("studio failed: {}", failed.join(", ")))
    }
}

fn is_singleton(path: &Path) -> bool {
    let mut head = Vec::new();
    let read = fs::File::open(path).and_then(|file| file.take(8192).read_to_end(&mut head));
    read.is_ok()
        && String::from_utf8_lossy(&head)
            .lines()
            .any(|line| line.trim() == "pragma Singleton")
}

/// The root for `plugin` with `commons`, by root.rs's rules: (links, qmldir).
pub fn plan(plugin: &Path, commons: &Path) -> Result<(BTreeMap<String, PathBuf>, String), String> {
    let mut links = BTreeMap::new();
    let reserved = |name: &str| {
        name == QMLDIR || name == COMMONS || PLUGIN_LINKS.iter().any(|(fixed, _)| *fixed == name)
    };
    let studio = plugin.join("studio");
    for entry in fs::read_dir(&studio).map_err(app::io(studio.display()))? {
        let entry = entry.map_err(app::io(studio.display()))?;
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !name.starts_with('.') && !reserved(&name) {
            links.insert(name, entry.path());
        }
    }
    for (name, required) in PLUGIN_LINKS {
        let target = plugin.join(name);
        if fs::symlink_metadata(&target).is_ok() {
            links.insert(name.to_string(), target);
        } else if required {
            return Err(format!("{} lacks {name}", plugin.display()));
        }
    }
    links.insert(COMMONS.to_string(), commons.to_path_buf());
    Ok((links.clone(), qmldir(&links)))
}

/// One line per top-level `.qml` file whose name starts with an uppercase
/// letter, sorted (`singleton` for a `pragma Singleton` file).
fn qmldir(links: &BTreeMap<String, PathBuf>) -> String {
    let mut out = String::new();
    for (name, target) in links {
        if let Some(stem) = name.strip_suffix(".qml")
            && stem.starts_with(|c: char| c.is_ascii_uppercase())
        {
            let kind = if is_singleton(target) {
                "singleton "
            } else {
                ""
            };
            out.push_str(&format!("{kind}{stem} 1.0 {name}\n"));
        }
    }
    out
}

/// Build the test root: the planned links, with the fixture-patched view,
/// the fixtures and the driver in place of the lock's own view.
fn build_root(root: &Path, shell: &Path, out: &Path) -> Result<(), String> {
    let plugin = app::plugin_root()
        .canonicalize()
        .map_err(app::io("plugin"))?;
    let (mut links, _) = plan(&plugin, &shell.join("Commons"))?;
    links.remove("LockView.qml");
    fs::create_dir_all(root).map_err(app::io(root.display()))?;
    for (name, target) in &links {
        symlink(target, root.join(name)).map_err(app::io(name))?;
    }
    // The fixtures and the patched LockView, as every suite has them.
    let scratch = out.join("fixture-app");
    app::prepare(&scratch, shell)?;
    for name in ["LockView.qml", "fixtures"] {
        fs::rename(scratch.join(name), root.join(name)).map_err(app::io(name))?;
    }
    let _ = fs::remove_dir_all(&scratch);
    let driver = root.join("StudioTest.qml");
    fs::write(&driver, DRIVER).map_err(app::io("StudioTest.qml"))?;
    let mut registered = links.clone();
    registered.insert("LockView.qml".into(), root.join("LockView.qml"));
    registered.insert("StudioTest.qml".into(), driver);
    fs::write(root.join(QMLDIR), qmldir(&registered)).map_err(app::io("qmldir"))
}

/// Warnings from the plugin's or the studio's QML (and script errors).
fn warnings(log: &str) -> Vec<String> {
    let studio: Vec<String> = fs::read_dir(app::plugin_root().join("studio"))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| name.ends_with(".qml") || name.ends_with(".js"))
                .collect()
        })
        .unwrap_or_default();
    let mut found: Vec<String> = styles::qml_warnings(log)
        .into_iter()
        .map(String::from)
        .collect();
    for line in log.lines() {
        let warn = line.contains("WARN") || line.contains("ERROR");
        let ours = line.contains("StudioTest.qml")
            || studio.iter().any(|name| {
                line.contains(&format!("{name}[")) || line.contains(&format!("/{name}:"))
            });
        if warn && ours && !found.iter().any(|seen| seen == line) {
            found.push(line.to_string());
        }
    }
    found
}

/// A binary PPM (P6, 8-bit): (width, height, RGB bytes).
fn read_ppm(bytes: &[u8]) -> Option<(usize, usize, &[u8])> {
    let mut fields = Vec::new();
    let mut at = 0;
    while fields.len() < 4 {
        while at < bytes.len() && bytes[at].is_ascii_whitespace() {
            at += 1;
        }
        if bytes.get(at) == Some(&b'#') {
            while at < bytes.len() && bytes[at] != b'\n' {
                at += 1;
            }
            continue;
        }
        let start = at;
        while at < bytes.len() && !bytes[at].is_ascii_whitespace() {
            at += 1;
        }
        if start == at {
            return None;
        }
        fields.push(std::str::from_utf8(&bytes[start..at]).ok()?.to_string());
    }
    let (width, height): (usize, usize) = (fields[1].parse().ok()?, fields[2].parse().ok()?);
    if fields[0] != "P6" || fields[3] != "255" {
        return None;
    }
    let pixels = bytes.get(at + 1..at + 1 + width * height * 3)?;
    Some((width, height, pixels))
}

/// The standard deviation of the luminance inside a rectangle.
fn contrast(width: usize, height: usize, pixels: &[u8], rect: (i64, i64, i64, i64)) -> f64 {
    let (x0, y0) = (rect.0.max(0) as usize, rect.1.max(0) as usize);
    let x1 = ((rect.0 + rect.2).max(0) as usize).min(width);
    let y1 = ((rect.1 + rect.3).max(0) as usize).min(height);
    let (mut sum, mut squares, mut count) = (0f64, 0f64, 0f64);
    for y in y0..y1 {
        for x in x0..x1 {
            let p = &pixels[(y * width + x) * 3..][..3];
            let luma =
                0.2126 * f64::from(p[0]) + 0.7152 * f64::from(p[1]) + 0.0722 * f64::from(p[2]);
            sum += luma;
            squares += luma * luma;
            count += 1.0;
        }
    }
    if count == 0.0 {
        return 0.0;
    }
    let mean = sum / count;
    (squares / count - mean * mean).max(0.0).sqrt()
}

/// Every shown module's rectangle in the idle capture has drawn content.
fn check_drawn(output: &str, out: &Path) -> Result<(), String> {
    let line = output
        .lines()
        .find_map(|line| line.split("STUDIO_RECTS ").nth(1))
        .ok_or("no STUDIO_RECTS line")?;
    let rects: Value =
        serde_json::from_str(line.trim()).map_err(|error| format!("STUDIO_RECTS: {error}"))?;
    let path = out.join("studio-idle.ppm");
    let bytes = fs::read(&path).map_err(app::io(path.display()))?;
    let (width, height, pixels) =
        read_ppm(&bytes).ok_or(format!("{} isn't a P6 PPM", path.display()))?;
    let rects = rects.as_object().ok_or("STUDIO_RECTS isn't an object")?;
    if rects.len() < 6 {
        return Err(format!("only {} modules shown", rects.len()));
    }
    let mut report = Vec::new();
    for (name, rect) in rects {
        let field = |key: &str| rect.get(key).and_then(Value::as_i64).unwrap_or(0);
        let value = contrast(
            width,
            height,
            pixels,
            (field("x"), field("y"), field("width"), field("height")),
        );
        report.push(format!("{name} {value:.1}"));
        if value < 3.0 {
            return Err(format!(
                "{name} looks blank in the capture (contrast {value:.1}); {}",
                path.display()
            ));
        }
    }
    println!(
        "studio ok: modules drawn ({width}×{height} capture; contrast {})",
        report.join(", ")
    );
    Ok(())
}

/// `quickshell ipc -p <root> call studio raise` in the run's environment.
fn raise(root: &Path, env: &[(String, String)]) -> Result<String, String> {
    let mut child = Command::new("quickshell")
        .args(["ipc", "-p"])
        .arg(root)
        .args(["--no-color", "call", "studio", "raise"])
        .env_clear()
        .envs(env.iter().map(|(key, value)| (key, value)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(app::io("quickshell ipc"))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while child
        .try_wait()
        .map_err(app::io("quickshell ipc"))?
        .is_none()
    {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("quickshell ipc timed out".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let output = child
        .wait_with_output()
        .map_err(app::io("quickshell ipc"))?;
    if !output.status.success() {
        return Err(format!(
            "quickshell ipc failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub fn run_host(name: &str, shell: &Path, language: &str) -> Result<(), String> {
    let base = app::temp_dir("foamy-lock-studio")?;
    let out = base.join("captures");
    fs::create_dir_all(&out).map_err(app::io(out.display()))?;
    let root = base.join("home/.cache/foamy-lock-studio/root");
    build_root(&root, shell, &base)?;
    app::install_theme(&base)?;
    let out_text = out.display().to_string();
    let mut raised = None;
    let mut tick = |log: &str, env: &[(String, String)]| -> Result<(), String> {
        if raised.is_none() && log.contains("STUDIO_IPC_WAIT") {
            let answer = raise(&root, env)?;
            fs::write(out.join("ipc-done"), &answer).map_err(app::io("ipc-done"))?;
            raised = Some(answer);
        }
        Ok(())
    };
    let (success, output) = app::run_quickshell_with(
        &base,
        &root,
        shell,
        language,
        Duration::from_secs(120),
        &[
            ("FOAMY_LOCK_STUDIO_TEST", "1"),
            ("FOAMY_LOCK_STUDIO_OUT", &out_text),
        ],
        &mut tick,
    )?;
    for line in output.lines().filter(|line| {
        line.contains("studio ok") || line.contains("STUDIO_") || line.contains("ERROR")
    }) {
        if !line.contains("STUDIO_RECTS") {
            println!("{line}");
        }
    }
    let found = warnings(&output);
    if !success || !output.contains("STUDIO_PASS") || !found.is_empty() {
        return Err(format!(
            "studio failed ({name} {}){}; log: {}",
            shell.display(),
            found
                .iter()
                .map(|line| format!("\n  {line}"))
                .collect::<String>(),
            base.join("quickshell.log").display()
        ));
    }
    check_drawn(&output, &out)?;
    println!(
        "studio ok: raised over IPC ({})",
        raised.unwrap_or_default()
    );
    for capture in CAPTURES {
        println!("Capture: {}", out.join(format!("{capture}.png")).display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{plan, read_ppm};
    use std::path::Path;

    #[test]
    fn the_root_holds_the_app_and_the_lock() {
        let plugin = crate::app::plugin_root();
        let (links, qmldir) = plan(&plugin, Path::new("/usr/share/omarchy/shell/Commons")).unwrap();
        for name in [
            "shell.qml",
            "StudioWindow.qml",
            "Canvas.qml",
            "Checker.qml",
            "Draft.js",
            "elements",
            "kit",
            "i18n",
            "LockView.qml",
            "Layout.js",
            "Model.js",
            "previews",
            "bin",
            "Commons",
        ] {
            assert!(links.contains_key(name), "{name}");
        }
        assert_eq!(
            links["Commons"],
            Path::new("/usr/share/omarchy/shell/Commons")
        );
        assert!(qmldir.contains("Canvas 1.0 Canvas.qml\n"));
        assert!(qmldir.contains("LockView 1.0 LockView.qml\n"));
        assert!(!qmldir.contains("shell"), "{qmldir}");
        assert!(!qmldir.contains("singleton"), "{qmldir}");
        let mut lines: Vec<&str> = qmldir.lines().collect();
        let sorted = {
            let mut copy = lines.clone();
            copy.sort();
            copy
        };
        assert_eq!(lines, sorted);
        lines.dedup();
        assert_eq!(lines.len(), qmldir.lines().count());
    }

    #[test]
    fn ppm_header() {
        let mut bytes = b"P6\n# comment\n2 1\n255\n".to_vec();
        bytes.extend([1, 2, 3, 4, 5, 6]);
        let (w, h, pixels) = read_ppm(&bytes).unwrap();
        assert_eq!((w, h, pixels), (2, 1, &[1u8, 2, 3, 4, 5, 6][..]));
        assert!(read_ppm(b"P5\n2 1\n255\n\0\0").is_none());
        assert!(read_ppm(b"P6\n2 1\n255\n\0").is_none());
    }
}
