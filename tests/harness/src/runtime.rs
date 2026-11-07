//! The runtime test: the real Service.qml in an offscreen Quickshell with a
//! simulated session lock, PAM and view, stand-in desktop commands on PATH, a
//! fake Omarchy tree and shell.json, driven over `quickshell ipc` and checked
//! through `lock status`. It never locks the desktop or authenticates a user.

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::process::CommandExt;
use std::panic::Location;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};

use crate::{app, host, png};

type R<T = ()> = Result<T, String>;

const SHELL: &str = include_str!("runtime.qml");
const SESSION_LOCK: &str = include_str!("../fixtures/mocks/SessionLock.qml");
const PAM_CONTEXT: &str = include_str!("../fixtures/mocks/PamContext.qml");
const LOCK_VIEW: &str = include_str!("../fixtures/mocks/LockView.qml");
const PNG_MAGIC: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
/// shell.json's default: the stock lock plugin is disabled.
const STOCK_OFF: &[&str] = &["omarchy.lock"];
const ENROLLED: &str = "found 1 devices\n - #0: right-index-finger\n";
const PROBE_ERROR: &str = "D-Bus activation failed\n";

/// Every command that could affect the desktop, replaced; identity probes
/// also answer with test data. (name, script body after `#!/bin/sh`.)
const COMMANDS: [(&str, &str); 8] = [
    (
        "getent",
        r#"printf "fixture:x:1000:1000:Foamy User:%s:/bin/sh\n" "$HOME""#,
    ),
    ("busctl", "exit 1"),
    ("magick", "exit 1"),
    (
        "fprintd-list",
        r#"cat "$HOME/fingerprint-output" 2>/dev/null || echo no"#,
    ),
    (
        "omarchy-hyprland-session-lock-stranded",
        "printf \"%s\\n\" \"$1\" > \"$HOME/stranded-parent\"\nexit \"$(cat \"$HOME/stranded-result\" 2>/dev/null || echo 1)\"",
    ),
    (
        "omarchy-system-wake",
        r#"printf "%s\n" "omarchy-system-wake" >> "$HOME/calls""#,
    ),
    (
        "omarchy-brightness-keyboard",
        r#"printf "%s\n" "omarchy-brightness-keyboard" >> "$HOME/calls""#,
    ),
    (
        "omarchy-brightness-display",
        r#"printf "%s\n" "omarchy-brightness-display" >> "$HOME/calls""#,
    ),
];

/// Fail the current check with the line it is on.
macro_rules! ensure {
    ($cond:expr) => {
        ensure!($cond, "{}", stringify!($cond))
    };
    ($cond:expr, $($message:tt)+) => {
        let holds: bool = $cond;
        if !holds {
            return Err(format!("runtime.rs:{}: {}", line!(), format!($($message)+)));
        }
    };
}

pub fn run(args: &[String]) -> R {
    let mut choice = "4.5".to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--host" => choice = rest.next().cloned().ok_or("--host needs a value")?,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        println!("Host {name}: {}", shell.display());
        if let Err(message) = run_host(shell) {
            eprintln!("{message}");
            failed.push(name.clone());
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("runtime failed on host {}", failed.join(", ")))
    }
}

/// Point Service.qml at the mocks and the PAM fixture, and expose the timers
/// and PAM contexts the test drives. Every pattern must still be there.
fn patch_service(service: &str, pam: &Path) -> R<String> {
    let pam = pam.display().to_string();
    let aliases = "  id: root
  property alias testPasswordPam: passwordPam
  property alias testFingerprintPam: fingerprintPam
  property alias testRetry: fingerprintRetryTimer
  property alias testProbeRetry: fingerprintRecheckTimer
  property alias testResume: fingerprintResumeTimer
  property bool testStaleLocked: false";
    let replacements = [
        ("import Quickshell.Wayland", "import \"mocks\" as Mock"),
        ("  id: root", aliases),
        (
            "readonly property bool locked: lockRequested",
            "readonly property bool locked: testStaleLocked || lockRequested",
        ),
        ("  WlSessionLock {", "  Mock.SessionLock {"),
        ("    WlSessionLockSurface {", "    Rectangle {"),
        ("  PamContext {", "  Mock.PamContext {"),
        ("LockView {", "Mock.LockView {"),
        ("  PanelWindow {", "  Rectangle {"),
        (
            "    anchors { top: true; bottom: true; left: true; right: true }",
            "    width: 800; height: 600",
        ),
        (
            "var screens = Quickshell.screens || []",
            "var screens = [{ name: \"fixture\", width: 1920, height: 1080 }]",
        ),
        // Both PAM services are fixtures; enrollment must not depend on host setup.
        ("/etc/pam.d/omarchy-lock-password", &pam),
        ("/etc/pam.d/omarchy-lock-fingerprint", &pam),
    ];
    let mut text = service.to_string();
    for (from, to) in replacements {
        if !text.contains(from) {
            return Err(format!(
                "Service.qml no longer contains {from:?}; update runtime.rs"
            ));
        }
        text = text.replace(from, to);
    }
    // The preview window's layer-shell properties have no Rectangle equivalent.
    Ok(text
        .split_inclusive('\n')
        .filter(|line| {
            !(line.ends_with('\n')
                && line.strip_prefix("    ").is_some_and(|rest| {
                    rest.starts_with("WlrLayershell.") || rest.starts_with("exclusionMode:")
                }))
        })
        .collect())
}

