//! `studio open`: the app root and the single running instance.
//!
//! **The root** is `$XDG_CACHE_HOME/foamy-lock-studio/root/`, never inside
//! the plugin folder (the shell watches that and reloads the plugin on any
//! change). It holds only symlinks and a generated `qmldir`:
//!
//! - every non-hidden entry of the plugin's `studio/` under its own name
//!   (`shell.qml`, the app's QML and JS, …), except the names below and
//!   `qmldir`;
//! - `elements`, `kit`, `i18n`, `LockView.qml`, `Layout.js`, `Model.js`
//!   (required), `previews` and `bin` (when the plugin has them: preset
//!   thumbnails, and this helper through FoamyNative from the root);
//! - `Commons` → `$OMARCHY_PATH/shell/Commons`, else
//!   `/usr/share/omarchy/shell/Commons` (`qs.Commons`);
//! - `qmldir`: one `Name 1.0 Name.qml` line per top-level `.qml` file whose
//!   name starts with an uppercase letter (`singleton Name 1.0 Name.qml`
//!   when the file has `pragma Singleton` in its first 8 KiB), sorted.
//!
//! A root that already matches is left alone. Otherwise the new one is
//! built in `.root-XXXXXXXX` beside it and swapped in with
//! `renameat2(RENAME_EXCHANGE)` (or `RENAME_NOREPLACE` the first time), so
//! a reader sees the old root or the new one, never a half-built one.
//!
//! **Single instance**, under the `flock` `foamy-lock-studio/.lock`:
//! `quickshell ipc -p <root> call studio raise` first (3 s). Exit 0 with an
//! answer is `raised`; exit 0 with Quickshell's "Target not found.",
//! "Function not found.", "Not ready to accept queries yet" or an argument
//! count message, or no answer within the bound, is `running` (an instance
//! is there; nothing else is started). Any other exit (no instance) builds
//! the root and starts `quickshell -n -p <root> --no-color` detached: its
//! own session, stdin `/dev/null`, stdout and stderr to
//! `$XDG_STATE_HOME/foamy-lock/studio.log` (0600, truncated per start), cwd
//! `$HOME`. `-n` makes a racing second start exit at once. A start that
//! exits within 400 ms is `running` with status 0 (another instance won)
//! and `START_FAILED` otherwise. The root's `shell.qml` is checked after the
//! build: without one (no `studio/` yet) the reply is `STUDIO_MISSING`.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, ErrorKind, Read};
use std::os::unix::fs::{OpenOptionsExt, symlink};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime};

use foamy_helper::Failure;
use foamy_helper::child::{Bounded, Output};
use foamy_helper::lock::FileLock;
use rustix::fs::{CWD, RenameFlags};
use rustix::io::Errno;
use serde_json::{Value, json};

use super::{Env, io_failure, random_suffix};

/// Links to the plugin, and whether the plugin must have them.
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
const STAGING: &str = ".root-";

/// Bounds of `open`; tests shorten them.
#[derive(Debug, Clone)]
pub struct Options {
    pub raise_timeout: Duration,
    /// How long a fresh start is watched for an immediate exit.
    pub settle: Duration,
    pub lock_timeout: Duration,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            raise_timeout: Duration::from_secs(3),
            settle: Duration::from_millis(400),
            lock_timeout: Duration::from_secs(10),
        }
    }
}

/// What the root should contain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub links: BTreeMap<String, PathBuf>,
    pub qmldir: String,
}

fn is_singleton(path: &Path) -> bool {
    let mut head = Vec::new();
    let read = fs::File::open(path).and_then(|file| file.take(8192).read_to_end(&mut head));
    read.is_ok()
        && String::from_utf8_lossy(&head)
            .lines()
            .any(|line| line.trim() == "pragma Singleton")
}

