//! Host shells and the hermetic environment, as in tests/hosts.py.

use std::path::{Path, PathBuf};

pub const CHOICES: [&str; 3] = ["4.5", "4.0", "both"];
const INSTALLED: &str = "/usr/share/omarchy/shell";

fn shell(name: &str) -> Option<PathBuf> {
    let var = |key: &str| std::env::var_os(key).filter(|value| !value.is_empty());
    if name == "4.0" {
        return var("FOAMY_HOST_40").map(PathBuf::from);
    }
    if let Some(path) = var("FOAMY_HOST_45") {
        return Some(PathBuf::from(path));
    }
    if let Some(root) = var("OMARCHY_TEST_ROOT") {
        return Some(PathBuf::from(root).join("shell"));
    }
    Some(PathBuf::from(INSTALLED))
}

/// The (name, shell directory) pairs to test. Prints a SKIP line for 4.0
/// without `FOAMY_HOST_40`.
pub fn selected(choice: &str) -> Result<Vec<(String, PathBuf)>, String> {
    let names: &[&str] = match choice {
        "both" => &["4.5", "4.0"],
        "4.5" => &["4.5"],
        "4.0" => &["4.0"],
        other => {
            return Err(format!(
                "unknown host {other:?}; use {}",
                CHOICES.join(", ")
            ));
        }
    };
    let mut chosen = Vec::new();
    for name in names {
        let Some(path) = shell(name) else {
            println!("SKIP: host 4.0 (set FOAMY_HOST_40 to an Omarchy 4.0 shell directory)");
            continue;
        };
        if !path.join("Commons").is_dir() {
            return Err(format!(
                "host {name} not found at {} (set FOAMY_HOST_{})",
                path.display(),
                name.replace('.', "")
            ));
        }
        chosen.push((name.to_string(), path));
    }
    Ok(chosen)
}

/// The current environment without the desktop's XDG, display, language and
/// Omarchy settings: HOME and every XDG base directory live under `home`.
pub fn hermetic(home: &Path, runtime: &Path, language_file: &Path) -> Vec<(String, String)> {
    const DROPPED: [&str; 6] = [
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "DBUS_SESSION_BUS_ADDRESS",
        "LANGUAGE",
        "QT_SCALE_FACTOR",
    ];
    let mut env: Vec<(String, String)> = std::env::vars()
        .filter(|(key, _)| {
            let desktop = key.starts_with("XDG_")
                || key.starts_with("OMARCHY_")
                || key.starts_with("FOAMY_LOCK_TEST_");
            !desktop && !DROPPED.contains(&key.as_str())
        })
        .collect();
    let at = |relative: &str| home.join(relative).display().to_string();
    env.extend([
        ("HOME".into(), home.display().to_string()),
        ("XDG_CONFIG_HOME".into(), at(".config")),
        ("XDG_CACHE_HOME".into(), at(".cache")),
        ("XDG_DATA_HOME".into(), at(".local/share")),
        ("XDG_STATE_HOME".into(), at(".local/state")),
        ("XDG_RUNTIME_DIR".into(), runtime.display().to_string()),
        (
            "OMARCHY_LANGUAGE_FILE".into(),
            language_file.display().to_string(),
        ),
    ]);
    for key in ["XDG_DATA_DIRS", "XDG_CONFIG_DIRS"] {
        if let Ok(value) = std::env::var(key) {
            env.push((key.into(), value));
        }
    }
    env
}