/// Python truthiness, which the checks below were written against.
fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::Number(value) => value.as_f64() != Some(0.0),
        Value::String(value) => !value.is_empty(),
        Value::Array(value) => !value.is_empty(),
        Value::Object(value) => !value.is_empty(),
    }
}

/// The member at a dotted `path`; a missing one is an error.
fn at<'a>(value: &'a Value, path: &str) -> R<&'a Value> {
    path.split('.').try_fold(value, |value, key| {
        value
            .get(key)
            .ok_or_else(|| format!("no {path:?} in {value}"))
    })
}

fn on(value: &Value, path: &str) -> R<bool> {
    at(value, path).map(truthy)
}

fn num(value: &Value, path: &str) -> R<f64> {
    let found = at(value, path)?;
    found
        .as_f64()
        .ok_or_else(|| format!("{path:?} is not a number: {found}"))
}

fn text<'a>(value: &'a Value, path: &str) -> R<&'a str> {
    let found = at(value, path)?;
    found
        .as_str()
        .ok_or_else(|| format!("{path:?} is not a string: {found}"))
}

fn parse(reply: &str) -> R<Value> {
    serde_json::from_str(reply).map_err(|error| format!("not JSON ({error}): {reply:?}"))
}

fn write(path: &Path, contents: impl AsRef<[u8]>) -> R {
    fs::write(path, contents).map_err(app::io(path.display()))
}

fn read(path: &Path) -> R<String> {
    fs::read_to_string(path).map_err(app::io(path.display()))
}

fn link(target: impl AsRef<Path>, path: &Path) -> R {
    symlink(target, path).map_err(app::io(path.display()))
}

fn unlink(path: &Path) -> R {
    fs::remove_file(path).map_err(app::io(path.display()))
}

fn ms(millis: u64) {
    sleep(Duration::from_millis(millis));
}

/// Signal a process group (std has no killpg).
fn kill_group(child: &Child, signal: &str) {
    let _ = Command::new("kill")
        .arg(format!("-{signal}"))
        .arg(format!("-{}", child.id()))
        .stderr(Stdio::null())
        .status();
}

/// The temporary app, its home and the environment quickshell runs in.
struct Test {
    base: PathBuf,
    app: PathBuf,
    env: BTreeMap<String, String>,
    config: PathBuf,
    background: PathBuf,
    poster: PathBuf,
    has_registry: bool,
}

impl Test {
    fn create(base: &Path, shell: &Path) -> R<Self> {
        let source = app::plugin_root();
        let commons = shell.join("Commons");
        let app = base.join("app");
        let mkdir = |path: &Path| fs::create_dir_all(path).map_err(app::io(path.display()));
        mkdir(&app.join("mocks"))?;
        link(&commons, &app.join("Commons"))?;
        // The plugin's stamped kit (FoamyIpc, FoamyI18n) and catalogs, unmodified.
        for name in ["kit", "i18n", "bin"] {
            link(source.join(name), &app.join(name))?;
        }
        // Model.js, FingerprintModel.js and any other script Service.qml may import.
        let mut copies = vec!["Artwork.qml".to_string()];
        for entry in fs::read_dir(&source).map_err(app::io(source.display()))? {
            let name = entry.map_err(app::io("plugin root"))?.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".js") {
                copies.push(name.into_owned());
            }
        }
        for name in &copies {
            write(
                &app.join(name),
                fs::read(source.join(name)).map_err(app::io(name))?,
            )?;
        }
        write(&app.join("mocks/SessionLock.qml"), SESSION_LOCK)?;
        write(&app.join("mocks/PamContext.qml"), PAM_CONTEXT)?;
        write(&app.join("mocks/LockView.qml"), LOCK_VIEW)?;
        let pam = base.join("pam-password");
        write(&pam, "")?;
        let service = read(&source.join("Service.qml"))?;
        write(&app.join("Service.qml"), patch_service(&service, &pam)?)?;
        write(&app.join("shell.qml"), SHELL)?;
        app::register_types(&app)?;