/// The root for `plugin` with Omarchy's `commons`.
pub fn plan(plugin: &Path, commons: &Path) -> Result<Plan, Failure> {
    let mut links = BTreeMap::new();
    let reserved = |name: &str| {
        name == QMLDIR || name == COMMONS || PLUGIN_LINKS.iter().any(|(fixed, _)| *fixed == name)
    };
    let studio = plugin.join("studio");
    match fs::read_dir(&studio) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry.map_err(io_failure(studio.display()))?;
                let Ok(name) = entry.file_name().into_string() else {
                    continue;
                };
                if !name.starts_with('.') && !reserved(&name) {
                    links.insert(name, entry.path());
                }
            }
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(io_failure(studio.display())(error)),
    }
    let mut missing = Vec::new();
    for (name, required) in PLUGIN_LINKS {
        let target = plugin.join(name);
        if fs::symlink_metadata(&target).is_ok() {
            links.insert(name.to_string(), target);
        } else if required {
            missing.push(name);
        }
    }
    if !missing.is_empty() {
        return Err(Failure::coded(
            "PLUGIN_NOT_FOUND",
            format!("{} lacks {}", plugin.display(), missing.join(", ")),
        ));
    }
    links.insert(COMMONS.to_string(), commons.to_path_buf());
    let mut qmldir = String::new();
    for (name, target) in &links {
        if let Some(stem) = name.strip_suffix(".qml")
            && stem.starts_with(|c: char| c.is_ascii_uppercase())
        {
            let kind = if is_singleton(target) {
                "singleton "
            } else {
                ""
            };
            qmldir.push_str(&format!("{kind}{stem} 1.0 {name}\n"));
        }
    }
    Ok(Plan { links, qmldir })
}

/// Whether `root` is a real directory holding exactly `plan`.
pub fn matches(root: &Path, plan: &Plan) -> bool {
    if !fs::symlink_metadata(root).is_ok_and(|meta| meta.is_dir()) {
        return false;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return false;
    };
    let mut seen = 0;
    for entry in entries {
        let Ok(entry) = entry else { return false };
        let path = entry.path();
        let name = entry.file_name();
        let same = if name == QMLDIR {
            fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file())
                && fs::read_to_string(&path).is_ok_and(|text| text == plan.qmldir)
        } else {
            name.to_str()
                .and_then(|name| plan.links.get(name))
                .is_some_and(|target| fs::read_link(&path).is_ok_and(|link| &link == target))
        };
        if !same {
            return false;
        }
        seen += 1;
    }
    seen == plan.links.len() + 1
}

fn remove_any(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Removes staging directories that a crashed build left over a minute ago.
fn sweep(base: &Path) {
    let Ok(entries) = fs::read_dir(base) else {
        return;
    };
    let stale = SystemTime::now() - Duration::from_secs(60);
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with(STAGING)
            && entry
                .metadata()
                .and_then(|meta| meta.modified())
                .is_ok_and(|time| time < stale)
        {
            let _ = remove_any(&entry.path());
        }
    }
}

/// Makes `base/root` hold `plan`; returns whether anything changed.
pub fn build(base: &Path, plan: &Plan) -> Result<bool, Failure> {
    let root = base.join("root");
    if matches(&root, plan) {
        return Ok(false);
    }
    sweep(base);
    let staging = base.join(format!(
        "{STAGING}{}",
        random_suffix().map_err(io_failure("random"))?
    ));
    let made = (|| -> io::Result<()> {
        fs::create_dir(&staging)?;
        for (name, target) in &plan.links {
            symlink(target, staging.join(name))?;
        }
        fs::write(staging.join(QMLDIR), &plan.qmldir)?;
        match rustix::fs::renameat_with(CWD, &staging, CWD, &root, RenameFlags::NOREPLACE) {
            Ok(()) => return Ok(()),
            Err(Errno::EXIST) | Err(Errno::NOTEMPTY) => {}
            Err(error) => return Err(error.into()),
        }
        // The old root is now at `staging`.
        rustix::fs::renameat_with(CWD, &staging, CWD, &root, RenameFlags::EXCHANGE)?;
        Ok(())
    })();
    let cleaned = remove_any(&staging);
    made.map_err(io_failure(format!("cannot build {}", root.display())))?;
    cleaned.map_err(io_failure(format!("cannot remove {}", staging.display())))?;
    Ok(true)
}

/// What `studio raise` found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Raise {
    Raised,
    /// An instance is there but didn't take the call (the detail says why).
    Running(String),
    NotRunning,
}

/// Quickshell's answers that come from an instance without running the call.
const NOT_RAISED: [&str; 5] = [
    "Target not found.",
    "Function not found.",
    "Not ready to accept queries yet",
    "Too few arguments provided",
    "Too many arguments provided",
];

