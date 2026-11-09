//! `foamy-lock-helper studio …`: Lock Studio's launcher and every piece of
//! its I/O (the window itself is QML run by Quickshell). None of it runs
//! under the image sandbox: nothing here decodes untrusted data, and the
//! subcommands must reach Quickshell, Omarchy's shell and the session bus.
//!
//! # Contract
//!
//! Every subcommand prints exactly one JSON line on stdout. Exit status 0:
//! the action ran to a conclusion and the line says how (`"ok"` is true on
//! success, false for a refusal the line explains, as `apply` does). Exit 1:
//! `{"ok": false, "code": "<CODE>", "error": "<English message>"}`, the
//! request couldn't be carried out. 101: a helper bug (`"code":
//! "INTERNAL"`). Never 126 or 127 (FoamyNative's "unavailable"). stderr is
//! free-form diagnostics only.
//!
//! - `studio` or `studio open`: see [`root`]. No stdin. `{"ok": true,
//!   "action": "raised" | "running" | "started", "root": …}` (`started`
//!   adds `pid` and `log`; `running` means an instance is there but didn't
//!   take the raise, with `detail`).
//! - `studio install` / `studio uninstall`: see [`desktop`].
//! - `studio draft-load` / `studio draft-save` / `studio draft-clear`: see
//!   [`draft`].
//! - `studio apply`: see [`apply`].
//! - `studio preset save` / `preset rename` / `preset delete`: see
//!   [`preset`].
//! - `studio pick-picture [title [filter name [media filter name]]]`: see
//!   [`portal`].
//!
//! Codes: `INVALID_ARGUMENT` (unknown subcommand or arguments),
//! `INVALID_REQUEST` (stdin isn't what the subcommand takes),
//! `REQUEST_TOO_LARGE`, `NO_HOME` (neither the XDG variable nor `HOME`),
//! `PLUGIN_NOT_FOUND`, `COMMONS_MISSING`, `STUDIO_MISSING`, `QUICKSHELL_MISSING`,
//! `START_FAILED`, `BUSY`, `IO`, `NO_SESSION_BUS`, `PORTAL_UNAVAILABLE`,
//! `PORTAL_FAILED`, `INTERNAL`.
//!
//! The plugin directory is two levels above the directory holding this
//! binary (`<plugin>/bin/<arch>/foamy-lock-helper`, resolved through
//! `/proc/self/exe`), or `$FOAMY_LOCK_PLUGIN_DIR` (absolute; for tests). It
//! must contain `LockView.qml`.
//!
//! Locations follow the XDG base directories (a variable that is unset,
//! empty or relative falls back to `$HOME/…`): the app root under
//! `$XDG_CACHE_HOME/foamy-lock-studio/`, the draft and the app's log under
//! `$XDG_STATE_HOME/foamy-lock/`, the launcher entry and icon under
//! `$XDG_DATA_HOME`.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use foamy_helper::Failure;
use serde_json::Value;

pub mod apply;
mod dbus;
pub mod desktop;
pub mod draft;
pub mod portal;
pub mod preset;
pub mod root;

/// Test override of the plugin directory.
pub const PLUGIN_DIR_VAR: &str = "FOAMY_LOCK_PLUGIN_DIR";
/// The app id: window class, `.desktop` name, icon name, cache folder.
pub const APP_ID: &str = "foamy-lock-studio";
/// The look keys of the `foamy.lock` entry.
pub const LOOK_KEYS: [&str; 4] = ["preset", "layout", "background", "glass"];
/// The look's link to the user preset it came from: `saveLook`'s fifth
/// key, kept in the draft too (never in a user preset's own look).
pub const LINK_KEY: &str = "userPreset";
/// Where Omarchy lives when `$OMARCHY_PATH` doesn't say.
pub const SYSTEM_OMARCHY: &str = "/usr/share/omarchy";