        let runtime = base.join("runtime");
        mkdir(&runtime)?;
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700))
            .map_err(app::io("runtime"))?;
        let bin = base.join("bin");
        mkdir(&bin)?;
        for (name, body) in COMMANDS {
            let path = bin.join(name);
            write(&path, format!("#!/bin/sh\n{body}\n"))?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
                .map_err(app::io(path.display()))?;
        }
        let omarchy = base.join("omarchy");
        let poster = omarchy.join("shell/plugins/lock/poster.sh");
        let background = base.join(".local/state/omarchy/current/background");
        let config = base.join(".config/omarchy/shell.json");
        for path in [&poster, &background, &config] {
            mkdir(path.parent().unwrap_or(base))?;
        }
        // A real account picture goes through the sandboxed helper into the cache.
        let face: Vec<u8> = [200, 80, 40].repeat(256 * 256);
        write(&base.join(".face"), png::encode_rgb(256, 256, &face))?;

        // No desktop config, language, compositor or session bus reaches the shell.
        let mut env: BTreeMap<String, String> =
            host::hermetic(base, &runtime, &base.join("no-language"))
                .into_iter()
                .filter(|(key, _)| key != "OMARCHY_LANGUAGE_FILE")
                .collect();
        let path = format!(
            "{}:{}",
            bin.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        for (key, value) in [
            ("USER", "fixture".to_string()),
            ("LOGNAME", "fixture".to_string()),
            ("XDG_CACHE_HOME", base.join("cache").display().to_string()),
            ("OMARCHY_PATH", omarchy.display().to_string()),
            ("QT_QPA_PLATFORM", "offscreen".to_string()),
            ("QT_QPA_PLATFORMTHEME", "basic".to_string()),
            ("QT_STYLE_OVERRIDE", "Fusion".to_string()),
            ("PATH", path),
        ] {
            env.insert(key.to_string(), value);
        }
        let test = Test {
            base: base.to_path_buf(),
            app,
            env,
            config,
            background,
            poster,
            has_registry: commons.join("IpcRegistry.qml").exists(),
        };
        test.write_config(STOCK_OFF, json!({}))?;
        Ok(test)
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.base.join(relative)
    }

    fn write_config(&self, disabled: &[&str], settings: Value) -> R {
        let mut plugin = json!({"id": "foamy.lock"});
        if let (Some(plugin), Value::Object(settings)) = (plugin.as_object_mut(), settings) {
            plugin.extend(settings);
        }
        let config =
            json!({"version": 1, "plugins": [plugin], "disabledPlugins": disabled}).to_string();
        write(&self.config, config)
    }

    /// Point the wallpaper link at `target` (None removes it).
    fn background(&self, target: Option<&Path>) -> R {
        if self.background.symlink_metadata().is_ok() {
            unlink(&self.background)?;
        }
        target.map_or(Ok(()), |target| link(target, &self.background))
    }

    fn spawn(&self, log_path: &Path) -> R<Child> {
        let log = fs::File::create(log_path).map_err(app::io(log_path.display()))?;
        Command::new("dbus-run-session")
            .args(["--", "quickshell", "-p"])
            .arg(&self.app)
            .arg("--no-color")
            .env_clear()
            .envs(&self.env)
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(app::io("log"))?)
            .stderr(log)
            .process_group(0)
            .spawn()
            .map_err(app::io("dbus-run-session quickshell"))
    }

    /// `quickshell ipc call target method args…` against the test instance,
    /// trimmed; a non-zero exit or 3 s without an answer is an error.
    fn ipc(&self, target: &str, method: &str, args: &[&str]) -> R<String> {
        let call = format!("ipc call {target} {method} {args:?}");
        let mut child = Command::new("quickshell")
            .args(["ipc", "-p"])
            .arg(&self.app)
            .args(["call", target, method])
            .args(args)
            .env_clear()
            .envs(&self.env)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(app::io(&call))?;
        let mut stdout = child.stdout.take().ok_or("no stdout")?;
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let mut output = Vec::new();
            let _ = sender.send(stdout.read_to_end(&mut output).map(|_| output));
        });
        let output = match receiver.recv_timeout(Duration::from_secs(3)) {
            Ok(output) => output.map_err(app::io(&call))?,
            Err(_) => {
                kill_group(&child, "KILL");
                let _ = child.wait();
                return Err(format!("{call}: timed out after 3 s"));
            }
        };
        let status = child.wait().map_err(app::io(&call))?;
        let output = String::from_utf8_lossy(&output).trim().to_string();
        if !status.success() {
            return Err(format!("{call}: {status}: {output}"));
        }
        Ok(output)
    }

    fn test(&self, method: &str) -> R<String> {
        self.ipc("test", method, &[])
    }

    fn test_json(&self, method: &str) -> R<Value> {
        parse(&self.test(method)?)
    }

    fn lock(&self, method: &str) -> R<String> {
        self.ipc("lock", method, &[])
    }

    fn status(&self) -> R<Value> {
        parse(&self.lock("status")?)
    }

    fn wallpaper(&self) -> R<Value> {
        self.test_json("wallpaperState")
    }

    fn fingerprint(&self) -> R<Value> {
        self.test_json("fingerprintState")
    }

    fn refresh_wallpaper(&self) -> R {
        self.test("wallpaperRefresh").map(drop)
    }

    fn submit(&self, password: &str) -> R {
        self.ipc("test", "submit", &[password]).map(drop)
    }

    /// Poll `lock status` until `predicate` holds, for up to 5 s. Failed
    /// calls, unparsable replies and predicate errors are retried.
    #[track_caller]
    fn wait_for(&self, mut predicate: impl FnMut(&Value) -> R<bool>) -> R<Value> {
        let caller = Location::caller().line();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut last = String::new();
        while Instant::now() < deadline {
            match self.status() {
                Ok(state) => match predicate(&state) {
                    Ok(true) => return Ok(state),
                    Ok(false) => last = state.to_string(),
                    Err(error) => last = error,
                },
                Err(error) => last = error,
            }
            ms(50);
        }
        Err(format!(
            "runtime.rs:{caller}: Timed out waiting for state; last: {last}"
        ))
    }
}

fn run_host(shell: &Path) -> R {
    let base = app::temp_dir("foamy-lock-runtime")?;
    let test = Test::create(&base, shell)?;
    let log_path = base.join("runtime.log");
    let mut child = test.spawn(&log_path)?;
    let result = scenarios(&test);
    if matches!(child.try_wait(), Ok(None)) {
        kill_group(&child, "TERM");
        let deadline = Instant::now() + Duration::from_secs(3);
        while matches!(child.try_wait(), Ok(None)) && Instant::now() < deadline {
            ms(50);
        }
        if matches!(child.try_wait(), Ok(None)) {
            kill_group(&child, "KILL");
            let _ = child.wait();
        }
    }
    print!("{}", fs::read_to_string(&log_path).unwrap_or_default());
    println!("Runtime evidence: {}", base.display());
    result
}

