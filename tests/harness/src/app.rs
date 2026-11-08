//! The temporary Quickshell app: the plugin's view with fixtures in place of
//! the live services, and a bounded, hermetic quickshell run.

use std::fs;
use std::os::unix::fs::symlink;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::host;

const NETWORKING: &str = include_str!("../fixtures/Networking.qml");
const POWER: &str = include_str!("../fixtures/Power.qml");
/// PipeWire, Bluetooth and the keyboard layout, for the status items.
const SOURCES: &str = include_str!("../fixtures/Sources.qml");
const SOURCE_FILES: [(&str, &str); 3] = [
    (
        "VolumeSource.qml",
        include_str!("../fixtures/sources/VolumeSource.qml"),
    ),
    (
        "BluetoothSource.qml",
        include_str!("../fixtures/sources/BluetoothSource.qml"),
    ),
    (
        "KeyboardSource.qml",
        include_str!("../fixtures/sources/KeyboardSource.qml"),
    ),
];
const WALLPAPER: &str = include_str!("../fixtures/wallpaper.svg");
const ARTWORK: &str = include_str!("../fixtures/artwork.svg");
/// Fixed readings for the "system" status style in place of /proc.
const PROC: [(&str, &str); 3] = [
    ("uptime", include_str!("../fixtures/proc/uptime")),
    ("loadavg", include_str!("../fixtures/proc/loadavg")),
    ("meminfo", include_str!("../fixtures/proc/meminfo")),
];
/// The theme the thumbnails are drawn in (a hermetic HOME has none).
pub const THEME_COLORS: &str = include_str!("../fixtures/theme-colors.toml");
/// The fixed time every render shows.
const FIXED_DATE: &str = "new Date(2026, 8, 26, 10, 24)";

/// The plugin root (the harness lives in tests/harness).
pub fn plugin_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

pub fn io(context: impl std::fmt::Display) -> impl FnOnce(std::io::Error) -> String {
    move |error| format!("{context}: {error}")
}

/// A new directory under the system temp dir, kept afterwards as evidence.
pub fn temp_dir(prefix: &str) -> Result<PathBuf, String> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("{prefix}-{}-{nanos:08x}", std::process::id()));
    fs::create_dir(&dir).map_err(io(dir.display()))?;
    Ok(dir)
}

/// Point a LockView source at the fixtures instead of Networking, UPower,
/// PipeWire, Bluetooth, Hyprland and the wall clock. LockView owns those data
/// sources (the last three in elements/sources, which it loads by path);
/// elements/ don't touch them, so only this file needs patching.
pub fn patch_view(view: &str) -> String {
    view.replace("\"elements/sources/", "\"fixtures/sources/")
        .replace(
            "import Quickshell.Networking",
            "import \"fixtures\" as Fixture",
        )
        .replace("import Quickshell.Services.UPower\n", "")
        .replace("Networking.", "Fixture.Networking.")
        .replace("NetworkConnectivity.", "Fixture.Networking.")
        .replace("DeviceType.", "Fixture.Networking.")
        .replace("UPower.", "Fixture.Power.")
        .replace("UPowerDeviceState.", "Fixture.Power.")
        .replace("lockClock.date", FIXED_DATE)
}

/// Fill `app` with the plugin's current view, its kit, catalogs and
/// elements (linked, unmodified), the fixtures and the test images.
pub fn prepare(app: &Path, host_shell: &Path) -> Result<(), String> {
    let root = plugin_root();
    let write = |path: PathBuf, text: &str| fs::write(&path, text).map_err(io(path.display()));
    fs::create_dir_all(app.join("fixtures")).map_err(io(app.display()))?;
    symlink(host_shell.join("Commons"), app.join("Commons")).map_err(io("Commons"))?;
    for name in ["kit", "i18n", "elements"] {
        symlink(root.join(name), app.join(name)).map_err(io(name))?;
    }
    write(app.join("qmldir"), "")?;
    for script in ["Model.js", "Layout.js"] {
        let text = fs::read_to_string(root.join(script)).map_err(io(script))?;
        write(app.join(script), &text)?;
    }
    let view = fs::read_to_string(root.join("LockView.qml")).map_err(io("LockView.qml"))?;
    let proc = app.join("fixtures/proc");
    fs::create_dir_all(&proc).map_err(io(proc.display()))?;
    for (name, text) in PROC {
        write(proc.join(name), text)?;
    }
    let view = patch_view(&view).replace(
        "property string procRoot: \"/proc\"",
        &format!("property string procRoot: \"{}\"", proc.display()),
    );
    write(app.join("LockView.qml"), &view)?;
    write(
        app.join("fixtures/qmldir"),
        "module Fixture\nsingleton Networking 1.0 Networking.qml\nsingleton Power 1.0 Power.qml\nsingleton Sources 1.0 Sources.qml\n",
    )?;
    write(app.join("fixtures/Networking.qml"), NETWORKING)?;
    write(app.join("fixtures/Power.qml"), POWER)?;
    write(app.join("fixtures/Sources.qml"), SOURCES)?;
    fs::create_dir_all(app.join("fixtures/sources")).map_err(io("fixtures/sources"))?;
    for (name, text) in SOURCE_FILES {
        write(app.join("fixtures/sources").join(name), text)?;
    }
    write(app.join("wallpaper.svg"), WALLPAPER)?;
    write(app.join("artwork.svg"), ARTWORK)
}