pub fn classify_raise(output: &Output) -> Raise {
    if output.timed_out {
        return Raise::Running("the running Lock Studio isn't responding".into());
    }
    if !output.status.success() {
        return Raise::NotRunning;
    }
    let answer = output.stdout_lossy();
    let answer = answer.trim();
    match NOT_RAISED.iter().find(|text| answer.starts_with(*text)) {
        Some(_) => Raise::Running(answer.to_string()),
        None => Raise::Raised,
    }
}

fn quickshell(env: &Env) -> Result<PathBuf, Failure> {
    env.find("quickshell", &[]).ok_or_else(|| {
        Failure::coded(
            "QUICKSHELL_MISSING",
            "quickshell isn't installed (not found in PATH)",
        )
    })
}

fn raise(env: &Env, program: &Path, root: &Path, options: &Options) -> Result<Raise, Failure> {
    if !root.join("shell.qml").exists() {
        return Ok(Raise::NotRunning);
    }
    let output = Bounded::new(program)
        .args(["ipc", "-p"])
        .arg(root)
        .args(["call", "studio", "raise"])
        .env("PATH", &env.path)
        .timeout(options.raise_timeout)
        .max_output(64 * 1024)
        .run()
        .map_err(|error| {
            Failure::coded(
                "QUICKSHELL_MISSING",
                format!("cannot run quickshell: {error}"),
            )
        })?;
    Ok(classify_raise(&output))
}

fn log_tail(path: &Path) -> String {
    let text = fs::read(path).unwrap_or_default();
    let start = text.len().saturating_sub(1024);
    String::from_utf8_lossy(&text[start..]).trim().to_string()
}

fn start(env: &Env, program: &Path, root: &Path, options: &Options) -> Result<Value, Failure> {
    let state = env.lock_state()?;
    fs::create_dir_all(&state).map_err(io_failure(state.display()))?;
    let log_path = state.join("studio.log");
    let log = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&log_path)
        .map_err(io_failure(log_path.display()))?;
    let error_log = log.try_clone().map_err(io_failure(log_path.display()))?;
    // Nothing the caller leaked reaches the app.
    crate::cloexec_inherited();
    let mut command = Command::new(program);
    command
        .args(["-n", "-p"])
        .arg(root)
        .arg("--no-color")
        .env("PATH", &env.path)
        .current_dir(
            env.home
                .as_deref()
                .filter(|home| home.is_dir())
                .unwrap_or(Path::new("/")),
        )
        .stdin(Stdio::null())
        .stdout(log)
        .stderr(error_log);
    // SAFETY: setsid(2) only, which is async-signal-safe, between fork and exec.
    unsafe {
        command.pre_exec(|| rustix::process::setsid().map(drop).map_err(io::Error::from));
    }
    let mut child = command.spawn().map_err(|error| {
        Failure::coded("START_FAILED", format!("cannot start quickshell: {error}"))
    })?;
    let pid = child.id();
    let settled = Instant::now() + options.settle;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                return Ok(json!({"ok": true, "action": "running", "root": root,
                    "detail": "another Lock Studio started first"}));
            }
            Ok(Some(status)) => {
                return Err(Failure::coded(
                    "START_FAILED",
                    format!(
                        "Lock Studio exited at once ({status}); see {}: {}",
                        log_path.display(),
                        log_tail(&log_path)
                    ),
                ));
            }
            Ok(None) if Instant::now() < settled => std::thread::sleep(Duration::from_millis(20)),
            // Still running (or no longer ours to wait for): it's started.
            _ => break,
        }
    }
    Ok(json!({"ok": true, "action": "started", "root": root, "pid": pid, "log": log_path}))
}