fn scenarios(test: &Test) -> R {
    identity_conflict_registry(test)?;
    preview(test)?;
    look(test)?;
    wallpaper(test)?;
    settings_and_password(test)?;
    fingerprint(test)?;
    stranded(test)?;
    test.test("missingPam")?;
    ensure!(test.lock("lock")? == "missing-pam");
    ensure!(!on(&test.status()?, "locked")?);
    println!(
        "PASS: settings reload/atomic save, invalid/missing settings retain policy and locking, disabled/timed blanking, simulated wrong/right password, missing PAM refuses lock"
    );
    Ok(())
}

fn identity_conflict_registry(test: &Test) -> R {
    let avatar_cache = test.path("cache/omarchy/foamy.lock/avatar.png");
    test.wait_for(|s| Ok(on(s, "passwordPam")? && !on(s, "configError")?))?;
    let state = test.wait_for(|s| Ok(on(s, "avatarRenderPath")? || on(s, "avatarError")?))?;
    ensure!(
        *at(&state, "avatarRenderPath")? == avatar_cache.display().to_string()
            && !on(&state, "avatarError")?,
        "{state}"
    );
    let cached = fs::read(&avatar_cache).map_err(app::io(avatar_cache.display()))?;
    ensure!(
        cached.starts_with(PNG_MAGIC),
        "the avatar cache is not a PNG"
    );
    ensure!(
        !on(&state, "conflict")? && *at(&state, "conflictReasons")? == json!([]),
        "{state}"
    );
    let foamy = parse(&test.ipc("foamy.lock", "status", &[])?)?;
    ensure!(
        *at(&foamy, "secure")? == json!(false),
        "foamy.lock status target answers"
    );
    test.write_config(&[], json!({}))?;
    let state = test.wait_for(|s| on(s, "conflict"))?;
    ensure!(
        *at(&state, "conflictReasons")? == json!(["stock-lock-enabled"]),
        "{state}"
    );
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| Ok(!on(s, "conflict")?))?;
    if test.has_registry {
        registry(test)?;
    } else {
        ensure!(*at(&test.status()?, "ipcFastPath")? == json!(false));
    }
    println!(
        "PASS: sandboxed avatar thumbnail, conflict flag from disabledPlugins, foamy.lock status target"
    );
    Ok(())
}

/// 4.5 only: the omarchy-shell socket's IpcRegistry.
fn registry(test: &Test) -> R {
    let direct = test.test_json("registryDirect")?;
    ensure!(
        on(&direct, "direct.ran")? && on(&parse(text(&direct, "direct.output")?)?, "passwordPam")?,
        "{direct}"
    );
    ensure!(
        *at(&direct, "refused")? == json!({"ran": false}),
        "undeclared functions stay unreachable"
    );
    ensure!(*at(&test.status()?, "ipcRouteFirst")? == json!(true));
    ensure!(
        test.test("registryShadow")? == "true",
        "fixture put the stand-in handler first"
    );
    // FoamyIpcPreference re-claims the route on its own (5 s timer), no call needed.
    let deadline = Instant::now() + Duration::from_secs(7);
    let mut route = test.test_json("registryRoute")?;
    while !on(&route, "first")? && Instant::now() < deadline {
        ms(250);
        route = test.test_json("registryRoute")?;
    }
    ensure!(
        on(&route, "first")?,
        "foamy-lock did not re-claim the lock route"
    );
    let routed = parse(text(&route, "status.output")?)?;
    let shared = at(&routed, "conflictReasons")?
        .as_array()
        .is_some_and(|reasons| reasons.contains(&json!("lock-target-shared")));
    ensure!(
        on(&routed, "conflict")? && shared && on(&routed, "ipcRouteFirst")?,
        "{route}"
    );
    ensure!(
        *at(&route, "isLocked")? == json!({"ran": true, "output": "false"}),
        "{route}"
    );
    ensure!(
        *at(&route, "lock")? == json!({"ran": true, "output": "ok"}),
        "lock must reach foamy-lock, not the second handler"
    );
    test.wait_for(|s| on(s, "secure"))?;
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    test.test("registryCleanup")?;
    test.wait_for(|s| Ok(!on(s, "conflict")?))?;
    ensure!(*at(&test.status()?, "ipcFastPath")? == json!(true));
    println!(
        "PASS: 4.5 IpcRegistry routes lock to foamy, keeps it ahead of a second lock handler and reports the conflict"
    );
    Ok(())
}

fn preview(test: &Test) -> R {
    ensure!(test.lock("preview")? == "ok" && test.test("previewState")? == "true");
    ensure!(test.test("previewKey")? == "true" && test.test("previewState")? == "false");
    ensure!(test.lock("preview")? == "ok");
    Ok(())
}