/// The environment the subcommands read, so tests never touch the
/// process's own.
#[derive(Debug, Clone)]
pub struct Env {
    pub home: Option<PathBuf>,
    pub cache: Option<PathBuf>,
    pub state: Option<PathBuf>,
    pub data: Option<PathBuf>,
    pub runtime: Option<PathBuf>,
    /// `$OMARCHY_PATH`, when set and absolute.
    pub omarchy: Option<PathBuf>,
    /// The installed Omarchy (`/usr/share/omarchy`), the fallback for both
    /// `shell/Commons` and `bin/omarchy-shell`.
    pub system_omarchy: PathBuf,
    /// `PATH` for the programs the helper starts.
    pub path: OsString,
    /// `$DBUS_SESSION_BUS_ADDRESS`.
    pub bus: Option<String>,
}

fn absolute(value: Option<OsString>) -> Option<PathBuf> {
    value.map(PathBuf::from).filter(|path| path.is_absolute())
}

impl Env {
    /// Reads the variables through `get` (the process's: [`Env::current`]).
    pub fn from_vars(get: impl Fn(&str) -> Option<OsString>) -> Env {
        let home = absolute(get("HOME"));
        Env {
            cache: absolute(get("XDG_CACHE_HOME"))
                .or_else(|| home.as_ref().map(|h| h.join(".cache"))),
            state: absolute(get("XDG_STATE_HOME"))
                .or_else(|| home.as_ref().map(|h| h.join(".local/state"))),
            data: absolute(get("XDG_DATA_HOME"))
                .or_else(|| home.as_ref().map(|h| h.join(".local/share"))),
            runtime: absolute(get("XDG_RUNTIME_DIR")),
            omarchy: absolute(get("OMARCHY_PATH")),
            system_omarchy: PathBuf::from(SYSTEM_OMARCHY),
            path: get("PATH")
                .filter(|path| !path.is_empty())
                .unwrap_or_else(|| "/usr/local/bin:/usr/bin:/bin".into()),
            bus: get("DBUS_SESSION_BUS_ADDRESS")
                .and_then(|value| value.into_string().ok())
                .filter(|value| !value.is_empty()),
            home,
        }
    }

    pub fn current() -> Env {
        Env::from_vars(|name| std::env::var_os(name))
    }

    fn base(dir: &Option<PathBuf>, variable: &str) -> Result<PathBuf, Failure> {
        dir.clone().ok_or_else(|| {
            Failure::coded(
                "NO_HOME",
                format!("neither {variable} nor HOME is an absolute path"),
            )
        })
    }

    /// `$XDG_CACHE_HOME/foamy-lock-studio`.
    pub fn studio_cache(&self) -> Result<PathBuf, Failure> {
        Ok(Env::base(&self.cache, "XDG_CACHE_HOME")?.join(APP_ID))
    }

    /// `$XDG_STATE_HOME/foamy-lock`.
    pub fn lock_state(&self) -> Result<PathBuf, Failure> {
        Ok(Env::base(&self.state, "XDG_STATE_HOME")?.join("foamy-lock"))
    }

    pub fn data_home(&self) -> Result<PathBuf, Failure> {
        Env::base(&self.data, "XDG_DATA_HOME")
    }

    /// `$OMARCHY_PATH`, else the installed Omarchy.
    pub fn omarchy_dir(&self) -> &Path {
        self.omarchy.as_deref().unwrap_or(&self.system_omarchy)
    }

    /// Omarchy's shell `Commons`: `$OMARCHY_PATH/shell/Commons`, falling
    /// back to the installed one.
    pub fn commons(&self) -> Result<PathBuf, Failure> {
        let mut tried = Vec::new();
        for omarchy in self.omarchy.iter().chain([&self.system_omarchy]) {
            let commons = omarchy.join("shell/Commons");
            if commons.is_dir() {
                return Ok(commons);
            }
            tried.push(commons.display().to_string());
        }
        Err(Failure::coded(
            "COMMONS_MISSING",
            format!(
                "Omarchy's shell Commons wasn't found (looked in {})",
                tried.join(" and ")
            ),
        ))
    }

