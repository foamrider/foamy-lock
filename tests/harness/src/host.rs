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

/// Omarchy's bin directories: the installed one, the tested shell's tree
/// and the caller's `$OMARCHY_PATH/bin`, resolved.
fn host_bins() -> Vec<PathBuf> {
    let mut bins = vec![PathBuf::from("/usr/share/omarchy/bin")];
    if let Some(tree) = shell().parent() {
        bins.push(tree.join("bin"));
    }
    if let Some(path) = std::env::var_os("OMARCHY_PATH").filter(|value| !value.is_empty()) {
        bins.push(PathBuf::from(path).join("bin"));
    }
    bins.iter()
        .filter_map(|bin| bin.canonicalize().ok())
        .collect()
}

/// `value` (a `:` list) without an AppImage's `$APPDIR` entries.
fn without_appdir(value: &str) -> Vec<&str> {
    let appdir = std::env::var("APPDIR").unwrap_or_default();
    let appdir = appdir.trim_end_matches('/');
    value
        .split(':')
        .filter(|entry| {
            !entry.is_empty()
                && (appdir.is_empty()
                    || (*entry != appdir && !entry.starts_with(&format!("{appdir}/"))))
        })
        .collect()
}

/// The caller's PATH without Omarchy's bin directories or `$APPDIR`, behind
/// `home/.host-stubs`: one stub for every other `omarchy`/`omarchy-*`
/// command on it (Omarchy installs them in /usr/bin too), which logs its
/// call to `$HOME/host-commands.log` and exits 127. A test fakes each host
/// command it means to run in its own bin, ahead of this PATH, so nothing
/// it didn't fake reaches the real desktop (foamy-kit's harness does the
/// same).
fn isolated_path(home: &Path) -> String {
    let path = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
    let bins = host_bins();
    let kept: Vec<&str> = without_appdir(&path)
        .into_iter()
        .filter(|entry| {
            !Path::new(entry)
                .canonicalize()
                .is_ok_and(|real| bins.contains(&real))
        })
        .collect();
    let stubs = home.join(".host-stubs");
    if !stubs.is_dir() && std::fs::create_dir_all(&stubs).is_ok() {
        use std::os::unix::fs::PermissionsExt;
        let log = home.join("host-commands.log");
        for entry in &kept {
            let Ok(names) = std::fs::read_dir(entry) else {
                continue;
            };
            for name in names.flatten().map(|item| item.file_name()) {
                let Some(name) = name.to_str() else { continue };
                if name != "omarchy" && !name.starts_with("omarchy-") {
                    continue;
                }
                let stub = stubs.join(name);
                let body = format!(
                    "#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> '{}'\nexit 127\n",
                    log.display()
                );
                if std::fs::write(&stub, body).is_ok() {
                    let _ = std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755));
                }
            }
        }
    }
    let mut entries = vec![stubs.display().to_string()];
    entries.extend(kept.into_iter().map(str::to_string));
    entries.join(":")
}

/// The host commands a hermetic run under `home` called that no fake
/// stood in for (empty when there were none).
pub fn host_commands(home: &Path) -> String {
    std::fs::read_to_string(home.join("host-commands.log")).unwrap_or_default()
}

/// `key`'s value in `env`.
pub fn get<'a>(env: &'a [(String, String)], key: &str) -> &'a str {
    env.iter()
        .rev()
        .find(|(name, _)| name == key)
        .map_or("", |(_, value)| value.as_str())
}

/// The current environment without the desktop's XDG, display, language and
/// Omarchy settings: HOME and every XDG base directory live under `home`.
/// Host commands, audio servers and the system bus are out of reach too
/// (see [`isolated_path`]): PULSE_SERVER and PIPEWIRE_REMOTE name dead
/// sockets and DBUS_SYSTEM_BUS_ADDRESS a dead address under `home`.
pub fn hermetic(home: &Path, runtime: &Path, language_file: &Path) -> Vec<(String, String)> {
    const DROPPED: [&str; 12] = [
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "DBUS_SESSION_BUS_ADDRESS",
        "DBUS_SYSTEM_BUS_ADDRESS",
        "LANGUAGE",
        "QT_SCALE_FACTOR",
        "PATH",
        "LD_LIBRARY_PATH",
        "PULSE_RUNTIME_PATH",
        "PIPEWIRE_RUNTIME_DIR",
        "PULSE_COOKIE",
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
        ("PATH".into(), isolated_path(home)),
        ("PULSE_SERVER".into(), format!("unix:{}", at("no-pulse"))),
        ("PIPEWIRE_REMOTE".into(), at("no-pipewire")),
        (
            "DBUS_SYSTEM_BUS_ADDRESS".into(),
            format!("unix:path={}", at("no-system-bus")),
        ),
    ]);
    let libraries = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
    let libraries = without_appdir(&libraries).join(":");
    if !libraries.is_empty() {
        env.push(("LD_LIBRARY_PATH".into(), libraries));
    }
    for key in ["XDG_DATA_DIRS", "XDG_CONFIG_DIRS"] {
        if let Ok(value) = std::env::var(key) {
            env.push((key.into(), value));
        }
    }
    env
}