/// The look (preset, layout, background, glass) reloads live, is validated
/// apart from the settings, and previewPreset shows a preset without saving.
fn look(test: &Test) -> R {
    let state = test.status()?;
    ensure!(
        text(&state, "preset")? == "foamy" && text(&state, "lookError")?.is_empty(),
        "{state}"
    );
    test.write_config(
        STOCK_OFF,
        json!({"preset": "corner", "layout": {"media": {"hidden": true}}}),
    )?;
    test.wait_for(|s| Ok(text(s, "preset")? == "corner" && on(s, "look.elements.media.hidden")?))?;
    // A look mistake keeps the previous look and never touches the settings.
    test.write_config(
        STOCK_OFF,
        json!({"preset": "corner", "layout": {"password": {"hidden": true}}, "timeFormat": "12h"}),
    )?;
    let state = test.wait_for(|s| Ok(text(s, "lookError")?.contains("password")))?;
    ensure!(
        text(&state, "preset")? == "corner"
            && *at(&state, "settings.timeFormat")? == "12h"
            && text(&state, "configError")?.is_empty(),
        "{state}"
    );
    // A settings mistake keeps the settings and still applies the look.
    test.write_config(STOCK_OFF, json!({"preset": "zen", "timeFormat": "system"}))?;
    let state = test.wait_for(|s| Ok(text(s, "preset")? == "zen"))?;
    ensure!(
        text(&state, "configError")?.contains("timeFormat")
            && *at(&state, "settings.timeFormat")? == "12h"
            && text(&state, "lookError")?.is_empty(),
        "{state}"
    );
    // The preview overlay shows a preset without saving it.
    ensure!(test.ipc("foamy.lock", "previewPreset", &["editorial"])? == "ok");
    let state = test.status()?;
    ensure!(
        text(&state, "previewPreset")? == "editorial"
            && text(&state, "preset")? == "zen"
            && test.test("previewState")? == "true",
        "{state}"
    );
    ensure!(test.lock("hidePreview")? == "ok");
    ensure!(text(&test.status()?, "previewPreset")?.is_empty());
    for name in ["field-only", "../editorial", ""] {
        ensure!(
            test.ipc("foamy.lock", "previewPreset", &[name])? == "unknown-preset",
            "previewPreset {name:?}"
        );
    }
    // A picture goes through the helper's sandbox; the view gets only the
    // prepared PNG, and a missing file leaves the theme colour.
    let picture = test.path("lake.png");
    write(
        &picture,
        crate::png::encode_rgb(64, 48, &vec![90; 64 * 48 * 3]),
    )?;
    test.write_config(
        STOCK_OFF,
        json!({"background": {"source": "picture", "path": picture.display().to_string(), "blur": 0.5}}),
    )?;
    let state = test.wait_for(|s| {
        Ok(!text(s, "picturePath")?.is_empty() || !text(s, "pictureError")?.is_empty())
    })?;
    let prepared = text(&state, "picturePath")?.to_string();
    ensure!(
        text(&state, "pictureError")?.is_empty()
            && prepared.contains("/omarchy/foamy.lock/background/"),
        "{state}"
    );
    let bytes = std::fs::read(&prepared).map_err(|e| format!("{prepared}: {e}"))?;
    ensure!(
        crate::png::size(&bytes).is_some_and(|(w, h)| w >= 16 && h >= 16),
        "the prepared background is a PNG"
    );
    test.write_config(
        STOCK_OFF,
        json!({"background": {"source": "picture", "path": test.path("missing.png").display().to_string()}}),
    )?;
    let state = test.wait_for(|s| Ok(text(s, "pictureError")? == "background-missing"))?;
    ensure!(text(&state, "picturePath")?.is_empty(), "{state}");
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| {
        Ok(text(s, "preset")? == "foamy"
            && text(s, "configError")?.is_empty()
            && text(s, "pictureError")?.is_empty())
    })?;
    println!(
        "PASS: look presets and overrides reload live, look and settings mistakes stay apart, previewPreset shows without saving, sandboxed picture background and missing picture"
    );
    Ok(())
}