/// Register the app's top-level view types beside the fixture singletons.
pub fn register_types(app: &Path) -> Result<(), String> {
    let mut registry = String::new();
    let mut entries: Vec<_> = fs::read_dir(app)
        .map_err(io(app.display()))?
        .flatten()
        .collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Some(stem) = name.strip_suffix(".qml")
            && stem.starts_with(|c: char| c.is_ascii_uppercase())
        {
            registry.push_str(&format!("{stem} 1.0 {name}\n"));
        }
    }
    fs::write(app.join("qmldir"), registry).map_err(io("qmldir"))
}

/// Run `quickshell -p app` offscreen under a private session bus, with a
/// temporary HOME and the Omarchy `language` (formats stay en_US), for at
/// most `timeout`. Returns (success, log).
pub fn run_quickshell(
    base: &Path,
    app: &Path,
    host_shell: &Path,
    language: &str,
    timeout: Duration,
) -> Result<(bool, String), String> {
    run_quickshell_with(
        base,
        app,
        host_shell,
        language,
        timeout,
        &[],
        &mut |_, _| Ok(()),
    )
}

/// The environment of a hermetic offscreen quickshell under `base` (HOME,
/// runtime dir and language file as run_quickshell sets them up), for
/// `quickshell ipc` calls into a running instance.
pub fn quickshell_env(base: &Path, host_shell: &Path) -> Vec<(String, String)> {
    let home = base.join("home");
    let omarchy = host_shell
        .parent()
        .unwrap_or(host_shell)
        .display()
        .to_string();
    let mut env = host::hermetic(
        &home,
        &base.join("runtime"),
        &home.join(".config/omarchy/language"),
    );
    env.extend(
        [
            ("OMARCHY_PATH", omarchy.as_str()),
            ("QT_QPA_PLATFORM", "offscreen"),
            ("QT_QUICK_BACKEND", "software"),
            ("QT_QPA_PLATFORMTHEME", "basic"),
            ("QT_STYLE_OVERRIDE", "Fusion"),
            ("LANG", "en_US.UTF-8"),
            ("LC_ALL", "en_US.UTF-8"),
            ("LC_TIME", "en_US.UTF-8"),
        ]
        .map(|(key, value)| (key.to_string(), value.to_string())),
    );
    env
}

/// Called with the log so far and the environment while quickshell runs.
pub type Tick<'a> = dyn FnMut(&str, &[(String, String)]) -> Result<(), String> + 'a;