    /// `program` in `PATH`, else in `fallbacks`.
    pub fn find(&self, program: &str, fallbacks: &[PathBuf]) -> Option<PathBuf> {
        std::env::split_paths(&self.path)
            .filter(|dir| dir.is_absolute())
            .map(|dir| dir.join(program))
            .chain(fallbacks.iter().cloned())
            .find(|path| is_executable(path))
    }
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// The plugin directory: `overridden` (absolute) or two levels above the
/// directory holding `exe`; either must contain `LockView.qml`.
pub fn plugin_dir(
    overridden: Option<OsString>,
    exe: io::Result<PathBuf>,
) -> Result<PathBuf, Failure> {
    let dir = match overridden.filter(|value| !value.is_empty()) {
        Some(value) => {
            let dir = PathBuf::from(value);
            if !dir.is_absolute() {
                return Err(Failure::coded(
                    "INVALID_ARGUMENT",
                    format!("{PLUGIN_DIR_VAR} must be an absolute path"),
                ));
            }
            dir
        }
        None => {
            let exe = exe.map_err(|error| {
                Failure::coded(
                    "PLUGIN_NOT_FOUND",
                    format!("cannot find this helper's path: {error}"),
                )
            })?;
            exe.parent()
                .and_then(Path::parent)
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .ok_or_else(|| {
                    Failure::coded(
                        "PLUGIN_NOT_FOUND",
                        format!("{} isn't inside a plugin's bin/<arch>/", exe.display()),
                    )
                })?
        }
    };
    if !dir.join("LockView.qml").is_file() {
        return Err(Failure::coded(
            "PLUGIN_NOT_FOUND",
            format!(
                "{} isn't a foamy-lock plugin (no LockView.qml)",
                dir.display()
            ),
        ));
    }
    Ok(dir)
}

fn current_plugin_dir() -> Result<PathBuf, Failure> {
    plugin_dir(std::env::var_os(PLUGIN_DIR_VAR), std::env::current_exe())
}

/// Checks the shape of a look: an object with only the four look keys and
/// `userPreset`, `preset` a string, `userPreset` a user preset's id (see
/// [`check_preset_id`]) and the others objects. The lock checks the rest.
pub fn check_look(look: &Value) -> Result<(), String> {
    let Value::Object(look) = look else {
        return Err("a look must be an object".into());
    };
    for (key, value) in look {
        if key == LINK_KEY {
            check_preset_id(value).map_err(|reason| format!("{LINK_KEY}: {reason}"))?;
            continue;
        }
        if !LOOK_KEYS.contains(&key.as_str()) {
            return Err(format!("unknown look key {key}"));
        }
        if key == "preset" && !value.is_string() {
            return Err("preset must be a string".into());
        }
        if key != "preset" && !value.is_object() {
            return Err(format!("{key} must be an object"));
        }
    }
    Ok(())
}

/// A user preset's id, as the lock takes it: 1 to 40 lowercase ASCII
/// letters, digits and dashes, not starting with a dash.
pub fn check_preset_id(id: &Value) -> Result<(), String> {
    let valid = id.as_str().is_some_and(|id| {
        (1..=40).contains(&id.len())
            && !id.starts_with('-')
            && id
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    });
    if valid {
        Ok(())
    } else {
        Err(
            "an id is 1 to 40 lowercase letters, digits and dashes, not starting with a dash"
                .into(),
        )
    }
}

/// `text` (valid JSON) without the whitespace between tokens; key order,
/// numbers and escapes stay exactly as written.
pub fn compact_json(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let (mut in_string, mut escaped) = (false, false);
    for c in text.chars() {
        if in_string {
            out.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
            out.push(c);
        } else if !matches!(c, ' ' | '\t' | '\n' | '\r') {
            out.push(c);
        }
    }
    out
}

/// Reads all of stdin, at most `limit` bytes.
pub fn read_stdin(limit: u64) -> Result<Vec<u8>, Failure> {
    foamy_helper::io::read_stdin_limited(limit).map_err(|error| {
        if foamy_helper::io::is_over_limit(&error) {
            Failure::coded(
                "REQUEST_TOO_LARGE",
                format!("the request is larger than {limit} bytes"),
            )
        } else {
            Failure::coded(
                "INVALID_REQUEST",
                format!("cannot read the request: {error}"),
            )
        }
    })
}

/// An `IO` failure with context.
pub fn io_failure(what: impl std::fmt::Display) -> impl FnOnce(io::Error) -> Failure {
    move |error| Failure::coded("IO", format!("{what}: {error}"))
}

/// Eight random lowercase letters and digits.
pub fn random_suffix() -> io::Result<String> {
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut bytes = [0u8; 8];
    let mut filled = 0;
    while filled < bytes.len() {
        filled +=
            rustix::rand::getrandom(&mut bytes[filled..], rustix::rand::GetRandomFlags::empty())?;
    }
    Ok(bytes
        .iter()
        .map(|&b| CHARS[b as usize % CHARS.len()] as char)
        .collect())
}

/// `time` as ISO 8601 in UTC, to the second (`2026-11-08T10:24:00Z`).
pub fn iso8601(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (days, rest) = (seconds.div_euclid(86400), seconds.rem_euclid(86400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest / 60 % 60,
        rest % 60
    )
}

const USAGE: &str = "usage: foamy-lock-helper studio [open | install | uninstall | draft-load | draft-save | draft-clear | apply | preset save | preset rename | preset delete | pick-picture [title [filter name [media filter name]]]]";

/// `foamy-lock-helper studio <args>`.
pub fn main(args: &[OsString]) -> Result<Value, Failure> {
    let words: Option<Vec<&str>> = args.iter().map(|arg| arg.to_str()).collect();
    let words = words.ok_or_else(|| Failure::coded("INVALID_ARGUMENT", USAGE))?;
    let env = Env::current();
    match words.as_slice() {
        [] | ["open"] => root::open(&env, &current_plugin_dir()?, &root::Options::default()),
        ["install"] => desktop::install(&env, &current_plugin_dir()?),
        ["uninstall"] => desktop::uninstall(&env),
        ["draft-load"] => draft::load(&env),
        ["draft-save"] => draft::save(&env, &read_stdin(draft::MAX_REQUEST)?),
        ["draft-clear"] => draft::clear(&env),
        ["apply"] => apply::apply(
            &env,
            &read_stdin(apply::MAX_REQUEST)?,
            &apply::Options::default(),
        ),
        ["preset", op @ ("save" | "rename" | "delete")] => preset::run(
            &env,
            op,
            &read_stdin(preset::MAX_REQUEST)?,
            &apply::Options::default(),
        ),
        ["pick-picture"] => portal::pick(&env, portal::DEFAULT_TITLE, portal::DEFAULT_FILTER, None),
        ["pick-picture", title] => portal::pick(&env, title, portal::DEFAULT_FILTER, None),
        ["pick-picture", title, filter] => portal::pick(&env, title, filter, None),
        ["pick-picture", title, filter, media] => portal::pick(&env, title, filter, Some(media)),
        _ => Err(Failure::coded("INVALID_ARGUMENT", USAGE)),
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::HashMap;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A fresh directory under the system temp dir (resolved), removed on drop.
    /// Holds `forks::Shared`: studio tests start processes.
    pub struct Scratch(pub PathBuf, crate::forks::Shared);

    impl Scratch {
        pub fn new(tag: &str) -> Scratch {
            static COUNT: AtomicU32 = AtomicU32::new(0);
            let path = std::env::temp_dir().join(format!(
                "foamy-lock-studio-{tag}-{}-{}",
                std::process::id(),
                COUNT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir(&path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
            let forks = crate::forks::Shared::take();
            Scratch(fs::canonicalize(path).unwrap(), forks)
        }

        pub fn path(&self, rel: &str) -> PathBuf {
            self.0.join(rel)
        }

        pub fn file(&self, rel: &str, text: &str) -> PathBuf {
            let path = self.0.join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, text).unwrap();
            path
        }

        /// An executable script `rel` with `body` after a bash shebang.
        pub fn script(&self, rel: &str, body: &str) -> PathBuf {
            let path = self.file(rel, &format!("#!/bin/bash\nPATH=/usr/bin:/bin\n{body}\n"));
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            path
        }

        /// An environment rooted here: HOME, no XDG variables, Omarchy in
        /// `omarchy/` and `PATH` = `bin/`.
        pub fn env(&self) -> Env {
            let vars: HashMap<&str, OsString> = [
                ("HOME", self.path("home").into_os_string()),
                ("PATH", self.path("bin").into_os_string()),
                ("XDG_RUNTIME_DIR", self.path("run").into_os_string()),
            ]
            .into();
            let mut env = Env::from_vars(|name| vars.get(name).cloned());
            env.system_omarchy = self.path("omarchy");
            fs::create_dir_all(self.path("home")).unwrap();
            fs::create_dir_all(self.path("bin")).unwrap();
            env
        }

        /// A minimal plugin in `plugin/`.
        pub fn plugin(&self) -> PathBuf {
            for name in ["LockView.qml", "Layout.js", "Model.js"] {
                self.file(&format!("plugin/{name}"), "// test\n");
            }
            for dir in ["elements", "kit", "i18n"] {
                fs::create_dir_all(self.path(&format!("plugin/{dir}"))).unwrap();
            }
            self.path("plugin")
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn environment_falls_back_to_home() {
        let vars: HashMap<&str, OsString> = [
            ("HOME", "/home/me".into()),
            ("XDG_CACHE_HOME", "relative/cache".into()),
            ("XDG_STATE_HOME", "".into()),
            ("XDG_DATA_HOME", "/data".into()),
            ("OMARCHY_PATH", "/opt/omarchy".into()),
        ]
        .into();
        let env = Env::from_vars(|name| vars.get(name).cloned());
        assert_eq!(
            env.studio_cache().unwrap(),
            Path::new("/home/me/.cache/foamy-lock-studio")
        );
        assert_eq!(
            env.lock_state().unwrap(),
            Path::new("/home/me/.local/state/foamy-lock")
        );
        assert_eq!(env.data_home().unwrap(), Path::new("/data"));
        assert_eq!(env.omarchy_dir(), Path::new("/opt/omarchy"));
        assert_eq!(env.path, "/usr/local/bin:/usr/bin:/bin");
        let bare = Env::from_vars(|_| None);
        assert_eq!(bare.studio_cache().unwrap_err().code, "NO_HOME");
        assert_eq!(bare.omarchy_dir(), Path::new(SYSTEM_OMARCHY));
    }

    #[test]
    fn plugin_dir_is_two_levels_above_the_binary() {
        let scratch = Scratch::new("plugin");
        let plugin = scratch.plugin();
        let exe = plugin.join("bin/x86_64/foamy-lock-helper");
        assert_eq!(plugin_dir(None, Ok(exe.clone())).unwrap(), plugin);
        assert_eq!(
            plugin_dir(Some("".into()), Ok(exe)).unwrap(),
            plugin,
            "an empty override is no override"
        );
        let other = scratch.path("other");
        fs::create_dir_all(other.join("bin/x86_64")).unwrap();
        let failure = plugin_dir(None, Ok(other.join("bin/x86_64/foamy-lock-helper"))).unwrap_err();
        assert_eq!(failure.code, "PLUGIN_NOT_FOUND");
        assert!(failure.message.contains("no LockView.qml"), "{failure}");
        assert_eq!(
            plugin_dir(None, Ok("/x".into())).unwrap_err().code,
            "PLUGIN_NOT_FOUND"
        );
        assert_eq!(
            plugin_dir(None, Err(io::Error::other("gone")))
                .unwrap_err()
                .code,
            "PLUGIN_NOT_FOUND"
        );
        // The override wins and must be absolute.
        assert_eq!(
            plugin_dir(
                Some(plugin.clone().into_os_string()),
                Ok("/x/bin/y/z".into())
            )
            .unwrap(),
            plugin
        );
        assert_eq!(
            plugin_dir(Some("plugin".into()), Ok("/x".into()))
                .unwrap_err()
                .code,
            "INVALID_ARGUMENT"
        );
    }

    #[test]
    fn commons_prefer_omarchy_path_then_the_installed_shell() {
        let scratch = Scratch::new("commons");
        let mut env = scratch.env();
        let failure = env.commons().unwrap_err();
        assert_eq!(failure.code, "COMMONS_MISSING");
        assert!(
            failure.message.contains("omarchy/shell/Commons"),
            "{failure}"
        );
        fs::create_dir_all(scratch.path("omarchy/shell/Commons")).unwrap();
        assert_eq!(
            env.commons().unwrap(),
            scratch.path("omarchy/shell/Commons")
        );
        env.omarchy = Some(scratch.path("dev"));
        assert_eq!(
            env.commons().unwrap(),
            scratch.path("omarchy/shell/Commons"),
            "a missing $OMARCHY_PATH/shell falls back"
        );
        fs::create_dir_all(scratch.path("dev/shell/Commons")).unwrap();
        assert_eq!(env.commons().unwrap(), scratch.path("dev/shell/Commons"));
    }

    #[test]
    fn programs_are_found_in_path_or_a_fallback() {
        let scratch = Scratch::new("find");
        let env = scratch.env();
        assert_eq!(env.find("tool", &[]), None);
        let fallback = scratch.script("omarchy/bin/tool", "exit 0");
        assert_eq!(
            env.find("tool", std::slice::from_ref(&fallback)),
            Some(fallback.clone())
        );
        scratch.file("bin/tool", "not executable");
        assert_eq!(
            env.find("tool", &[fallback]),
            Some(scratch.path("omarchy/bin/tool"))
        );
        let own = scratch.script("bin/tool", "exit 0");
        assert_eq!(env.find("tool", &[]), Some(own));
    }

    #[test]
    fn looks_are_checked_for_shape() {
        assert_eq!(check_look(&json!({})), Ok(()));
        assert_eq!(
            check_look(&json!({"preset": "zen", "layout": {}, "background": {}, "glass": {}})),
            Ok(())
        );
        assert!(check_look(&json!([])).is_err());
        assert_eq!(
            check_look(&json!({"preset": 1})),
            Err("preset must be a string".into())
        );
        assert_eq!(
            check_look(&json!({"glass": []})),
            Err("glass must be an object".into())
        );
        assert_eq!(
            check_look(&json!({"id": "x"})),
            Err("unknown look key id".into())
        );
        // The link to a user preset: an id, and only that.
        assert_eq!(
            check_look(&json!({"preset": "zen", "userPreset": "mine-1"})),
            Ok(())
        );
        for id in [
            json!("Mine"),
            json!(""),
            json!("-a"),
            json!(1),
            json!("a".repeat(41)),
            json!("a/b"),
        ] {
            assert!(check_look(&json!({"userPreset": id})).is_err(), "{id}");
        }
    }

    #[test]
    fn compaction_keeps_strings_and_order() {
        let text =
            "{ \"z\" : 1,\n \"a\": [ 1.50 , \"a b\\\" c\\\\\" ],\t\"m\":{\"k\":\" \\n \"} }\n";
        let compact = compact_json(text);
        assert_eq!(
            compact,
            "{\"z\":1,\"a\":[1.50,\"a b\\\" c\\\\\"],\"m\":{\"k\":\" \\n \"}}"
        );
        let before: Value = serde_json::from_str(text).unwrap();
        let after: Value = serde_json::from_str(&compact).unwrap();
        assert_eq!(before, after);
    }

    #[test]
    fn timestamps_are_utc_iso8601() {
        let at = |seconds: u64| iso8601(UNIX_EPOCH + std::time::Duration::from_secs(seconds));
        assert_eq!(at(0), "1970-01-01T00:00:00Z");
        assert_eq!(at(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(at(1_793_442_240), "2026-10-31T10:24:00Z");
        assert_eq!(at(4_102_444_799), "2099-12-31T23:59:59Z");
    }

    #[test]
    fn suffixes_are_random_names() {
        let (a, b) = (random_suffix().unwrap(), random_suffix().unwrap());
        assert_eq!(a.len(), 8);
        assert!(
            a.bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        );
        assert_ne!(a, b);
    }

    #[test]
    fn unknown_subcommands_are_refused() {
        for args in [
            vec!["nope"],
            vec!["open", "extra"],
            vec!["apply", "x"],
            vec!["preset"],
            vec!["preset", "move"],
            vec!["preset", "save", "x"],
        ] {
            let args: Vec<OsString> = args.into_iter().map(OsString::from).collect();
            assert_eq!(main(&args).unwrap_err().code, "INVALID_ARGUMENT");
        }
        use std::os::unix::ffi::OsStringExt;
        assert_eq!(
            main(&[OsString::from_vec(vec![0xff])]).unwrap_err().code,
            "INVALID_ARGUMENT"
        );
    }
}