fn wallpaper(test: &Test) -> R {
    let path_is = |expected: &Path| {
        let expected = expected.display().to_string();
        move |_: &Value| Ok(*at(&test.wallpaper()?, "path")? == expected)
    };
    let source_is = |expected: &Path| {
        let expected = expected.display().to_string();
        move |_: &Value| Ok(*at(&test.wallpaper()?, "source")? == expected)
    };
    let error_is =
        |expected: &'static str| move |s: &Value| Ok(*at(s, "wallpaperError")? == expected);
    let path = || -> R<Value> { Ok(at(&test.wallpaper()?, "path")?.clone()) };
    let version = || num(&test.wallpaper()?, "version");

    let image = test.path("static # wallpaper.svg");
    write(
        &image,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>"#,
    )?;
    test.background(Some(&image))?;
    test.refresh_wallpaper()?;
    test.wait_for(path_is(&image))?;
    let before = version()?;
    write(&image, read(&image)?.replace("16", "32"))?;
    test.refresh_wallpaper()?;
    test.wait_for(|_| Ok(version()? > before))?;
    let before = version()?;
    test.refresh_wallpaper()?;
    ms(200);
    ensure!(
        version()? == before,
        "unchanged wallpaper should reuse cache"
    );
    let video = test.path("movie.MP4");
    write(&video, "")?;
    test.background(Some(&video))?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("video-poster-unavailable"))?;
    ensure!(
        path()? == "",
        "without poster.sh (as on 4.0) video must never reach Image"
    );
    write(&test.poster, "#!/bin/sh\nexit 1\n")?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("video-poster-failed"))?;
    ensure!(path()? == "");
    write(
        &test.poster,
        "#!/bin/sh\nsleep 0.2\nprintf \"%s\\n\" \"$HOME/static # wallpaper.svg\"\n",
    )?;
    test.refresh_wallpaper()?;
    let shown = path_is(&image);
    test.wait_for(|s| Ok(shown(s)? && !on(s, "wallpaperError")?))?;
    // A stale video result must launch extraction for the newest video as well.
    let second_video = test.path("second.mp4");
    write(&second_video, "")?;
    let second_poster = test.path("second.svg");
    write(&second_poster, read(&image)?)?;
    let marker = test.path("poster-started");
    write(
        &test.poster,
        "#!/bin/sh\n: > \"$HOME/poster-started\"\nsleep 0.3\ncase \"$1\" in *second.mp4) printf \"%s\\n\" \"$HOME/second.svg\";; *) printf \"%s\\n\" \"$HOME/static # wallpaper.svg\";; esac\n",
    )?;
    test.refresh_wallpaper()?;
    test.wait_for(|_| Ok(marker.exists()))?;
    test.background(Some(&second_video))?;
    test.refresh_wallpaper()?;
    test.wait_for(source_is(&second_video))?;
    test.wait_for(path_is(&second_poster))?;
    // Change the selection while extraction is still running; reject its stale output.
    test.refresh_wallpaper()?;
    ms(100);
    test.background(Some(&image))?;
    test.refresh_wallpaper()?;
    test.wait_for(source_is(&image))?;
    ms(300);
    ensure!(path()? == image.display().to_string());
    test.background(None)?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("wallpaper-unavailable"))?;
    ensure!(path()? == "");
    // The helper's probe: a relative link chain, a retargeted link, a touch,
    // a dangling link and a directory, as Omarchy's theme switch leaves them.
    let other_dir = test.path("themes/other");
    fs::create_dir_all(&other_dir).map_err(app::io(other_dir.display()))?;
    let other = other_dir.join("other.svg");
    write(&other, read(&image)?)?;
    let theme = test
        .background
        .parent()
        .ok_or("background has no parent")?
        .join("theme");
    link("../../../../themes/other", &theme)?;
    test.background(Some(Path::new("theme/other.svg")))?;
    test.refresh_wallpaper()?;
    let shown = path_is(&other);
    test.wait_for(|s| Ok(shown(s)? && !on(s, "wallpaperError")?))?;
    let before = version()?;
    let touched = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
    fs::File::options()
        .write(true)
        .open(&other)
        .and_then(|file| {
            file.set_times(
                fs::FileTimes::new()
                    .set_accessed(touched)
                    .set_modified(touched),
            )
        })
        .map_err(app::io(other.display()))?;
    test.refresh_wallpaper()?;
    test.wait_for(|_| Ok(version()? > before))?;
    ensure!(
        path()? == other.display().to_string(),
        "a touch keeps the path and reloads the image"
    );
    let before = version()?;
    test.background(Some(&image))?;
    test.refresh_wallpaper()?;
    test.wait_for(path_is(&image))?;
    ensure!(version()? > before, "a retargeted link reloads the image");
    for target in [test.path("gone.svg"), other_dir] {
        test.background(Some(&target))?;
        test.refresh_wallpaper()?;
        test.wait_for(error_is("wallpaper-unavailable"))?;
        ensure!(path()? == "", "{}", target.display());
    }
    // No helper binary for this CPU: helper-unavailable, and no retry loop.
    let bin = test.app.join("bin");
    unlink(&bin)?;
    fs::create_dir(&bin).map_err(app::io(bin.display()))?;
    test.background(Some(&image))?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("helper-unavailable"))?;
    ensure!(path()? == "");
    fs::remove_dir(&bin).map_err(app::io(bin.display()))?;
    link(app::plugin_root().join("bin"), &bin)?;
    test.refresh_wallpaper()?;
    ms(300);
    let state = test.wallpaper()?;
    ensure!(
        *at(&state, "source")? == "" && *at(&state, "error")? == "helper-unavailable",
        "an unavailable helper is not started again: {state}"
    );
    ensure!(
        !on(&test.status()?, "locked")?,
        "wallpaper failures must not change lock state"
    );
    println!(
        "PASS: static wallpaper invalidation/cache reuse, optional video poster success/failure/missing helper, stale result rejection"
    );
    println!(
        "PASS: helper wallpaper probe follows relative and retargeted links, touches; dangling link, directory and missing helper keep the themed background"
    );
    Ok(())
}

