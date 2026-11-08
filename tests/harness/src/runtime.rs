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
const COMMANDS: [(&str, &str); 9] = [
    // FoamyPeerIpc's fallback for a target IpcRegistry can't run: recorded,
    // and answered as omarchy-shell answers a missing function.
    (
        "omarchy-shell",
        r#"printf "%s\n" "$*" >> "$HOME/omarchy-shell-calls"; echo "Function not found.""#,
    ),
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
  property alias testWeatherRetry: weatherRetryTimer
  property alias testFoamyIpc: foamyLockIpc
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
        // A video wallpaper's still comes from the helper's video-probe; a
        // stand-in answers here ($HOME/fake-video-probe: missing is a
        // missing helper), and can hand over to the real one.
        (
            r#"readonly property var posterProbeCommand: FoamyNative.command(FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["video-probe"])"#,
            r#"readonly property var posterProbeCommand: ["bash", "-c", "exec \"$0\" video-probe", root.home + "/fake-video-probe"]"#,
        ),
        (
            "    anchors { top: true; bottom: true; left: true; right: true }",
            "    width: 800; height: 600",
        ),
        (
            "var screens = Quickshell.screens || []",
            "var screens = [{ name: \"fixture\", width: 1920, height: 1080 }]",
        ),
        // The weather polls every 2.5 s and retries a pending reply after 0.2 s.
        (
            "readonly property int weatherPollMs: 900000",
            "readonly property int weatherPollMs: 2500",
        ),
        (
            "readonly property int weatherRetryMs: 10000",
            "readonly property int weatherRetryMs: 200",
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
    // The preview window's layer-shell properties and input mask have no
    // Rectangle equivalent.
    Ok(text
        .split_inclusive('\n')
        .filter(|line| {
            !(line.ends_with('\n')
                && line.strip_prefix("    ").is_some_and(|rest| {
                    rest.starts_with("WlrLayershell.")
                        || rest.starts_with("exclusionMode:")
                        || rest.starts_with("mask:")
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
        // The plugin's stamped kit (FoamyIpc, FoamyI18n), catalogs and elements
        // (the preview banner), unmodified.
        for name in ["kit", "i18n", "bin", "elements"] {
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
        // The stand-in for the helper's video-probe behind a video
        // wallpaper's still (posterProbeCommand, patched above).
        let poster = base.join("fake-video-probe");
        let background = base.join(".local/state/omarchy/current/background");
        let config = base.join(".config/omarchy/shell.json");
        // Omarchy's own poster.sh (ffmpegthumbnailer outside any sandbox) is
        // there but must never run: it leaves a mark if it does.
        let omarchy_poster = omarchy.join("shell/plugins/lock/poster.sh");
        for path in [&omarchy_poster, &background, &config] {
            mkdir(path.parent().unwrap_or(base))?;
        }
        write(
            &omarchy_poster,
            "#!/bin/sh\n: > \"$HOME/poster-sh-ran\"\nexit 1\n",
        )?;
        fs::set_permissions(&omarchy_poster, fs::Permissions::from_mode(0o755))
            .map_err(app::io(omarchy_poster.display()))?;
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
    video(test)?;
    user_presets(test)?;
    cover_art(test)?;
    weather(test)?;
    wallpaper(test)?;
    settings_and_password(test)?;
    fingerprint(test)?;
    stranded(test)?;
    test.test("missingPam")?;
    ensure!(test.lock("lock")? == "missing-pam");
    ensure!(!on(&test.status()?, "locked")?);
    println!(
        "PASS: settings reload/atomic save, invalid/missing settings retain policy and locking, disabled/timed blanking, simulated wrong/right password, missing PAM refuses lock, a lock ends the preview hold and preview refuses while locked"
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
    // A banner says it is a preview, in plain text; the view has no unlock
    // hint (it isn't a lock).
    let parts = parse(&test.test("previewParts")?)?;
    ensure!(
        on(&parts, "banner")?
            && text(&parts, "title")? == "Preview"
            && text(&parts, "hint")? == "Not locked. Any key or click closes the preview."
            && on(&parts, "plain")?
            && on(&parts, "drawn")?
            && on(&parts, "view")?
            && *at(&parts, "unlockHint")? == json!(false),
        "the preview's banner and view: {parts}"
    );
    // Any key closes it; for previewHoldMs after, keys are still swallowed
    // (accepted, the overlay stays closed) and the view and banner are gone.
    let closed = Instant::now();
    ensure!(test.test("previewKey")? == "true" && test.test("previewState")? == "false");
    let parts = parse(&test.test("previewParts")?)?;
    ensure!(
        on(&parts, "holding")? && !on(&parts, "banner")? && !on(&parts, "view")?,
        "holding the keyboard after closing: {parts}"
    );
    ensure!(test.test("previewKey")? == "true" && test.test("previewState")? == "false");
    loop {
        let parts = parse(&test.test("previewParts")?)?;
        if !on(&parts, "holding")? {
            break;
        }
        ensure!(
            closed.elapsed() < Duration::from_secs(3),
            "the hold never ends"
        );
        ms(25);
    }
    let held = closed.elapsed();
    ensure!(held >= Duration::from_millis(450), "held only {held:?}");
    // Opening it again during a hold ends the hold.
    ensure!(test.lock("preview")? == "ok");
    ensure!(test.lock("hidePreview")? == "ok");
    ensure!(on(&parse(&test.test("previewParts")?)?, "holding")?);
    ensure!(test.lock("preview")? == "ok");
    let parts = parse(&test.test("previewParts")?)?;
    ensure!(
        on(&parts, "visible")? && !on(&parts, "holding")? && on(&parts, "banner")?,
        "reopened: {parts}"
    );
    println!(
        "PASS: the preview overlay has a Preview banner and no unlock hint, any key closes it and keys are swallowed for {held:?} after"
    );
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
    // catalog lists what an editor may offer; previewLook previews an unsaved look.
    let catalog = parse(&test.ipc("foamy.lock", "catalog", &[])?)?;
    let preset_count = app::selectable_presets()?.len();
    ensure!(
        at(&catalog, "presets")?
            .as_array()
            .is_some_and(|p| p.iter().any(|p| p["name"] == "foamy"))
            && at(&catalog, "styles.password")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "pill") && s.iter().any(|s| s == "terminal"))
            && at(&catalog, "styles.clock")?
                .as_array()
                .is_some_and(|s| s.len() == 12
                    && s.iter().any(|s| s == "ring")
                    && s.iter().any(|s| s == "serif"))
            && at(&catalog, "styles.calendar")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "card"))
            && at(&catalog, "presets")?.as_array().is_some_and(|p| {
                p.len() == preset_count
                    && p.iter().all(|p| {
                        p["thumbnail"].as_str().is_some_and(|t| {
                            t.ends_with(&format!(
                                "/previews/presets/{}.png",
                                p["name"].as_str().unwrap_or("?")
                            ))
                        })
                    })
            })
            && at(&catalog, "backgroundDecor")?
                .as_array()
                .is_some_and(|d| d.iter().any(|d| d == "cinema"))
            && at(&catalog, "glassTints")?
                .as_array()
                .is_some_and(|t| t.iter().any(|t| t == "accent"))
            && at(&catalog, "backgroundSources")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "aurora"))
            && text(&catalog, "defaultPreset")? == "foamy",
        "{catalog}"
    );
    // Version 3: the weather, the new styles and each element's own keys.
    ensure!(
        at(&catalog, "elements")?
            .as_array()
            .is_some_and(|e| e.last() == Some(&json!("weather")))
            && at(&catalog, "styles.date")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "week"))
            && at(&catalog, "styles.calendar")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "mini"))
            && at(&catalog, "styles.weather")?
                .as_array()
                .is_some_and(|s| s.len() == 6)
            && at(&catalog, "styles.media")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "disc"))
            && text(
                &catalog,
                "elementLimits.password.options.reveal.defaults.pill"
            )? == "typing"
            && at(&catalog, "elementLimits.media.options.artwork.default")? == &json!(true)
            && at(&catalog, "statusItems")?
                .as_array()
                .is_some_and(|s| s.len() == 8)
            && at(&catalog, "elementKeysFor.password")?
                .as_array()
                .is_some_and(|k| k.iter().any(|k| k == "reveal"))
            && at(&catalog, "elementKeysFor.weather")?
                .as_array()
                .is_some_and(|k| k.iter().any(|k| k == "location"))
            && at(&catalog, "elementKeysFor.clock")?
                .as_array()
                .is_some_and(|k| !k.iter().any(|k| k == "reveal"))
            && text(&catalog, "elementLimits.password.options.reveal.default")? == "always"
            && at(&catalog, "elementLimits.weather.options.location.default")? == &json!(false)
            && at(
                &catalog,
                "elementLimits.status.options.items.defaults.system"
            )?
            .as_array()
            .is_some_and(|d| d.len() == 4)
            && at(&catalog, "weather.target")?.is_boolean()
            && at(&catalog, "presets")?.as_array().is_some_and(|p| p
                .iter()
                .all(|p| p["look"]["elements"]["weather"]["hidden"] == true)),
        "{catalog}"
    );
    // Version 4: shapes, their limits and the templates; every preset's
    // look has a list of shapes and never the older decor.
    ensure!(
        at(&catalog, "shapeKinds")?
            .as_array()
            .is_some_and(|k| k.len() == 3 && k.iter().any(|k| k == "panel"))
            && num(&catalog, "shapeLimits.limits.count")? == 4.0
            && num(&catalog, "shapeLimits.limits.frosted")? == 2.0
            && num(&catalog, "shapeLimits.defaults.box.radius")? == 24.0
            && at(&catalog, "templates.cinema")?
                .as_array()
                .is_some_and(|t| t.len() == 2)
            && at(&catalog, "templates.island")?
                .as_array()
                .is_some_and(|t| t.len() == 1 && t[0]["wrap"]["zones"] == json!(["top-center"]))
            && at(&catalog, "presets")?.as_array().is_some_and(|p| {
                p.iter().all(|p| {
                    p["look"]["background"]["shapes"].is_array()
                        && p["look"]["background"].get("decor").is_none()
                })
            }),
        "{catalog}"
    );
    // Version 2: the placement keys and their limits, per element.
    ensure!(
        num(&catalog, "version")? == 4.0
            && at(&catalog, "elementKeys")?.as_array().is_some_and(|k| {
                ["scale", "opacity", "offset", "glass", "screens"]
                    .iter()
                    .all(|key| k.iter().any(|k| k == key))
                    && !k.iter().any(|k| k == "options")
            })
            && num(&catalog, "elementLimits.clock.scale.min")? == 0.5
            && num(&catalog, "elementLimits.clock.scale.max")? == 2.0
            && num(&catalog, "elementLimits.clock.scale.step")? == 0.05
            && num(&catalog, "elementLimits.password.scale.min")? == 0.85
            && num(&catalog, "elementLimits.password.opacity.min")? == 0.7
            && num(&catalog, "elementLimits.password.glass.min")? == 0.08
            && num(&catalog, "elementLimits.media.offset.max")? == 0.5
            && at(&catalog, "elementLimits.date.glass")?.is_null()
            && at(&catalog, "elementLimits.account.screens")?.is_null()
            && at(&catalog, "elementLimits.calendar.screens")?
                .as_array()
                .is_some_and(|s| s.iter().any(|s| s == "primary")),
        "{catalog}"
    );
    let custom =
        json!({"preset": "corner", "layout": {"media": {"zone": "bottom-center"}}}).to_string();
    ensure!(test.ipc("foamy.lock", "previewLook", &[&custom])? == "ok");
    ensure!(text(&test.status()?, "previewPreset")? == "corner");
    ensure!(test.lock("hidePreview")? == "ok");
    // The placement keys preview, and their limits hold over IPC.
    let placed = json!({"layout": {"clock": {"scale": 1.25, "opacity": 0.8,
        "offset": {"x": 0.05, "y": -0.02}, "screens": "primary"}, "media": {"glass": 0.4}}})
    .to_string();
    ensure!(test.ipc("foamy.lock", "previewLook", &[&placed])? == "ok");
    ensure!(test.lock("hidePreview")? == "ok");
    for (look, error) in [
        (
            json!({"layout": {"password": {"scale": 2}}}),
            "layout.password.scale must be",
        ),
        (
            json!({"layout": {"clock": {"offset": {"x": 0.1}}}}),
            "layout.clock.offset must be",
        ),
        (
            json!({"layout": {"account": {"screens": "primary"}}}),
            "layout.account.screens isn't",
        ),
        (
            json!({"layout": {"date": {"glass": 0.5}}}),
            "layout.date.glass isn't",
        ),
        (
            json!({"layout": {"clock": {"options": {"seconds": true}}}}),
            "layout.clock has an unknown key: options",
        ),
    ] {
        let look = look.to_string();
        for function in ["previewLook", "saveLook"] {
            let reply = test.ipc("foamy.lock", function, &[&look])?;
            ensure!(
                reply.starts_with(&format!("invalid: {error}")),
                "{function} {look}: {reply}"
            );
        }
    }
    // saveLook writes the look keys through Omarchy's updateEntryInline and
    // keeps every other key of the entry.
    test.write_config(
        STOCK_OFF,
        json!({"timeFormat": "12h", "background": {"dim": 0.5}, "layout": {"date": {"hidden": true}}}),
    )?;
    test.wait_for(|s| Ok(*at(s, "settings.timeFormat")? == "12h"))?;
    let save = json!({"preset": "editorial", "layout": {"clock": {"hidden": true}}}).to_string();
    ensure!(test.ipc("foamy.lock", "saveLook", &[&save])? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        text(&saved, "module")? == "foamy.lock"
            && *at(&saved, "entry.timeFormat")? == "12h"
            && text(&saved, "entry.preset")? == "editorial"
            && on(&saved, "entry.layout.clock.hidden")?
            && at(&saved, "entry.background").is_err()
            && at(&saved, "entry.id").is_err(),
        "{saved}"
    );
    ensure!(test.ipc("foamy.lock", "saveLook", &[&save])? == "unchanged");
    // The placement keys are saved as given, the other keys kept.
    let moved = json!({"preset": "editorial", "layout": {"clock": {"hidden": true},
        "date": {"scale": 1.5, "offset": {"x": 0.1, "y": 0}, "screens": "primary"}}})
    .to_string();
    ensure!(test.ipc("foamy.lock", "saveLook", &[&moved])? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        num(&saved, "entry.layout.date.scale")? == 1.5
            && num(&saved, "entry.layout.date.offset.x")? == 0.1
            && text(&saved, "entry.layout.date.screens")? == "primary"
            && *at(&saved, "entry.timeFormat")? == "12h",
        "{saved}"
    );
    let extra = json!({"preset": "zen", "timeFormat": "24h"}).to_string();
    ensure!(
        test.ipc("foamy.lock", "saveLook", &[&extra])?
            .starts_with("invalid: unknown key")
    );
    let hidden = json!({"layout": {"password": {"hidden": true}}}).to_string();
    ensure!(
        test.ipc("foamy.lock", "saveLook", &[&hidden])?
            .starts_with("invalid: ")
    );
    ensure!(
        test.ipc("foamy.lock", "previewLook", &[&hidden])?
            .starts_with("invalid: ")
    );
    ensure!(test.ipc("foamy.lock", "previewLook", &["{not json"])? == "invalid-json");
    // JSON arguments over 64 KiB are refused before they are parsed (valid
    // JSON padded with spaces, so only the size can refuse it); 64 KiB is
    // parsed (saveLook and savePreset then refuse what they read, so nothing
    // is written). Called in the process: `quickshell ipc` itself can't carry
    // them.
    let big = parse(&test.test("bigArguments")?)?;
    for function in ["previewLook", "saveLook", "savePreset"] {
        ensure!(
            text(&big, &format!("{function}.over"))? == "invalid: argument over 65536 bytes",
            "{function} over 64 KiB: {big}"
        );
    }
    ensure!(
        text(&big, "previewLook.at")? == "ok"
            && text(&big, "saveLook.at")? == "invalid: unknown key bogus"
            && text(&big, "savePreset.at")?.starts_with("invalid: name must be"),
        "64 KiB is parsed: {big}"
    );
    ensure!(test.lock("hidePreview")? == "ok");
    for name in ["field-only", "../editorial", ""] {
        ensure!(
            test.ipc("foamy.lock", "previewPreset", &[name])? == "unknown-preset",
            "previewPreset {name:?}"
        );
    }
    // Omarchy saves shell.json by rename (FileView atomicWrites): the watch
    // must follow the new file, more than once.
    for preset in ["editorial", "corner"] {
        let staged = test.path(".config/omarchy/shell.json.saving");
        let config = json!({"version": 1, "plugins": [{"id": "foamy.lock", "preset": preset}],
            "disabledPlugins": STOCK_OFF});
        write(&staged, config.to_string())?;
        std::fs::rename(&staged, &test.config).map_err(|e| format!("rename: {e}"))?;
        test.wait_for(|s| Ok(text(s, "preset")? == preset))?;
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

/// User presets (`userPresets`): read item by item apart from the settings
/// and the look, listed in status and catalog, previewed as `user:<id>`,
/// and saved, renamed and deleted one at a time through Omarchy's
/// updateEntryInline (the fake records each write; it never writes the
/// file, so a second write in a row shows the first was taken as the entry).
/// A video background: the real helper's video-probe (in its sandbox)
/// gives the poster while unlocked; the clip is found only once it was
/// converted (as Lock Studio does, with the size the lock asked for), and a
/// broken file leaves the theme colour. Never a picture job for a video.
fn video(test: &Test) -> R {
    if !Path::new("/usr/bin/ffmpeg").is_file() || !Path::new("/usr/bin/ffprobe").is_file() {
        println!("SKIP: video backgrounds (no ffmpeg)");
        return Ok(());
    }
    let clip = test.path("loop.mp4");
    let made = Command::new("/usr/bin/ffmpeg")
        .args(["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i"])
        .args([
            "testsrc2=size=96x54:rate=10:duration=1",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ])
        .arg(&clip)
        .status()
        .map_err(app::io("ffmpeg"))?;
    ensure!(made.success(), "ffmpeg made the test clip");
    let entry = |motion: &str, path: &Path| json!({"background": {"source": "picture", "path": path.display().to_string(), "motion": motion}});
    test.write_config(STOCK_OFF, entry("play", &clip))?;
    let state = test.wait_for(|s| {
        Ok(!text(s, "video.poster")?.is_empty() || !text(s, "video.error")?.is_empty())
    })?;
    let poster = text(&state, "video.poster")?.to_string();
    ensure!(
        text(&state, "video.error")?.is_empty()
            && poster.contains("/omarchy/foamy.lock/video/")
            && text(&state, "video.clip")?.is_empty()
            && text(&state, "picturePath")?.is_empty()
            && text(&state, "pictureError")?.is_empty(),
        "{state}"
    );
    let bytes = std::fs::read(&poster).map_err(|e| format!("{poster}: {e}"))?;
    let request = at(&state, "video.request")?.clone();
    let size = (
        num(&request, "width")? as u32,
        num(&request, "height")? as u32,
    );
    ensure!(
        crate::png::size(&bytes) == Some(size) || size.0 > 3840 || size.1 > 2160,
        "the poster is the screen's size: {request}"
    );
    // Converted as Lock Studio converts it, then probed again.
    let helper =
        app::plugin_root().join(format!("bin/{}/foamy-lock-helper", std::env::consts::ARCH));
    let mut convert = Command::new(&helper)
        .arg("video-convert")
        .env_clear()
        .env("HOME", &test.base)
        .env("PATH", "/usr/bin")
        .env("XDG_CACHE_HOME", test.path("cache"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .map_err(app::io(helper.display()))?;
    {
        use std::io::Write;
        let mut stdin = convert.stdin.take().ok_or("no stdin")?;
        writeln!(stdin, "{request}").map_err(app::io("video-convert"))?;
    }
    let output = convert
        .wait_with_output()
        .map_err(app::io("video-convert"))?;
    let reply = String::from_utf8_lossy(&output.stdout)
        .lines()
        .last()
        .unwrap_or("")
        .to_string();
    let reply = parse(&reply)?;
    ensure!(on(&reply, "ok")?, "video-convert: {reply}");
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| Ok(text(s, "video.poster")?.is_empty()))?;
    test.write_config(STOCK_OFF, entry("play", &clip))?;
    let state = test.wait_for(|s| {
        Ok(!text(s, "video.clip")?.is_empty() || !text(s, "video.error")?.is_empty())
    })?;
    ensure!(
        text(&state, "video.clip")? == text(&reply, "clip")?
            && text(&state, "video.poster")? == poster,
        "{state}"
    );
    // Still: the same probe (the poster), no other job.
    test.write_config(STOCK_OFF, entry("still", &clip))?;
    test.wait_for(|s| Ok(text(s, "look.background.motion").is_err()))?;
    // A video Omarchy wallpaper: its still is the real helper's sandboxed
    // video-probe poster (the stand-in hands over to it), in the same cache.
    write(
        &test.poster,
        format!("#!/bin/sh\nexec '{}' \"$@\"\n", helper.display()),
    )?;
    fs::set_permissions(&test.poster, fs::Permissions::from_mode(0o755))
        .map_err(app::io(test.poster.display()))?;
    test.background(Some(&clip))?;
    test.refresh_wallpaper()?;
    test.wait_for(|_| {
        let state = test.wallpaper()?;
        Ok(text(&state, "path")?.contains("/omarchy/foamy.lock/video/")
            && text(&state, "error")?.is_empty())
    })?;
    let still = text(&test.wallpaper()?, "path")?.to_string();
    let bytes = std::fs::read(&still).map_err(|e| format!("{still}: {e}"))?;
    ensure!(
        crate::png::size(&bytes).is_some(),
        "the wallpaper's still is a PNG: {still}"
    );
    test.background(None)?;
    test.refresh_wallpaper()?;
    test.wait_for(|_| Ok(text(&test.wallpaper()?, "path")?.is_empty()))?;
    // A broken file: no poster, no clip, the theme colour.
    let broken = test.path("broken.mp4");
    write(&broken, b"\0\0\0\x20ftypisom\0\0\x02\0garbage, not a video")?;
    test.write_config(STOCK_OFF, entry("play", &broken))?;
    let state = test.wait_for(|s| Ok(text(s, "video.error")? == "decode-failed"))?;
    ensure!(
        text(&state, "video.poster")?.is_empty() && text(&state, "video.clip")?.is_empty(),
        "{state}"
    );
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| Ok(text(s, "video.error")?.is_empty() && at(s, "video.request")?.is_null()))?;
    println!(
        "PASS: a video background's poster and clip from the sandboxed video-probe while unlocked, the clip only once converted for the lock's size, a video Omarchy wallpaper's still from the same probe, a broken video keeps the theme colour"
    );
    Ok(())
}

fn user_presets(test: &Test) -> R {
    let mine = |id: &str, name: &str, preset: &str| json!({"id": id, "name": name, "look": {"preset": preset, "layout": {"media": {"hidden": true}}}});
    // A bad item is skipped and counted; the good one, the look and the
    // settings stay.
    test.write_config(
        STOCK_OFF,
        json!({"preset": "corner", "timeFormat": "12h", "userPreset": "a",
            "userPresets": [mine("a", "Mine", "zen"), {"id": "Bad Id", "name": "x", "look": {}}]}),
    )?;
    let state = test
        .wait_for(|s| Ok(text(s, "preset")? == "corner" && num(s, "userPresetsInvalid")? == 1.0))?;
    ensure!(
        *at(&state, "userPresets")? == json!([{"id": "a", "name": "Mine"}])
            && text(&state, "userPresetsError")?.starts_with("userPresets[1]: id must be")
            && text(&state, "userPreset")? == "a"
            && *at(&state, "settings.timeFormat")? == "12h"
            && text(&state, "lookError")?.is_empty(),
        "{state}"
    );
    // Bad presets list, look still applies; an unknown link is ignored.
    test.write_config(
        STOCK_OFF,
        json!({"preset": "zen", "timeFormat": "12h", "userPreset": "gone", "userPresets": "nope"}),
    )?;
    let state = test.wait_for(|s| Ok(text(s, "preset")? == "zen"))?;
    ensure!(
        *at(&state, "userPresets")? == json!([])
            && num(&state, "userPresetsInvalid")? == 1.0
            && text(&state, "userPreset")?.is_empty()
            && text(&state, "lookError")?.is_empty()
            && text(&state, "configError")?.is_empty(),
        "{state}"
    );
    test.write_config(
        STOCK_OFF,
        json!({"timeFormat": "12h", "userPresets": [mine("a", "Mine", "editorial")]}),
    )?;
    test.wait_for(|s| {
        Ok(at(s, "userPresets")?
            .as_array()
            .is_some_and(|p| p.len() == 1))
    })?;
    // The catalog lists them with their look and their preset's thumbnail.
    let catalog = parse(&test.ipc("foamy.lock", "catalog", &[])?)?;
    ensure!(
        at(&catalog, "userPresets")?[0]["id"] == "a"
            && at(&catalog, "userPresets")?[0]["look"]["preset"] == "editorial"
            && at(&catalog, "userPresets")?[0]["entry"]["layout"]["media"]["hidden"] == true
            && at(&catalog, "userPresets")?[0]["thumbnail"]
                .as_str()
                .is_some_and(|t| t.ends_with("/previews/presets/editorial.png"))
            && num(&catalog, "userPresetLimits.count")? == 50.0
            && num(&catalog, "userPresetLimits.bytes")? == 262144.0
            && num(&catalog, "userPresetsInvalid")? == 0.0,
        "{catalog}"
    );
    // previewPreset user:<id> shows it; nothing is saved.
    ensure!(test.ipc("foamy.lock", "previewPreset", &["user:a"])? == "ok");
    ensure!(text(&test.status()?, "previewPreset")? == "editorial");
    ensure!(test.lock("hidePreview")? == "ok");
    for name in ["user:nope", "user:", "user:A"] {
        ensure!(
            test.ipc("foamy.lock", "previewPreset", &[name])? == "unknown-preset",
            "{name}"
        );
    }
    // savePreset: a new id goes first, the rest of the entry is kept; a
    // retry is the same save.
    let save = mine("b", "Ålesund ✓", "corner").to_string();
    ensure!(test.ipc("foamy.lock", "savePreset", &[&save])? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        text(&saved, "module")? == "foamy.lock"
            && *at(&saved, "entry.timeFormat")? == "12h"
            && at(&saved, "entry.userPresets")?
                .as_array()
                .is_some_and(|p| p.len() == 2
                    && p[0]["id"] == "b"
                    && p[0]["name"] == "Ålesund ✓"
                    && p[1]["id"] == "a")
            && at(&saved, "entry.id").is_err(),
        "{saved}"
    );
    ensure!(test.ipc("foamy.lock", "savePreset", &[&save])? == "unchanged");
    // At once, before any file watch: the next operation merges over it.
    ensure!(
        at(&test.status()?, "userPresets")?
            .as_array()
            .is_some_and(|p| p.len() == 2)
    );
    ensure!(test.ipc("foamy.lock", "renamePreset", &["b", "Bee"])? == "ok");
    ensure!(test.ipc("foamy.lock", "previewPreset", &["user:b"])? == "ok");
    ensure!(test.lock("hidePreview")? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        at(&saved, "entry.userPresets")?
            .as_array()
            .is_some_and(|p| p.len() == 2
                && p[0]["name"] == "Bee"
                && p[0]["look"]["preset"] == "corner"
                && p[1]["id"] == "a")
            && *at(&saved, "entry.timeFormat")? == "12h",
        "two quick operations both stay: {saved}"
    );
    ensure!(test.ipc("foamy.lock", "renamePreset", &["b", "Bee"])? == "unchanged");
    ensure!(test.ipc("foamy.lock", "renamePreset", &["zz", "Bee"])? == "unknown-preset");
    // saveLook links the look to it (a fifth key), and a look saved
    // without the key drops the link; the presets stay either way.
    let linked =
        json!({"preset": "corner", "layout": {"media": {"hidden": true}}, "userPreset": "b"})
            .to_string();
    ensure!(test.ipc("foamy.lock", "saveLook", &[&linked])? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        text(&saved, "entry.userPreset")? == "b"
            && text(&saved, "entry.preset")? == "corner"
            && at(&saved, "entry.userPresets")?
                .as_array()
                .is_some_and(|p| p.len() == 2),
        "{saved}"
    );
    ensure!(text(&test.status()?, "userPreset")? == "b");
    let unlinked = json!({"preset": "corner", "layout": {"media": {"hidden": true}}}).to_string();
    ensure!(test.ipc("foamy.lock", "saveLook", &[&unlinked])? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        at(&saved, "entry.userPreset").is_err()
            && at(&saved, "entry.userPresets")?
                .as_array()
                .is_some_and(|p| p.len() == 2),
        "{saved}"
    );
    ensure!(test.ipc("foamy.lock", "saveLook", &[&linked])? == "ok");
    // deletePreset: gone with its link, the look kept; a retry is unchanged.
    ensure!(test.ipc("foamy.lock", "deletePreset", &["b"])? == "ok");
    let saved = parse(&test.test("savedEntry")?)?;
    ensure!(
        at(&saved, "entry.userPreset").is_err()
            && text(&saved, "entry.preset")? == "corner"
            && at(&saved, "entry.userPresets")?
                .as_array()
                .is_some_and(|p| p.len() == 1 && p[0]["id"] == "a"),
        "{saved}"
    );
    ensure!(test.ipc("foamy.lock", "deletePreset", &["b"])? == "unchanged");
    // Strict parsing.
    for (function, args, reply) in [
        ("savePreset", vec!["{nope"], "invalid-json"),
        (
            "savePreset",
            vec![r#"{"id":"Bad","name":"x","look":{}}"#],
            "invalid: id must be",
        ),
        (
            "savePreset",
            vec![r#"{"id":"c","name":" x","look":{}}"#],
            "invalid: name must be",
        ),
        (
            "savePreset",
            vec![r#"{"id":"c","name":"x","look":{"userPreset":"a"}}"#],
            "invalid: look has an unknown key",
        ),
        (
            "savePreset",
            vec![r#"{"id":"c","name":"x","look":{"layout":{"password":{"hidden":true}}}}"#],
            "invalid: ",
        ),
        ("renamePreset", vec!["a", ""], "invalid: name must be"),
        ("deletePreset", vec!["../a"], "invalid: id must be"),
        (
            "saveLook",
            vec![r#"{"userPreset":"Not An Id"}"#],
            "invalid: userPreset must be",
        ),
    ] {
        let answer = test.ipc("foamy.lock", function, &args)?;
        ensure!(answer.starts_with(reply), "{function} {args:?}: {answer}");
    }
    // Caps: 50 presets, and 256 KiB of them (items the lock skips count).
    let fifty: Vec<Value> = (0..50)
        .map(|i| mine(&format!("p{i}"), "Many", "zen"))
        .collect();
    test.write_config(STOCK_OFF, json!({"userPresets": fifty}))?;
    test.wait_for(|s| {
        Ok(at(s, "userPresets")?
            .as_array()
            .is_some_and(|p| p.len() == 50))
    })?;
    ensure!(
        test.ipc(
            "foamy.lock",
            "savePreset",
            &[&mine("new", "New", "zen").to_string()]
        )? == "full"
    );
    ensure!(
        test.ipc(
            "foamy.lock",
            "savePreset",
            &[&mine("p7", "Changed", "zen").to_string()]
        )? == "ok"
    );
    let filler = json!({"junk": "x".repeat(262_100)});
    test.write_config(STOCK_OFF, json!({"userPresets": [filler]}))?;
    test.wait_for(|s| {
        Ok(at(s, "userPresets")?
            .as_array()
            .is_some_and(|p| p.is_empty())
            && num(s, "userPresetsInvalid")? == 1.0)
    })?;
    ensure!(
        test.ipc(
            "foamy.lock",
            "savePreset",
            &[&mine("new", "New", "zen").to_string()]
        )? == "too-large"
    );
    // A shell.json Omarchy can't read is never written (persistShellConfig
    // skips it): write-failed, not ok.
    write(&test.config, "{ \"version\": 1, \"plugins\": [")?;
    test.wait_for(|s| Ok(!text(s, "configError")?.is_empty()))?;
    for (function, arg) in [
        ("savePreset", mine("w", "W", "zen").to_string()),
        ("saveLook", json!({"preset": "zen"}).to_string()),
        ("deletePreset", "a".to_string()),
    ] {
        let answer = test.ipc("foamy.lock", function, &[&arg])?;
        ensure!(answer == "write-failed", "{function}: {answer}");
    }
    // No entry to merge into.
    write(
        &test.config,
        json!({"version": 1, "plugins": [], "disabledPlugins": STOCK_OFF}).to_string(),
    )?;
    test.wait_for(|s| Ok(text(s, "configError")?.contains("exactly one")))?;
    ensure!(
        test.ipc(
            "foamy.lock",
            "savePreset",
            &[&mine("w", "W", "zen").to_string()]
        )? == "no-entry"
    );
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| {
        Ok(text(s, "preset")? == "foamy"
            && text(s, "configError")?.is_empty()
            && num(s, "userPresetsInvalid")? == 0.0)
    })?;
    println!(
        "PASS: user presets read item by item (a bad list never touches the look or settings), listed, previewed as user:<id>, saved, renamed and deleted one at a time with the caps, the link as saveLook's fifth key, two quick writes kept, write-failed and no-entry"
    );
    Ok(())
}

/// Lock Studio's cover art choice: `setCoverArt` writes one of three fixed
/// pairs of showArtwork and artworkHosts (Spotify's host exactly) through
/// updateEntryInline (the fake records each write), keeps every other key,
/// takes no other argument, keeps the entry it wrote as the one a second
/// write merges into, and refuses while locked.
fn cover_art(test: &Test) -> R {
    let saved = |test: &Test| -> R<Value> {
        let saved = parse(&test.test("savedEntry")?)?;
        ensure!(text(&saved, "module")? == "foamy.lock", "{saved}");
        Ok(saved["entry"].clone())
    };
    test.write_config(
        STOCK_OFF,
        json!({"preset": "zen", "timeFormat": "12h", "artworkFileRoots": ["/tmp/covers"]}),
    )?;
    test.wait_for(|s| Ok(text(s, "preset")? == "zen"))?;
    let catalog = parse(&test.ipc("foamy.lock", "catalog", &[])?)?;
    ensure!(
        text(&catalog, "coverArt")? == "player"
            && *at(&catalog, "coverArtModes")? == json!(["off", "player", "spotify"]),
        "{catalog}"
    );
    ensure!(test.ipc("foamy.lock", "setCoverArt", &["spotify"])? == "ok");
    let written = saved(test)?;
    ensure!(
        written["showArtwork"] == json!(true)
            && written["artworkHosts"] == json!(["i.scdn.co"])
            && written["artworkFileRoots"] == json!(["/tmp/covers"])
            && written["timeFormat"] == "12h"
            && written["preset"] == "zen"
            && written.get("id").is_none(),
        "{written}"
    );
    ensure!(test.ipc("foamy.lock", "setCoverArt", &["spotify"])? == "unchanged");
    // A look saved at once merges over the entry just written (before the
    // file watch would report it).
    ensure!(test.ipc("foamy.lock", "saveLook", &[r#"{"preset":"corner"}"#])? == "ok");
    let written = saved(test)?;
    ensure!(
        written["artworkHosts"] == json!(["i.scdn.co"]) && written["preset"] == "corner",
        "{written}"
    );
    for (mode, show) in [("off", false), ("player", true)] {
        ensure!(
            test.ipc("foamy.lock", "setCoverArt", &[mode])? == "ok",
            "{mode}"
        );
        let written = saved(test)?;
        ensure!(
            written["showArtwork"] == json!(show)
                && written["artworkHosts"] == json!([])
                && written["artworkFileRoots"] == json!(["/tmp/covers"])
                && written["preset"] == "corner",
            "{mode}: {written}"
        );
    }
    // Only the three names: never a host, a list or another case.
    for bad in [
        "",
        "Spotify",
        "online",
        "i.scdn.co",
        "custom",
        "spotify ",
        "[\"i.scdn.co\"]",
    ] {
        let answer = test.ipc("foamy.lock", "setCoverArt", &[bad])?;
        ensure!(
            answer == "invalid: mode must be one of off, player, spotify",
            "{bad:?}: {answer}"
        );
    }
    ensure!(saved(test)?["artworkHosts"] == json!([]));
    // The catalog reads the mode back from the settings; hand-set hosts
    // are custom.
    for (settings, mode) in [
        (json!({"artworkHosts": ["i.scdn.co"]}), "spotify"),
        (
            json!({"showArtwork": false, "artworkHosts": ["i.scdn.co"]}),
            "off",
        ),
        (
            json!({"artworkHosts": ["images.example.com", "i.scdn.co"]}),
            "custom",
        ),
    ] {
        test.write_config(STOCK_OFF, settings.clone())?;
        test.wait_for(|s| {
            Ok(at(s, "settings.artworkHosts")? == &settings["artworkHosts"]
                && on(s, "settings.showArtwork")? == settings.get("showArtwork").is_none())
        })?;
        let catalog = parse(&test.ipc("foamy.lock", "catalog", &[])?)?;
        ensure!(
            text(&catalog, "coverArt")? == mode,
            "{mode}: {}",
            catalog["coverArt"]
        );
    }
    // Refused while locked (the harness's stand-in session lock).
    let before = saved(test)?;
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| Ok(on(s, "locked")?))?;
    ensure!(test.ipc("foamy.lock", "setCoverArt", &["spotify"])? == "locked");
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    ensure!(saved(test)? == before, "written while locked");
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| {
        Ok(text(s, "preset")? == "foamy" && *at(s, "settings.artworkHosts")? == json!([]))
    })?;
    println!(
        "PASS: setCoverArt writes off, player and spotify (i.scdn.co only) keeping every other key, merges with a write right after, refuses any other argument and while locked; the catalog names the mode, custom for hand-set hosts"
    );
    Ok(())
}

/// Poll the test's weather state until `predicate` holds, for up to 5 s.
#[track_caller]
fn wait_weather(test: &Test, mut predicate: impl FnMut(&Value) -> R<bool>) -> R<Value> {
    let caller = Location::caller().line();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut last = String::new();
    while Instant::now() < deadline {
        match test.test_json("weather") {
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
        "runtime.rs:{caller}: Timed out waiting for the weather; last: {last}"
    ))
}

/// The weather element's data: fetched from Foamy Weather's `current()`
/// only while a shown look has the weather, checked, and hidden when the
/// target is missing, pending, stale, invalid or not ok. A fake
/// foamy.weather target in IpcRegistry stands in (4.5); omarchy-shell is a
/// stand-in that records calls.
fn weather(test: &Test) -> R {
    let shell_calls = test.path("omarchy-shell-calls");
    let shown = json!({"layout": {"weather": {"hidden": false, "details": "full"}}}).to_string();
    let reply = |value: Value| value.to_string();
    let good = json!({"ok": true, "temperature": 6, "unit": "C", "code": "lightrain_day",
        "condition": "Light rain", "high": 10, "low": 2, "location": "Bergen", "updatedAt": "__UPDATED__"});
    let peer = |reply: &str, age: i64, current: bool| -> R {
        let age = age.to_string();
        let current = current.to_string();
        test.ipc("test", "weatherPeer", &[reply, &age, &current])
            .map(drop)
    };
    let preview = |look: &str| -> R {
        ensure!(test.ipc("foamy.lock", "previewLook", &[look])? == "ok");
        Ok(())
    };
    let hide = || -> R {
        ensure!(test.lock("hidePreview")? == "ok");
        Ok(())
    };
    // No foamy.weather target: nothing is called, nothing shows.
    peer("none", 0, true)?;
    preview(&shown)?;
    let state = wait_weather(test, |w| Ok(text(w, "state")? == "absent"))?;
    ensure!(
        num(&state, "polls")? == 0.0 && at(&state, "shown")?.is_null(),
        "{state}"
    );
    hide()?;
    ensure!(
        !shell_calls.exists(),
        "an absent Foamy Weather starts no process"
    );
    if !test.has_registry {
        println!("SKIP: weather peer (no IpcRegistry on this host)");
        return Ok(());
    }
    // A look without the weather never asks.
    peer(&reply(good.clone()), 60, true)?;
    ensure!(test.ipc("foamy.lock", "previewPreset", &["corner"])? == "ok");
    ms(400);
    let state = test.test_json("weather")?;
    ensure!(
        num(&state, "calls")? == 0.0 && !on(&state, "wanted")?,
        "{state}"
    );
    hide()?;
    // Opening the preview asks at once; the report is checked and shown.
    preview(&shown)?;
    let state = wait_weather(test, |w| Ok(text(w, "state")? == "ok"))?;
    ensure!(
        num(&state, "shown.temperature")? == 6.0
            && text(&state, "shown.unit")? == "C"
            && text(&state, "shown.code")? == "lightrain_day"
            && text(&state, "shown.group")? == "rain"
            && text(&state, "shown.condition")? == "Light rain"
            && num(&state, "shown.high")? == 10.0
            && text(&state, "shown.location")? == "Bergen",
        "{state}"
    );
    let status = test.status()?;
    ensure!(
        text(&status, "weather.state")? == "ok"
            && on(&status, "weather.shown")?
            && !status.to_string().contains("Bergen"),
        "status never names the place: {status}"
    );
    // And again every poll interval while it shows.
    let polls = num(&state, "polls")?;
    wait_weather(test, |w| Ok(num(w, "polls")? > polls))?;
    hide()?;
    // Hidden again, it stops asking.
    let calls = num(&test.test_json("weather")?, "calls")?;
    ms(3000);
    ensure!(
        num(&test.test_json("weather")?, "calls")? == calls,
        "no polls without a shown weather"
    );
    // A cold service: "pending", asked again three times, then left until
    // the next poll; the old report stays meanwhile.
    peer(&reply(json!({"ok": false, "reason": "pending"})), 0, true)?;
    preview(&shown)?;
    let state = wait_weather(test, |w| {
        Ok(text(w, "state")? == "pending" && num(w, "pendingLeft")? == 0.0 && !on(w, "retrying")?)
    })?;
    ensure!(
        num(&state, "calls")? == 4.0 && num(&state, "shown.temperature")? == 6.0,
        "one call and three retries: {state}"
    );
    hide()?;
    // A pending service that becomes ready within the retries shows at once.
    peer(&reply(json!({"ok": false, "reason": "pending"})), 0, true)?;
    preview(&shown)?;
    wait_weather(test, |w| Ok(num(w, "calls")? >= 1.0))?;
    peer(&reply(good.clone()), 120, true)?;
    let state = wait_weather(test, |w| Ok(text(w, "state")? == "ok"))?;
    ensure!(num(&state, "shown.temperature")? == 6.0, "{state}");
    hide()?;
    // Too old (over three hours), not ok, or invalid: hidden.
    let mut long = good.clone();
    long["condition"] = json!("x".repeat(65));
    let mut typed = good.clone();
    typed["temperature"] = json!("6");
    let mut controls = good.clone();
    controls["location"] = json!("Ber\u{202e}gen");
    for (reply, age, expected) in [
        (good.to_string(), 3 * 3600 + 60, "stale"),
        (
            json!({"ok": false, "reason": "offline"}).to_string(),
            0,
            "unavailable",
        ),
        (
            json!({"ok": false, "reason": "no-location"}).to_string(),
            0,
            "unavailable",
        ),
        (long.to_string(), 60, "invalid"),
        (typed.to_string(), 60, "invalid"),
        (controls.to_string(), 60, "invalid"),
        ("<html>".to_string(), 0, "invalid"),
        ("x".repeat(5000), 0, "invalid"),
    ] {
        // Shown first, so each case has something to hide.
        peer(&good.to_string(), 60, true)?;
        preview(&shown)?;
        wait_weather(test, |w| Ok(text(w, "state")? == "ok"))?;
        hide()?;
        peer(&reply, age, true)?;
        preview(&shown)?;
        let state = wait_weather(test, |w| Ok(text(w, "state")? == expected))?;
        ensure!(
            at(&state, "shown")?.is_null() && at(&state, "report")?.is_null(),
            "{expected}: {state}"
        );
        hide()?;
    }
    // An older Foamy Weather without current(): IpcRegistry can't run it,
    // FoamyPeerIpc asks omarchy-shell (the stand-in), and nothing shows.
    peer("", 0, false)?;
    preview(&shown)?;
    let state = wait_weather(test, |w| Ok(text(w, "state")? == "unavailable"))?;
    ensure!(at(&state, "shown")?.is_null(), "{state}");
    hide()?;
    ensure!(
        read(&shell_calls)?
            .lines()
            .all(|line| line == "foamy.weather current"),
        "only the weather call reaches omarchy-shell"
    );
    // The lock asks when it opens, and not while the display is blanked.
    peer(&good.to_string(), 60, true)?;
    test.write_config(STOCK_OFF, json!({"layout": {"weather": {"hidden": false}}}))?;
    test.wait_for(|s| Ok(!on(s, "look.elements.weather.hidden")?))?;
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| on(s, "secure"))?;
    let state = wait_weather(test, |w| Ok(text(w, "state")? == "ok" && on(w, "wanted")?))?;
    ensure!(num(&state, "calls")? >= 1.0, "{state}");
    test.test("blank")?;
    let state = wait_weather(test, |w| Ok(!on(w, "wanted")?))?;
    let calls = num(&state, "calls")?;
    ms(3000);
    ensure!(
        num(&test.test_json("weather")?, "calls")? == calls,
        "no polls while the display is blanked"
    );
    test.test("wake")?;
    wait_weather(test, |w| on(w, "wanted"))?;
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    peer("none", 0, true)?;
    test.write_config(STOCK_OFF, json!({}))?;
    test.wait_for(|s| on(s, "look.elements.weather.hidden"))?;
    println!(
        "PASS: weather from a foamy.weather peer only for a shown weather (absent target, preview, lock, polls, blanking), pending retries, stale, not ok, invalid and older peers hidden"
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
    // A video wallpaper's still: the helper's video-probe poster (here a
    // stand-in that logs its request), never Omarchy's poster.sh.
    let cache = test.path("cache/omarchy/foamy.lock/video");
    let poster_a = cache.join(format!("{}.png", "a".repeat(64)));
    let poster_b = cache.join(format!("{}.png", "b".repeat(64)));
    let probe = |body: &str| -> R {
        write(
            &test.poster,
            format!(
                "#!/bin/sh\nread -r request\nprintf '%s %s\\n' \"$1\" \"$request\" >> \"$HOME/probe-requests\"\ncache=\"$XDG_CACHE_HOME/omarchy/foamy.lock/video\"\nmkdir -p \"$cache\"\n{body}\n"
            ),
        )?;
        fs::set_permissions(&test.poster, fs::Permissions::from_mode(0o755))
            .map_err(app::io(test.poster.display()))
    };
    let answer = |name: &str| {
        format!(
            "cp \"$HOME/static # wallpaper.svg\" \"$cache/{name}.png\"\nprintf '{{\"ok\":true,\"poster\":\"%s\"}}\\n' \"$cache/{name}.png\""
        )
    };
    if test.poster.exists() {
        unlink(&test.poster)?;
    }
    let video = test.path("movie.MP4");
    write(&video, "")?;
    test.background(Some(&video))?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("video-poster-unavailable"))?;
    ensure!(
        path()? == "",
        "without the helper a video must never reach Image"
    );
    probe("exit 1")?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("video-poster-failed"))?;
    ensure!(path()? == "");
    // A reply that isn't ok, or a poster outside the lock's video cache, is
    // no poster either.
    probe("echo '{\"ok\":false,\"error\":\"decode-failed\"}'")?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("video-poster-failed"))?;
    probe("printf '{\"ok\":true,\"poster\":\"%s\"}\\n' \"$HOME/static # wallpaper.svg\"")?;
    test.refresh_wallpaper()?;
    test.wait_for(error_is("video-poster-failed"))?;
    ensure!(path()? == "");
    probe(&format!("sleep 0.2\n{}", answer(&"a".repeat(64))))?;
    test.refresh_wallpaper()?;
    let shown = path_is(&poster_a);
    test.wait_for(|s| Ok(shown(s)? && !on(s, "wallpaperError")?))?;
    // The request: video-probe for the wallpaper at the screen's size.
    let requests = read(&test.path("probe-requests"))?;
    let last = requests.lines().last().unwrap_or("");
    let request = parse(
        last.strip_prefix("video-probe ")
            .ok_or(format!("not video-probe: {last}"))?,
    )?;
    ensure!(
        text(&request, "path")? == video.display().to_string()
            && num(&request, "width")? >= 16.0
            && num(&request, "height")? >= 16.0,
        "the probe's request: {request}"
    );
    // A stale video result must launch extraction for the newest video as well.
    let second_video = test.path("second.mp4");
    write(&second_video, "")?;
    let second_poster = poster_b.clone();
    let marker = test.path("poster-started");
    probe(&format!(
        ": > \"$HOME/poster-started\"\nsleep 0.3\ncase \"$request\" in *second.mp4*) {};; *) {};; esac",
        answer(&"b".repeat(64)),
        answer(&"a".repeat(64))
    ))?;
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
    ensure!(
        !test.path("poster-sh-ran").exists(),
        "Omarchy's poster.sh (unsandboxed) must never run"
    );
    println!(
        "PASS: static wallpaper invalidation/cache reuse, a video wallpaper's still from the helper's video-probe (success, failure, a bad reply, missing helper, stale result rejection), never Omarchy's poster.sh"
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
    // A preview just closed by a key holds the keyboard; a real lock ends
    // the hold at once.
    ensure!(test.lock("preview")? == "ok" && test.test("previewKey")? == "true");
    ensure!(on(&parse(&test.test("previewParts")?)?, "holding")?);
    ensure!(test.lock("lock")? == "ok");
    test.wait_for(|s| Ok(on(s, "requested")? && on(s, "secure")?))?;
    ensure!(
        test.test("previewState")? == "false",
        "a real lock hides the preview overlay"
    );
    ensure!(
        !on(&parse(&test.test("previewParts")?)?, "holding")?,
        "a real lock ends the preview's keyboard hold"
    );
    // Like previewLook and previewPreset, preview refuses over a real lock.
    ensure!(test.lock("preview")? == "locked" && test.test("previewState")? == "false");
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
    // The view hears of it, so drawn backgrounds hold still while blank.
    ensure!(
        on(&test.status()?, "displayBlanked")?,
        "blanking is reported"
    );
    test.submit("test-password")?;
    test.wait_for(|s| Ok(!on(s, "locked")?))?;
    ensure!(
        !on(&test.status()?, "displayBlanked")?,
        "the wake on unlock clears the blank"
    );
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
  readonly property int weatherPollMs: 900000
  readonly property int weatherRetryMs: 10000
  readonly property var posterProbeCommand: FoamyNative.command(FoamyNative.localPath(Qt.resolvedUrl(\".\")), \"foamy-lock-helper\", [\"video-probe\"])
}
";

    #[test]
    fn service_patch() {
        let patched = patch_service(SERVICE, Path::new("/tmp/pam")).unwrap();
        assert!(patched.starts_with("import \"mocks\" as Mock\n"));
        assert!(patched.contains("property alias testResume: fingerprintResumeTimer\n"));
        assert!(patched.contains("locked: testStaleLocked || lockRequested"));
        assert!(patched.contains("weatherPollMs: 2500") && patched.contains("weatherRetryMs: 200"));
        assert!(patched.contains("root.home + \"/fake-video-probe\"]"));
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
