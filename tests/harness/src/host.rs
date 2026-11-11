//! Host shells and the hermetic environment for the offscreen tests.

use std::path::{Path, PathBuf};

pub const CHOICES: [&str; 1] = ["4.5"];
const INSTALLED: &str = "/usr/share/omarchy/shell";

/// The Omarchy 4.5 shell: `FOAMY_HOST_45`, else `$OMARCHY_TEST_ROOT/shell`,
/// else the installed one.
fn shell() -> PathBuf {
    let var = |key: &str| std::env::var_os(key).filter(|value| !value.is_empty());
    if let Some(path) = var("FOAMY_HOST_45") {
        return PathBuf::from(path);
    }
    if let Some(root) = var("OMARCHY_TEST_ROOT") {
        return PathBuf::from(root).join("shell");
    }
    PathBuf::from(INSTALLED)
}

/// The (name, shell directory) pairs to test: Omarchy 4.5, the only
/// supported host.
pub fn selected(choice: &str) -> Result<Vec<(String, PathBuf)>, String> {
    if !CHOICES.contains(&choice) {
        return Err(format!(
            "unknown host {choice:?}; use {} (Omarchy 4.0 is no longer supported)",
            CHOICES.join(", ")
        ));
    }
    let path = shell();
    if !path.join("Commons").is_dir() {
        return Err(format!(
            "host {choice} not found at {} (set FOAMY_HOST_45)",
            path.display()
        ));
    }
    Ok(vec![(choice.to_string(), path)])
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