fn settings_and_password(test: &Test) -> R {
    let calls = test.path("calls");
    let failures = || test.test("failures");
    // Simulate a stale QML property binding during a pre-suspend IPC call.
    test.ipc("test", "staleLock", &["true"])?;
    ensure!(test.lock("isLocked")? == "false");
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| Ok(on(s, "requested")? && on(s, "secure")?))?;
    ensure!(
        test.test("previewState")? == "false",
        "a real lock hides the preview overlay"
    );
    test.ipc("test", "staleLock", &["false"])?;
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    if calls.symlink_metadata().is_ok() {
        unlink(&calls)?;
    }
    test.write_config(
        STOCK_OFF,
        json!({"timeFormat": "12h", "showUserInfo": false, "showMedia": false, "blankAfterSec": null}),
    )?;
    test.wait_for(|s| {
        Ok(*at(s, "settings.timeFormat")? == "12h" && at(s, "settings.blankAfterSec")?.is_null())
    })?;
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| on(s, "secure"))?;
    ms(1100);
    ensure!(
        !calls.exists(),
        "null blank timeout should not blank the display"
    );
    write(&test.config, "{invalid")?;
    let state = test.wait_for(|s| on(s, "configError"))?;
    ensure!(
        on(&state, "secure")? && *at(&state, "settings.timeFormat")? == "12h",
        "{state}"
    );
    test.write_config(STOCK_OFF, json!({"blankAfterSec": 0}))?;
    test.wait_for(|s| Ok(text(s, "configError")?.contains("blankAfterSec")))?;
    test.ipc("test", "doubleReport", &["true"])?;
    test.submit("incorrect")?;
    test.wait_for(|s| Ok(!on(s, "authenticating")? && on(s, "secure")?))?;
    let deadline = Instant::now() + Duration::from_secs(3);
    while failures()? != "1" && Instant::now() < deadline {
        ms(50);
    }
    ms(200);
    ensure!(
        failures()? == "1",
        "onError plus onCompleted must count one failure"
    );
    test.ipc("test", "doubleReport", &["false"])?;
    ensure!(on(&test.status()?, "secure")?);
    // A picture the sandbox refuses never reaches Qt: the initial is shown.
    write(&test.path(".face"), "not an image")?;
    test.submit("incorrect")?;
    test.wait_for(|_| Ok(failures()? == "2"))?;
    ensure!(on(&test.status()?, "secure")?);
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    test.write_config(STOCK_OFF, json!({"blankAfterSec": 1}))?;
    test.wait_for(|s| Ok(!on(s, "configError")? && num(s, "settings.blankAfterSec")? == 1.0))?;
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| on(s, "secure"))?;
    let state = test.wait_for(|s| on(s, "avatarError"))?;
    ensure!(
        *at(&state, "avatarError")? == "unsupported-format"
            && *at(&state, "avatarRenderPath")? == "",
        "{state}"
    );
    let blanked =
        || fs::read_to_string(&calls).is_ok_and(|text| text.contains("omarchy-brightness-display"));
    let deadline = Instant::now() + Duration::from_secs(3);
    while !blanked() && Instant::now() < deadline {
        ms(50);
    }
    ensure!(read(&calls)?.contains("omarchy-brightness-display"));
    ensure!(
        on(&test.status()?, "secure")?,
        "blanking must not unlock the session"
    );
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    let replacement = test.config.with_extension("new");
    write(
        &replacement,
        json!({"version": 1, "plugins": [{"id": "foamy.lock", "showMedia": false}]}).to_string(),
    )?;
    fs::rename(&replacement, &test.config).map_err(app::io(replacement.display()))?;
    test.wait_for(|s| {
        Ok(!on(s, "settings.showMedia")? && num(s, "settings.blankAfterSec")? == 30.0)
    })?;
    unlink(&test.config)?;
    test.wait_for(|s| on(s, "configError"))?;
    ensure!(
        test.lock("lock")? == "ok",
        "missing preferences must not disable locking"
    );
    test.wait_for(|s| on(s, "secure"))?;
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    Ok(())
}

fn fingerprint(test: &Test) -> R {
    let output = test.path("fingerprint-output");
    let field = |path: &str| -> R<f64> { num(&test.fingerprint()?, path) };
    let flag = |path: &str| -> R<bool> { on(&test.fingerprint()?, path) };
    let active = |_: &Value| flag("active");
    test.write_config(STOCK_OFF, json!({"blankAfterSec": null}))?;
    test.wait_for(|s| Ok(at(s, "settings.blankAfterSec")?.is_null()))?;
    write(&output, ENROLLED)?;
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| Ok(on(s, "secure")? && on(s, "fingerprint")? && on(s, "authenticating")?))?;
    for (streak, delay) in [(1.0, 1000.0), (2.0, 2000.0), (3.0, 4000.0)] {
        test.wait_for(active)?;
        test.test("fingerprintFail")?;
        let state = test.fingerprint()?;
        ensure!(
            num(&state, "streak")? == streak,
            "error plus completed must settle once"
        );
        ensure!(num(&state, "delay")? == delay, "{state}");
    }
    let state = test.status()?;
    ensure!(on(&state, "fingerprintUnavailable")? && on(&state, "secure")?);
    test.submit("incorrect")?;
    test.wait_for(|_| Ok(test.test("failures")? == "1"))?;
    ensure!(
        on(&test.status()?, "secure")?,
        "wrong password while reader is unavailable must not unlock"
    );
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    ensure!(
        !flag("retrying")?,
        "password fallback must stop fingerprint retries"
    );
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| Ok(on(s, "secure")? && flag("active")?))?;
    test.wait_for(active)?;
    test.test("fingerprintPrompt")?;
    ensure!(
        !on(&test.status()?, "fingerprintUnavailable")?,
        "prompt clears notice immediately"
    );
    // A prompt followed immediately by a device error is still an unusable attempt.
    test.test("fingerprintFail")?;
    ensure!(field("streak")? == 1.0 && field("delay")? == 1000.0);
    test.wait_for(active)?;
    test.test("fingerprintPrompt")?;
    test.test("fingerprintMismatch")?;
    ensure!(field("streak")? == 0.0 && field("delay")? == 250.0);
    test.wait_for(active)?;
    test.test("fingerprintPrompt")?;
    test.test("oldPrompt")?;
    test.test("fingerprintFail")?;
    ensure!(
        field("streak")? == 0.0,
        "normal full-window error should retry fast"
    );
    test.wait_for(active)?;
    let starts = field("starts")?;
    test.test("blank")?;
    ensure!(
        on(&test.status()?, "fingerprintPaused")? && flag("active")?,
        "blanking preserves the active attempt"
    );
    test.test("fingerprintFail")?;
    ms(1200);
    ensure!(field("starts")? == starts && !flag("retrying")?);
    test.test("unpause")?;
    ensure!(
        field("backoff")? == 1000.0,
        "wake must preserve the backoff tier"
    );
    test.wait_for(active)?;
    test.test("fingerprintFail")?;
    test.test("blank")?;
    let due = field("due")?;
    ms(100);
    test.test("unpause")?;
    ensure!(field("due")? == due && field("backoff")? == 2000.0);
    let delay = field("delay")?;
    ensure!(
        (250.0..2000.0).contains(&delay),
        "wake resumes the remaining delay"
    );
    test.test("blank")?;
    ensure!(test.lock("lock")? == "ok");
    ensure!(
        flag("resumeWatching")?,
        "repeat pre-suspend lock must watch for resume while blank"
    );
    test.test("sleepGap")?;
    test.wait_for(|s| Ok(!on(s, "fingerprintPaused")? && flag("active")?))?;
    ensure!(field("streak")? == 0.0);
    test.test("fingerprintPrompt")?;
    let generation = field("generation")?;
    test.test("resume")?;
    ensure!(field("generation")? == generation + 1.0);
    test.wait_for(active)?;
    ensure!(field("streak")? == 0.0, "resume clears the stale streak");
    write(&output, PROBE_ERROR)?;
    test.test("fingerprintProbe")?;
    ms(200);
    ensure!(
        field("probing")? == 0.0 && !flag("probeRetrying")?,
        "known enrollment must not spawn competing probes"
    );
    ensure!(
        on(&test.status()?, "fingerprint")?,
        "temporary probe error must retain enrollment state"
    );
    write(&output, ENROLLED)?;
    test.test("fingerprintProbe")?;
    test.wait_for(|_| Ok(field("probing")? == 0.0))?;
    test.test("fingerprintMatch")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    ensure!(!flag("retrying")?, "unlock must stop pending retries");
    write(&output, "no\n")?;
    test.test("fingerprintProbe")?;
    test.wait_for(|s| Ok(!on(s, "fingerprint")?))?;
    write(&output, PROBE_ERROR)?;
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| Ok(on(s, "secure")? && on(s, "fingerprintUnavailable")?))?;
    ensure!(
        !on(&test.status()?, "fingerprint")?,
        "unknown initial enrollment must remain unknown"
    );
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    ensure!(!flag("probeRetrying")? && !flag("resumeWatching")?);
    println!(
        "PASS: fingerprint pause/in-flight completion, deadline/backoff preservation, blank suspend recovery, fast device errors, initial probe failures"
    );
    println!(
        "PASS: fingerprint duplicate settlement, backoff, unavailable/recovered UI state, resume abort/retry, transient probe recovery, match unlock and retry cleanup"
    );
    Ok(())
}

