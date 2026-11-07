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
const WALLPAPER: &str = include_str!("../fixtures/wallpaper.svg");
const ARTWORK: &str = include_str!("../fixtures/artwork.svg");
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

/// Point a LockView source at the fixtures instead of Networking, UPower and
/// the wall clock. LockView owns those data sources; elements/ don't touch
/// them, so only this file needs patching.
pub fn patch_view(view: &str) -> String {
    view.replace(
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
    write(app.join("LockView.qml"), &patch_view(&view))?;
    write(
        app.join("fixtures/qmldir"),
        "module Fixture\nsingleton Networking 1.0 Networking.qml\nsingleton Power 1.0 Power.qml\n",
    )?;
    write(app.join("fixtures/Networking.qml"), NETWORKING)?;
    write(app.join("fixtures/Power.qml"), POWER)?;
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
    let omarchy = host_shell
        .parent()
        .unwrap_or(host_shell)
        .display()
        .to_string();
    let log_path = base.join("quickshell.log");
    let log = fs::File::create(&log_path).map_err(io(log_path.display()))?;
    let mut child = Command::new("dbus-run-session")
        .args(["--", "quickshell", "-p"])
        .arg(app)
        .arg("--no-color")
        .env_clear()
        .envs(host::hermetic(&home, &runtime, &language_file))
        .envs([
            ("OMARCHY_PATH", omarchy.as_str()),
            ("QT_QPA_PLATFORM", "offscreen"),
            ("QT_QUICK_BACKEND", "software"),
            ("QT_QPA_PLATFORMTHEME", "basic"),
            ("QT_STYLE_OVERRIDE", "Fusion"),
            ("LANG", "en_US.UTF-8"),
            ("LC_ALL", "en_US.UTF-8"),
            ("LC_TIME", "en_US.UTF-8"),
        ])
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
        if Instant::now() >= deadline {
            // The whole group: dbus-run-session, its bus and quickshell.
            let _ = Command::new("kill")
                .arg("-TERM")
                .arg(format!("-{}", child.id()))
                .status();
            let _ = child.wait();
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