/// run_quickshell with `extra` environment variables, calling `tick` with
/// the log so far (and the environment) about every 100 ms while it runs.
pub fn run_quickshell_with(
    base: &Path,
    app: &Path,
    host_shell: &Path,
    language: &str,
    timeout: Duration,
    extra: &[(&str, &str)],
    tick: &mut Tick,
) -> Result<(bool, String), String> {
    let home = base.join("home");
    let runtime = base.join("runtime");
    let language_file = home.join(".config/omarchy/language");
    fs::create_dir_all(language_file.parent().unwrap_or(&home)).map_err(io("home"))?;
    fs::create_dir(&runtime).map_err(io("runtime"))?;
    fs::set_permissions(
        &runtime,
        std::os::unix::fs::PermissionsExt::from_mode(0o700),
    )
    .map_err(io("runtime"))?;
    fs::write(&language_file, format!("{language}\n")).map_err(io("language"))?;
    let env = quickshell_env(base, host_shell);
    let log_path = base.join("quickshell.log");
    let log = fs::File::create(&log_path).map_err(io(log_path.display()))?;
    let mut child = Command::new("dbus-run-session")
        .args(["--", "quickshell", "-p"])
        .arg(app)
        .arg("--no-color")
        .env_clear()
        .envs(env.iter().map(|(key, value)| (key, value)))
        .envs(extra.iter().copied())
        .stdin(Stdio::null())
        .stdout(log.try_clone().map_err(io("log"))?)
        .stderr(log)
        .process_group(0)
        .spawn()
        .map_err(io("dbus-run-session quickshell"))?;
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait().map_err(io("quickshell"))? {
            break Some(status);
        }
        let ticked = fs::read_to_string(&log_path)
            .map_err(io(log_path.display()))
            .and_then(|log| tick(&log, &env));
        if ticked.is_err() || Instant::now() >= deadline {
            // The whole group: dbus-run-session, its bus and quickshell.
            let _ = Command::new("kill")
                .arg("-TERM")
                .arg(format!("-{}", child.id()))
                .status();
            let _ = child.wait();
            ticked?;
            break None;
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    let output = fs::read_to_string(&log_path).map_err(io(log_path.display()))?;
    match status {
        Some(status) => Ok((status.success(), output)),
        None => Err(format!("quickshell timed out after {timeout:?}:\n{output}")),
    }
}

/// The selectable presets, read from Layout.js (`var SELECTABLE_PRESETS = [...]`),
/// so the harness never lags behind the model.
pub fn selectable_presets() -> Result<Vec<String>, String> {
    let layout = fs::read_to_string(plugin_root().join("Layout.js")).map_err(io("Layout.js"))?;
    parse_presets(&layout).ok_or_else(|| "no SELECTABLE_PRESETS in Layout.js".to_string())
}

fn parse_presets(layout: &str) -> Option<Vec<String>> {
    let start = layout.find("var SELECTABLE_PRESETS = [")?;
    let list = &layout[start..];
    let list = &list[list.find('[')? + 1..list.find(']')?];
    let names: Vec<String> = list
        .split(',')
        .map(|item| item.trim().trim_matches('"').to_string())
        .filter(|name| !name.is_empty())
        .collect();
    (!names.is_empty()).then_some(names)
}

/// Write the thumbnails' theme into `base`'s hermetic HOME (before
/// run_quickshell), where Omarchy's Color singleton looks for it.
pub fn install_theme(base: &Path) -> Result<(), String> {
    let theme = base.join("home/.local/state/omarchy/current/theme");
    fs::create_dir_all(&theme).map_err(io(theme.display()))?;
    fs::write(theme.join("colors.toml"), THEME_COLORS).map_err(io("colors.toml"))
}

/// `$FOAMY_RENDER_OUT/<sub>` when FOAMY_RENDER_OUT asks for a copy of the
/// captures, else None.
pub fn render_out(sub: &str) -> Option<PathBuf> {
    std::env::var_os("FOAMY_RENDER_OUT")
        .filter(|value| !value.is_empty())
        .map(|out| Path::new(&out).join(sub))
}

/// Copy the app's `capture-*.png` files to `out`.
pub fn copy_captures(app: &Path, out: &Path) -> Result<(), String> {
    fs::create_dir_all(out).map_err(io(out.display()))?;
    for entry in fs::read_dir(app).map_err(io(app.display()))?.flatten() {
        let file = entry.file_name().to_string_lossy().into_owned();
        if file.starts_with("capture-") && file.ends_with(".png") {
            fs::copy(entry.path(), out.join(&file)).map_err(io(&file))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_presets;

    #[test]
    fn presets_come_from_layout_js() {
        let layout = "var X = [\"no\"]\nvar SELECTABLE_PRESETS = [\"foamy\", \"corner\",\n  \"dock\"]\nvar DEFAULT_PRESET = \"foamy\"";
        assert_eq!(parse_presets(layout).unwrap(), ["foamy", "corner", "dock"]);
        assert!(parse_presets("var SELECTABLE_PRESETS = []").is_none());
        assert!(parse_presets("").is_none());
        let real = super::selectable_presets().unwrap();
        assert_eq!(&real[..4], ["foamy", "corner", "editorial", "zen"]);
    }
}
