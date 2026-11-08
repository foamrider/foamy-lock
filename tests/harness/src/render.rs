//! The render test: the real LockView with synthetic data through every state
//! the view must handle, with a capture of each.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::{app, host, png, video};

const SHELL: &str = include_str!("render.qml");
/// The view size of each capture, in the order render.qml steps through them.
const SIZES: [(u32, u32); 9] = [
    (1920, 1080),
    (800, 1000),
    (1280, 720),
    (1280, 720),
    (1920, 1080),
    (800, 1000),
    (1920, 1080),
    (800, 1000),
    (1920, 1080),
];

/// An Omarchy language code such as `no` or `pt-BR`.
fn valid_language(code: &str) -> bool {
    let (base, region) = code.split_once('-').unwrap_or((code, ""));
    (2..=3).contains(&base.len())
        && base.bytes().all(|b| b.is_ascii_lowercase())
        && (code.len() == base.len()
            || (region.len() == 2 && region.bytes().all(|b| b.is_ascii_alphabetic())))
}

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
    if !valid_language(&language) {
        return Err(format!("not a language code: {language:?}"));
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        match run_host(name, shell, &language) {
            Ok(app) => keep_captures(&app, (choice == "both").then_some(name.as_str()))?,
            Err(message) => {
                eprintln!("{message}");
                failed.push(name.clone());
            }
        }
        // And a video background's switching (see video.rs).
        if let Err(message) = video::run_host(name, shell) {
            eprintln!("{message}");
            failed.push(format!("{name} video"));
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("render failed on host {}", failed.join(", ")))
    }
}

fn run_host(name: &str, shell: &Path, language: &str) -> Result<PathBuf, String> {
    let base = app::temp_dir("foamy-lock-render")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    // The view receives only a generated thumbnail, exactly as in production.
    let pixels: Vec<u8> = (0..256u32)
        .flat_map(|y| (0..256u32).flat_map(move |x| [30 + x / 3, 70 + y / 2, 130 + x / 4]))
        .map(|channel| channel as u8)
        .collect();
    fs::write(dir.join("artwork.png"), png::encode_rgb(256, 256, &pixels))
        .map_err(app::io("artwork.png"))?;
    fs::write(dir.join("shell.qml"), SHELL).map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let (success, output) =
        app::run_quickshell(&base, &dir, shell, language, Duration::from_secs(40))?;
    print!("{output}");
    if !success || !output.contains("PASS:") {
        return Err(format!(
            "render failed ({name} {}); log: {}",
            shell.display(),
            base.display()
        ));
    }
    // The preview banner's title in the languages the plugin ships (other
    // languages: any text; render.qml refuses an empty or undrawn one).
    let title = match language {
        "en" => "Preview",
        "no" => "Forhåndsvisning",
        _ => "",
    };
    if !output.contains(&format!("PASS: preview banner reads \"{title}")) {
        return Err(format!(
            "the preview banner doesn't read {title:?} ({name}, language {language}); log: {}",
            base.display()
        ));
    }
    for (index, expected) in SIZES.iter().enumerate() {
        let path = dir.join(format!("capture-{index}.png"));
        let bytes = fs::read(&path).map_err(app::io(path.display()))?;
        if png::size(&bytes) != Some(*expected) {
            return Err(format!(
                "{}: expected {expected:?}, found {:?}",
                path.display(),
                png::size(&bytes)
            ));
        }
    }
    // Every animation's still frame, the same twice (deterministic).
    if !output.contains("PASS: every animation's still frame") {
        return Err(format!("the animations' still frames are missing; log: {}", base.display()));
    }
    for name in app::drawn_sources()? {
        let path = dir.join(format!("capture-animation-{name}.png"));
        let bytes = fs::read(&path).map_err(app::io(path.display()))?;
        if png::size(&bytes) != Some((1920, 1080)) {
            return Err(format!("{}: expected 1920x1080, found {:?}", path.display(), png::size(&bytes)));
        }
        let again = dir.join(format!("capture-animation-{name}-again.png"));
        if fs::read(&again).map_err(app::io(again.display()))? != bytes {
            return Err(format!("the {name} still frame differs when drawn again: {}", dir.display()));
        }
    }
    println!(
        "Renders ({name} {}, language {language}): {}",
        shell.display(),
        dir.display()
    );
    Ok(dir)
}

/// With FOAMY_RENDER_OUT set, copy the captures there (per host with `both`).
fn keep_captures(app: &Path, host: Option<&str>) -> Result<(), String> {
    let Some(out) = std::env::var_os("FOAMY_RENDER_OUT").filter(|value| !value.is_empty()) else {
        return Ok(());
    };
    let out = host.map_or_else(
        || PathBuf::from(&out),
        |name| PathBuf::from(&out).join(name),
    );
    fs::create_dir_all(&out).map_err(app::io(out.display()))?;
    for index in 0..SIZES.len() {
        let name = format!("capture-{index}.png");
        fs::copy(app.join(&name), out.join(&name)).map_err(app::io(&name))?;
    }
    fs::copy(app.join("capture-banner.png"), out.join("capture-banner.png"))
        .map_err(app::io("capture-banner.png"))?;
    for name in app::drawn_sources()? {
        let file = format!("capture-animation-{name}.png");
        fs::copy(app.join(&file), out.join(&file)).map_err(app::io(&file))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::valid_language;

    #[test]
    fn language_codes() {
        for code in ["en", "no", "fil", "pt-BR", "zh-cn"] {
            assert!(valid_language(code), "{code}");
        }
        for code in ["", "e", "EN", "engl", "pt-", "pt-BRA", "pt_BR", "../x"] {
            assert!(!valid_language(code), "{code}");
        }
    }
}