/// `studio open`.
pub fn open(env: &Env, plugin: &Path, options: &Options) -> Result<Value, Failure> {
    let base = env.studio_cache()?;
    foamy_helper::fs::ensure_private_dir(&base).map_err(io_failure("the studio cache"))?;
    let _lock = FileLock::exclusive_within(&base.join(".lock"), options.lock_timeout)
        .map_err(io_failure("the studio lock"))?
        .ok_or_else(|| Failure::coded("BUSY", "another Lock Studio launch is still under way"))?;
    let root = base.join("root");
    let program = quickshell(env)?;
    match raise(env, &program, &root, options)? {
        Raise::Raised => return Ok(json!({"ok": true, "action": "raised", "root": root})),
        Raise::Running(detail) => {
            return Ok(json!({"ok": true, "action": "running", "root": root, "detail": detail}));
        }
        Raise::NotRunning => {}
    }
    let plan = plan(plugin, &env.commons()?)?;
    build(&base, &plan)?;
    if !plan.links.contains_key("shell.qml") {
        return Err(Failure::coded(
            "STUDIO_MISSING",
            format!("{} has no studio/shell.qml", plugin.display()),
        ));
    }
    start(env, &program, &root, options)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::os::unix::process::ExitStatusExt;

    fn studio(scratch: &Scratch) -> PathBuf {
        let plugin = scratch.plugin();
        scratch.file(
            "plugin/studio/shell.qml",
            "//@ pragma AppId foamy-lock-studio\n",
        );
        scratch.file(
            "plugin/studio/StudioWindow.qml",
            "import QtQuick\nItem {}\n",
        );
        scratch.file(
            "plugin/studio/Theme.qml",
            "pragma Singleton\nimport QtQuick\nQtObject {}\n",
        );
        scratch.file("plugin/studio/Draft.js", ".pragma library\n");
        scratch.file("plugin/studio/qmldir", "ignored\n");
        scratch.file("plugin/studio/kit", "a clash with the plugin's kit\n");
        scratch.file("plugin/studio/.hidden.qml", "");
        fs::create_dir_all(scratch.path("plugin/studio/parts")).unwrap();
        fs::create_dir_all(scratch.path("plugin/previews")).unwrap();
        fs::create_dir_all(scratch.path("omarchy/shell/Commons")).unwrap();
        plugin
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn the_root_links_the_studio_the_view_and_commons() {
        let scratch = Scratch::new("root");
        let plugin = studio(&scratch);
        let commons = scratch.path("omarchy/shell/Commons");
        let plan = plan(&plugin, &commons).unwrap();
        let base = scratch.path("cache");
        fs::create_dir(&base).unwrap();
        assert!(build(&base, &plan).unwrap());
        let root = base.join("root");
        assert_eq!(
            names(&root),
            [
                "Commons",
                "Draft.js",
                "Layout.js",
                "LockView.qml",
                "Model.js",
                "StudioWindow.qml",
                "Theme.qml",
                "elements",
                "i18n",
                "kit",
                "parts",
                "previews",
                "qmldir",
                "shell.qml",
            ]
        );
        let link = |name: &str| fs::read_link(root.join(name)).unwrap();
        assert_eq!(link("shell.qml"), plugin.join("studio/shell.qml"));
        assert_eq!(link("parts"), plugin.join("studio/parts"));
        assert_eq!(
            link("kit"),
            plugin.join("kit"),
            "the plugin's kit wins a clash"
        );
        assert_eq!(link("LockView.qml"), plugin.join("LockView.qml"));
        assert_eq!(link("Commons"), commons);
        assert_eq!(
            fs::read_to_string(root.join("qmldir")).unwrap(),
            "LockView 1.0 LockView.qml\nStudioWindow 1.0 StudioWindow.qml\nsingleton Theme 1.0 Theme.qml\n"
        );
        assert_eq!(names(&base), ["root"], "no staging directory is left");
        // Nothing was written inside the plugin.
        assert_eq!(
            names(&plugin),
            [
                "Layout.js",
                "LockView.qml",
                "Model.js",
                "elements",
                "i18n",
                "kit",
                "previews",
                "studio"
            ]
        );
    }

    #[test]
    fn a_matching_root_is_left_alone_and_a_changed_one_swapped() {
        let scratch = Scratch::new("rebuild");
        let plugin = studio(&scratch);
        let commons = scratch.path("omarchy/shell/Commons");
        let base = scratch.path("cache");
        fs::create_dir(&base).unwrap();
        let first = plan(&plugin, &commons).unwrap();
        assert!(build(&base, &first).unwrap());
        let root = base.join("root");
        assert!(
            !build(&base, &first).unwrap(),
            "an identical root isn't rebuilt"
        );
        scratch.file("plugin/studio/Canvas.qml", "import QtQuick\nItem {}\n");
        let second = plan(&plugin, &commons).unwrap();
        assert_ne!(first, second);
        assert!(build(&base, &second).unwrap());
        assert!(matches(&root, &second));
        assert!(
            fs::read_to_string(root.join("qmldir"))
                .unwrap()
                .contains("Canvas 1.0 Canvas.qml")
        );
        assert_eq!(names(&base), ["root"]);
        // A stray file in the root, or a root that is a symlink, is rebuilt.
        fs::write(root.join("stray"), "").unwrap();
        assert!(!matches(&root, &second));
        assert!(build(&base, &second).unwrap());
        assert!(matches(&root, &second));
        fs::remove_dir_all(&root).unwrap();
        symlink(&plugin, &root).unwrap();
        assert!(!matches(&root, &second));
        assert!(build(&base, &second).unwrap());
        assert!(matches(&root, &second));
        assert!(
            plugin.join("LockView.qml").exists(),
            "the old link went, not its target"
        );
        // Stale staging directories are swept, fresh ones (a concurrent build) kept.
        let stale = base.join(".root-stale000");
        fs::create_dir(&stale).unwrap();
        let old = fs::File::open(&stale).unwrap();
        old.set_modified(SystemTime::now() - Duration::from_secs(120))
            .unwrap();
        let fresh = base.join(".root-fresh000");
        fs::create_dir(&fresh).unwrap();
        fs::write(root.join("stray"), "").unwrap();
        assert!(build(&base, &second).unwrap());
        assert_eq!(names(&base), [".root-fresh000", "root"]);
    }

    #[test]
    fn a_plugin_without_the_view_is_refused() {
        let scratch = Scratch::new("incomplete");
        let plugin = scratch.plugin();
        fs::remove_file(plugin.join("Model.js")).unwrap();
        fs::remove_dir(plugin.join("i18n")).unwrap();
        let failure = plan(&plugin, Path::new("/c")).unwrap_err();
        assert_eq!(failure.code, "PLUGIN_NOT_FOUND");
        assert!(
            failure.message.ends_with("lacks i18n, Model.js"),
            "{failure}"
        );
    }

    #[test]
    fn a_plugin_without_studio_still_gets_a_root() {
        let scratch = Scratch::new("nostudio");
        let plugin = scratch.plugin();
        let plan = plan(&plugin, Path::new("/c")).unwrap();
        assert_eq!(
            plan.links.keys().collect::<Vec<_>>(),
            [
                "Commons",
                "Layout.js",
                "LockView.qml",
                "Model.js",
                "elements",
                "i18n",
                "kit"
            ]
        );
        assert_eq!(plan.qmldir, "LockView 1.0 LockView.qml\n");
    }

    fn output(code: i32, stdout: &str, timed_out: bool) -> Output {
        Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: Vec::new(),
            timed_out,
            overflowed: false,
        }
    }

    #[test]
    fn raise_answers_are_classified() {
        assert_eq!(classify_raise(&output(0, "ok\n", false)), Raise::Raised);
        assert_eq!(classify_raise(&output(0, "", false)), Raise::Raised);
        for text in [
            "Target not found.",
            "Function not found.",
            "Not ready to accept queries yet.",
        ] {
            assert_eq!(
                classify_raise(&output(0, text, false)),
                Raise::Running(text.into())
            );
        }
        assert_eq!(
            classify_raise(&output(255, "No running instances for x", false)),
            Raise::NotRunning
        );
        assert!(matches!(
            classify_raise(&output(0, "", true)),
            Raise::Running(_)
        ));
    }

    /// A fake quickshell: `ipc` answers from `ipc-answer` (exit `ipc-exit`),
    /// a start records its argv in `started` and lives `life` seconds.
    fn fake_quickshell(scratch: &Scratch) {
        let dir = scratch.0.display();
        scratch.script(
            "bin/quickshell",
            &format!(
                "dir='{dir}'\n\
                 if [[ $1 == ipc ]]; then printf '%s\\n' \"$@\" > \"$dir/ipc-args\"; cat \"$dir/ipc-answer\" 2>/dev/null; exit $(cat \"$dir/ipc-exit\" 2>/dev/null || echo 255); fi\n\
                 printf '%s\\n' \"$@\" > \"$dir/started.tmp\"; ps -o sid= -p $$ >> \"$dir/started.tmp\"; pwd >> \"$dir/started.tmp\"; mv \"$dir/started.tmp\" \"$dir/started\"\n\
                 echo 'app log line'\n\
                 exit_code=$(cat \"$dir/start-exit\" 2>/dev/null || echo 0); sleep $(cat \"$dir/life\" 2>/dev/null || echo 2); exit $exit_code"
            ),
        );
    }

    fn quick() -> Options {
        Options {
            raise_timeout: Duration::from_secs(2),
            settle: Duration::from_millis(300),
            lock_timeout: Duration::from_secs(2),
        }
    }

    #[test]
    fn open_starts_a_detached_app_when_none_runs() {
        let scratch = Scratch::new("open");
        let plugin = studio(&scratch);
        fake_quickshell(&scratch);
        let env = scratch.env();
        let reply = open(&env, &plugin, &quick()).unwrap();
        let root = scratch.path("home/.cache/foamy-lock-studio/root");
        assert_eq!(reply["action"], "started", "{reply}");
        assert_eq!(reply["root"], root.to_str().unwrap());
        let started = fs::read_to_string(scratch.path("started")).unwrap();
        let lines: Vec<&str> = started.lines().collect();
        assert_eq!(
            &lines[..4],
            ["-n", "-p", root.to_str().unwrap(), "--no-color"]
        );
        assert_eq!(
            lines[4].trim(),
            reply["pid"].to_string(),
            "it leads its own session"
        );
        assert_eq!(lines[5], scratch.path("home").to_str().unwrap());
        assert!(
            !scratch.path("ipc-args").exists(),
            "no root yet: nothing to raise"
        );
        let log = scratch.path("home/.local/state/foamy-lock/studio.log");
        assert_eq!(reply["log"], log.to_str().unwrap());
        assert!(fs::read_to_string(&log).unwrap().contains("app log line"));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&log).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(matches(
            &root,
            &plan(&plugin, &scratch.path("omarchy/shell/Commons")).unwrap()
        ));

        // Now "running": the raise call answers and nothing else starts.
        fs::remove_file(scratch.path("started")).unwrap();
        fs::write(scratch.path("ipc-answer"), "ok\n").unwrap();
        fs::write(scratch.path("ipc-exit"), "0").unwrap();
        let reply = open(&env, &plugin, &quick()).unwrap();
        assert_eq!(reply["action"], "raised", "{reply}");
        assert_eq!(
            fs::read_to_string(scratch.path("ipc-args")).unwrap(),
            format!("ipc\n-p\n{}\ncall\nstudio\nraise\n", root.display())
        );
        assert!(!scratch.path("started").exists());

        // An instance without the handler yet is running, not started again.
        fs::write(
            scratch.path("ipc-answer"),
            "Not ready to accept queries yet\n",
        )
        .unwrap();
        let reply = open(&env, &plugin, &quick()).unwrap();
        assert_eq!(reply["action"], "running");
        assert_eq!(reply["detail"], "Not ready to accept queries yet");
        assert!(!scratch.path("started").exists());
    }

    #[test]
    fn a_start_that_exits_at_once_is_reported() {
        let scratch = Scratch::new("startfail");
        let plugin = studio(&scratch);
        fake_quickshell(&scratch);
        fs::write(scratch.path("life"), "0").unwrap();
        fs::write(scratch.path("start-exit"), "3").unwrap();
        let env = scratch.env();
        let failure = open(&env, &plugin, &quick()).unwrap_err();
        assert_eq!(failure.code, "START_FAILED");
        assert!(failure.message.contains("app log line"), "{failure}");
        // -n lost the race: another instance is up.
        fs::write(scratch.path("start-exit"), "0").unwrap();
        let reply = open(&env, &plugin, &quick()).unwrap();
        assert_eq!(reply["action"], "running", "{reply}");
    }

    #[test]
    fn open_reports_what_is_missing() {
        let scratch = Scratch::new("missing");
        let plugin = scratch.plugin();
        let env = scratch.env();
        assert_eq!(
            open(&env, &plugin, &quick()).unwrap_err().code,
            "QUICKSHELL_MISSING"
        );
        fake_quickshell(&scratch);
        assert_eq!(
            open(&env, &plugin, &quick()).unwrap_err().code,
            "COMMONS_MISSING"
        );
        fs::create_dir_all(scratch.path("omarchy/shell/Commons")).unwrap();
        let failure = open(&env, &plugin, &quick()).unwrap_err();
        assert_eq!(failure.code, "STUDIO_MISSING");
        assert!(
            scratch
                .path("home/.cache/foamy-lock-studio/root/LockView.qml")
                .exists(),
            "the root is built all the same"
        );
        assert!(!scratch.path("started").exists());
    }
}