fn stranded(test: &Test) -> R {
    let result = test.path("stranded-result");
    write(&result, "1")?;
    test.test("strandedCheck")?;
    test.wait_for(|_| Ok(test.test("strandedResolved")? == "true"))?;
    ensure!(
        !on(&test.status()?, "locked")?,
        "another live locker must not be taken over"
    );
    let parent = read(&test.path("stranded-parent"))?;
    ensure!(
        parent.trim().parse::<i64>().is_ok_and(|pid| pid > 0),
        "stranded helper receives the shell PID: {parent:?}"
    );
    write(&result, "2")?;
    test.test("strandedCheck")?;
    ms(600);
    ensure!(!on(&test.status()?, "locked")? && test.test("strandedResolved")? == "false");
    write(&result, "0")?;
    test.wait_for(|s| on(s, "secure"))?;
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    println!(
        "PASS: direct lock-state decisions, live-owner refusal, unknown-output retry and orphan recovery"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SERVICE: &str = "import Quickshell.Wayland
Item {
  id: root
  readonly property bool locked: lockRequested
  WlSessionLock {
    WlSessionLockSurface {
      LockView {
      }
    }
  }
  PamContext { config: \"/etc/pam.d/omarchy-lock-password\" }
  PamContext { config: \"/etc/pam.d/omarchy-lock-fingerprint\" }
  PanelWindow {
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore
      WlrLayershell.deeper: kept
    LockView { }
  }
  function screens() { var screens = Quickshell.screens || [] }
}
";

    #[test]
    fn service_patch() {
        let patched = patch_service(SERVICE, Path::new("/tmp/pam")).unwrap();
        assert!(patched.starts_with("import \"mocks\" as Mock\n"));
        assert!(patched.contains("property alias testResume: fingerprintResumeTimer\n"));
        assert!(patched.contains("locked: testStaleLocked || lockRequested"));
        assert_eq!(
            patched
                .matches("Mock.PamContext { config: \"/tmp/pam\" }")
                .count(),
            2
        );
        assert_eq!(patched.matches("Mock.LockView {").count(), 2);
        assert!(
            patched
                .contains("  Rectangle {\n    width: 800; height: 600\n      WlrLayershell.deeper")
        );
        assert!(!patched.contains("exclusionMode") && !patched.contains("WlrLayer.Overlay"));
        assert!(patched.contains("[{ name: \"fixture\", width: 1920, height: 1080 }]"));
        let error = patch_service(
            &SERVICE.replace("PanelWindow", "Window"),
            Path::new("/tmp/pam"),
        );
        assert!(error.unwrap_err().contains("PanelWindow"));
    }

    #[test]
    fn python_truthiness() {
        for value in [
            json!(null),
            json!(false),
            json!(0),
            json!(""),
            json!([]),
            json!({}),
        ] {
            assert!(!truthy(&value), "{value}");
        }
        for value in [
            json!(true),
            json!(1),
            json!("x"),
            json!([0]),
            json!({"a": 0}),
        ] {
            assert!(truthy(&value), "{value}");
        }
    }

    #[test]
    fn dotted_paths() {
        let value = json!({"settings": {"blankAfterSec": null, "timeFormat": "12h"}});
        assert!(at(&value, "settings.blankAfterSec").unwrap().is_null());
        assert_eq!(text(&value, "settings.timeFormat").unwrap(), "12h");
        assert!(at(&value, "settings.missing").is_err());
        assert!(num(&value, "settings.timeFormat").is_err());
    }
}
