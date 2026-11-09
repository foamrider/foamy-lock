//! `studio install` / `studio ensure` / `studio uninstall`: the app
//! launcher entry.
//!
//! - **install** writes `$XDG_DATA_HOME/applications/foamy-lock-studio.desktop`
//!   (0644, atomic) with `StartupWMClass=foamy-lock-studio`, English and
//!   Norwegian Bokmål (`nb`) names and comments, and
//!   `Exec=/bin/sh -c '<script>' sh <helper> <entry> <icon file>` (each
//!   argument quoted per the Desktop Entry spec when it needs it). The
//!   script runs `<helper> studio` while the helper is there, and otherwise
//!   removes the entry and the icon: a plugin removal has no hook, so an
//!   entry left behind goes away the first time it is chosen. There is no
//!   `TryExec`: Quickshell's DesktopEntries, which Omarchy's menu lists,
//!   ignores it, and gtk-launch, which the menu starts entries with, would
//!   then refuse to run the entry, so it could never clean itself up.
//!   When the plugin has `studio/foamy-lock-studio.svg` (at most 1 MiB) it
//!   is copied to `$XDG_DATA_HOME/icons/hicolor/scalable/apps/foamy-lock-studio.svg`
//!   (0644, atomic) and `Icon=foamy-lock-studio`; otherwise any icon this
//!   command installed before is removed and `Icon=` is the themed
//!   `preferences-desktop-screensaver`. It also removes the opt-out marker
//!   (below). Reply: `{"ok": true, "desktop": "<path>", "icon": "<icon
//!   name>", "iconFile": "<path>" | null, "exec": "<helper path>"}`.
//! - **ensure**, which the lock's service runs once per shell start, does
//!   what install does, except that it does nothing after `uninstall` (the
//!   marker `$XDG_STATE_HOME/foamy-lock/launcher-removed` is there) and
//!   writes nothing when both files already hold what install would write.
//!   Reply: `{"ok": true, "action": "declined" | "current"}`, or install's
//!   reply with `"action": "installed" | "updated"`.
//! - **uninstall** removes both files and writes the marker. Reply:
//!   `{"ok": true, "removed": ["<path>", …]}` (only those that existed).
//!
//! A path that is a symlink or someone else's file is refused (`IO`), never
//! followed or replaced.

use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use foamy_helper::Failure;
use serde_json::{Value, json};

use super::{APP_ID, Env, io_failure};

/// The themed icon when the plugin ships none.
pub const FALLBACK_ICON: &str = "preferences-desktop-screensaver";
const MAX_ICON: u64 = 1024 * 1024;
/// More than any entry [`entry`] writes; a bigger file is not ours.
const MAX_ENTRY: u64 = 64 * 1024;

/// `$1` the helper, `$2` the entry, `$3` the icon file.
pub const SCRIPT: &str = r#"if [ -x "$1" ]; then exec "$1" studio; fi; rm -f -- "$2" "$3""#;

const MARKER_TEXT: &[u8] =
    b"Lock Studio's launcher entry was removed with `studio uninstall`; `studio install` adds it again.\n";

fn desktop_file(env: &Env) -> Result<PathBuf, Failure> {
    Ok(env
        .data_home()?
        .join("applications")
        .join(format!("{APP_ID}.desktop")))
}

fn icon_file(env: &Env) -> Result<PathBuf, Failure> {
    Ok(env
        .data_home()?
        .join("icons/hicolor/scalable/apps")
        .join(format!("{APP_ID}.svg")))
}

/// Left by `uninstall`: `ensure` adds no entry while it is there.
fn marker_file(env: &Env) -> Result<PathBuf, Failure> {
    Ok(env.lock_state()?.join("launcher-removed"))
}

/// The helper of `plugin` for this CPU.
pub fn helper(plugin: &Path) -> PathBuf {
    plugin
        .join("bin")
        .join(std::env::consts::ARCH)
        .join("foamy-lock-helper")
}

/// A `string` value of a desktop entry key (`\s`, `\n`, `\t`, `\r`, `\\`).
fn escape_value(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out
}

/// One `Exec` argument: bare when it is plain, else double-quoted with
/// `"`, `` ` ``, `$` and `\` escaped (then, like every value, `\` doubled
/// by [`escape_value`]); `%` is always `%%`.
fn exec_argument(text: &str) -> String {
    let text = text.replace('%', "%%");
    if text
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "/._+-,:@%".contains(c))
    {
        return text;
    }
    let mut quoted = String::from("\"");
    for c in text.chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            quoted.push('\\');
        }
        quoted.push(c);
    }
    quoted.push('"');
    quoted
}

/// `path` as an `Exec` argument, if it can be one.
fn path_argument(path: &Path) -> Result<String, Failure> {
    match path
        .to_str()
        .filter(|text| !text.chars().any(char::is_control))
    {
        Some(text) => Ok(exec_argument(text)),
        None => Err(Failure::coded(
            "INVALID_ARGUMENT",
            format!(
                "{} can't go in a launcher entry (not UTF-8, or a control character)",
                path.display()
            ),
        )),
    }
}

/// The entry that starts `helper`, with `icon`, and removes `desktop` and
/// `icon_file` once `helper` is gone.
pub fn entry(
    helper: &Path,
    icon: &str,
    desktop: &Path,
    icon_file: &Path,
) -> Result<String, Failure> {
    let exec = escape_value(&format!(
        "/bin/sh -c {} sh {} {} {}",
        exec_argument(SCRIPT),
        path_argument(helper)?,
        path_argument(desktop)?,
        path_argument(icon_file)?,
    ));
    Ok(format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Version=1.5\n\
         Name=Lock Studio\n\
         Name[nb]=Låsestudio\n\
         GenericName=Lock screen designer\n\
         GenericName[nb]=Utforming av låseskjermen\n\
         Comment=Design the Foamy lock screen\n\
         Comment[nb]=Utform Foamy-låseskjermen\n\
         Keywords=lock;screen;design;foamy;\n\
         Keywords[nb]=lås;skjerm;utforming;foamy;\n\
         Exec={exec}\n\
         Icon={}\n\
         Terminal=false\n\
         Categories=Settings;DesktopSettings;\n\
         StartupWMClass={APP_ID}\n",
        escape_value(icon),
    ))
}

fn ensure_dir(dir: &Path) -> Result<(), Failure> {
    fs::create_dir_all(dir).map_err(io_failure(dir.display()))
}

fn remove(path: &Path) -> Result<bool, Failure> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() => {
            fs::remove_file(path).map_err(io_failure(path.display()))?;
            Ok(true)
        }
        Ok(_) => Err(Failure::coded(
            "IO",
            format!("{} isn't a regular file; left alone", path.display()),
        )),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_failure(path.display())(error)),
    }
}

fn exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

/// Whether `path` is a regular file holding exactly `data`.
fn holds(path: &Path, data: &[u8], limit: u64) -> bool {
    foamy_helper::fs::read_file_limited(path, limit).is_ok_and(|text| text == data)
}

/// What install writes.
struct Plan {
    helper: PathBuf,
    desktop: PathBuf,
    icon_path: PathBuf,
    /// The shipped icon, or `None` for the themed fallback.
    svg: Option<Vec<u8>>,
    text: String,
}

impl Plan {
    fn new(env: &Env, plugin: &Path) -> Result<Plan, Failure> {
        let helper = helper(plugin);
        if !fs::metadata(&helper).is_ok_and(|meta| meta.is_file()) {
            return Err(Failure::coded(
                "PLUGIN_NOT_FOUND",
                format!("{} is missing", helper.display()),
            ));
        }
        let source = plugin.join("studio").join(format!("{APP_ID}.svg"));
        let svg = match foamy_helper::fs::read_file_limited(&source, MAX_ICON) {
            Ok(svg) => Some(svg),
            Err(error) if error.kind() == ErrorKind::NotFound => None,
            Err(error) => return Err(io_failure("cannot read the icon")(error)),
        };
        let desktop = desktop_file(env)?;
        let icon_path = icon_file(env)?;
        let text = entry(&helper, Plan::icon_name(&svg), &desktop, &icon_path)?;
        Ok(Plan {
            helper,
            desktop,
            icon_path,
            svg,
            text,
        })
    }

    fn icon_name(svg: &Option<Vec<u8>>) -> &'static str {
        if svg.is_some() { APP_ID } else { FALLBACK_ICON }
    }

    /// Both files already as they would be written.
    fn is_current(&self) -> bool {
        holds(&self.desktop, self.text.as_bytes(), MAX_ENTRY)
            && match &self.svg {
                Some(svg) => holds(&self.icon_path, svg, MAX_ICON),
                None => !exists(&self.icon_path),
            }
    }

    fn write(&self) -> Result<Value, Failure> {
        let icon = match &self.svg {
            Some(svg) => {
                ensure_dir(self.icon_path.parent().unwrap_or(&self.icon_path))?;
                foamy_helper::fs::write_atomic(&self.icon_path, svg, 0o644)
                    .map_err(io_failure("cannot install the icon"))?;
                Some(&self.icon_path)
            }
            None => {
                remove(&self.icon_path)?;
                None
            }
        };
        ensure_dir(self.desktop.parent().unwrap_or(&self.desktop))?;
        foamy_helper::fs::write_atomic(&self.desktop, self.text.as_bytes(), 0o644)
            .map_err(io_failure("cannot write the launcher entry"))?;
        Ok(json!({
            "ok": true,
            "desktop": self.desktop,
            "icon": Plan::icon_name(&self.svg),
            "iconFile": icon,
            "exec": self.helper,
        }))
    }
}

/// `studio install`.
pub fn install(env: &Env, plugin: &Path) -> Result<Value, Failure> {
    let reply = Plan::new(env, plugin)?.write()?;
    remove(&marker_file(env)?)?;
    Ok(reply)
}

/// `studio ensure`.
pub fn ensure(env: &Env, plugin: &Path) -> Result<Value, Failure> {
    if exists(&marker_file(env)?) {
        return Ok(json!({"ok": true, "action": "declined"}));
    }
    let plan = Plan::new(env, plugin)?;
    if plan.is_current() {
        return Ok(json!({"ok": true, "action": "current"}));
    }
    let action = if exists(&plan.desktop) {
        "updated"
    } else {
        "installed"
    };
    let mut reply = plan.write()?;
    reply["action"] = json!(action);
    Ok(reply)
}

/// `studio uninstall`.
pub fn uninstall(env: &Env) -> Result<Value, Failure> {
    let mut removed = Vec::new();
    for path in [desktop_file(env)?, icon_file(env)?] {
        if remove(&path)? {
            removed.push(path);
        }
    }
    let marker = marker_file(env)?;
    ensure_dir(marker.parent().unwrap_or(&marker))?;
    foamy_helper::fs::write_atomic(&marker, MARKER_TEXT, 0o644)
        .map_err(io_failure("cannot record the removal"))?;
    Ok(json!({"ok": true, "removed": removed}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::process::Command;

    fn plugin_with_helper(scratch: &Scratch) -> PathBuf {
        let plugin = scratch.plugin();
        scratch.script(
            &format!("plugin/bin/{}/foamy-lock-helper", std::env::consts::ARCH),
            "exit 0",
        );
        plugin
    }

    /// The keys of a desktop entry, in order.
    fn keys(text: &str) -> Vec<(String, String)> {
        text.lines()
            .skip(1)
            .map(|line| {
                let (key, value) = line.split_once('=').unwrap();
                (key.to_string(), value.to_string())
            })
            .collect()
    }

    fn value<'a>(entries: &'a [(String, String)], key: &str) -> &'a str {
        &entries.iter().find(|(k, _)| k == key).unwrap().1
    }

    /// `Exec` read back as the Desktop Entry spec says a launcher reads it:
    /// the string value's escapes, then quoted arguments and `%%`.
    fn exec_args(exec: &str) -> Vec<String> {
        let mut unescaped = String::new();
        let mut chars = exec.chars();
        while let Some(c) = chars.next() {
            if c != '\\' {
                unescaped.push(c);
                continue;
            }
            match chars.next().unwrap() {
                's' => unescaped.push(' '),
                'n' => unescaped.push('\n'),
                't' => unescaped.push('\t'),
                'r' => unescaped.push('\r'),
                '\\' => unescaped.push('\\'),
                other => panic!("unknown escape \\{other}"),
            }
        }
        let mut args = Vec::new();
        let mut chars = unescaped.chars().peekable();
        while let Some(&c) = chars.peek() {
            if c == ' ' {
                chars.next();
                continue;
            }
            let mut arg = String::new();
            if c == '"' {
                chars.next();
                loop {
                    match chars.next().expect("an unterminated quote") {
                        '"' => break,
                        '\\' => {
                            let next = chars.next().unwrap();
                            assert!(matches!(next, '"' | '`' | '$' | '\\'), "\\{next} in quotes");
                            arg.push(next);
                        }
                        other => arg.push(other),
                    }
                }
            } else {
                while let Some(&c) = chars.peek() {
                    if c == ' ' {
                        break;
                    }
                    assert!(!"\"'\\><~|&;$*?#()`\t".contains(c), "{c} unquoted");
                    arg.push(c);
                    chars.next();
                }
            }
            args.push(arg.replace("%%", "%"));
        }
        args
    }

    fn expected(helper: &str, desktop: &str, icon: &str) -> Vec<String> {
        ["/bin/sh", "-c", SCRIPT, "sh", helper, desktop, icon]
            .map(String::from)
            .to_vec()
    }

    #[test]
    fn the_entry_launches_the_helper() {
        let text = entry(
            Path::new("/p/bin/x86_64/foamy-lock-helper"),
            "foamy-lock-studio",
            Path::new("/d/applications/foamy-lock-studio.desktop"),
            Path::new("/d/icons/foamy-lock-studio.svg"),
        )
        .unwrap();
        assert!(text.starts_with("[Desktop Entry]\n"));
        assert!(text.ends_with('\n'));
        let entries = keys(&text);
        assert_eq!(
            exec_args(value(&entries, "Exec")),
            expected(
                "/p/bin/x86_64/foamy-lock-helper",
                "/d/applications/foamy-lock-studio.desktop",
                "/d/icons/foamy-lock-studio.svg"
            )
        );
        assert!(
            !entries.iter().any(|(k, _)| k == "TryExec"),
            "no TryExec: gtk-launch would skip the clean-up"
        );
        assert_eq!(value(&entries, "Name"), "Lock Studio");
        assert_eq!(value(&entries, "Name[nb]"), "Låsestudio");
        assert_eq!(value(&entries, "Comment[nb]"), "Utform Foamy-låseskjermen");
        assert_eq!(value(&entries, "StartupWMClass"), "foamy-lock-studio");
        assert_eq!(value(&entries, "Icon"), "foamy-lock-studio");
        assert_eq!(value(&entries, "Type"), "Application");
        assert_eq!(value(&entries, "Categories"), "Settings;DesktopSettings;");
        let unique: std::collections::BTreeSet<_> = entries.iter().map(|(k, _)| k).collect();
        assert_eq!(unique.len(), entries.len(), "no key twice");
    }

    #[test]
    fn exec_paths_are_quoted_when_they_need_it() {
        for path in [
            "/a b/helper",
            "/a$b/h\"x",
            "/a\\b",
            "/100%/h",
            "/x`y'z;(1)/h",
        ] {
            let text = entry(
                Path::new(path),
                "x",
                Path::new("/e f.desktop"),
                Path::new("/i$.svg"),
            )
            .unwrap();
            assert_eq!(
                exec_args(value(&keys(&text), "Exec")),
                expected(path, "/e f.desktop", "/i$.svg"),
                "{path}"
            );
        }
        let text = entry(
            Path::new("/p/h"),
            "x",
            Path::new("/d.desktop"),
            Path::new("/i.svg"),
        )
        .unwrap();
        assert!(
            value(&keys(&text), "Exec").ends_with(" sh /p/h /d.desktop /i.svg"),
            "plain paths stay bare"
        );
        for (helper, desktop) in [("/a\nb", "/d"), ("/h", "/d\tx")] {
            assert_eq!(
                entry(Path::new(helper), "x", Path::new(desktop), Path::new("/i"))
                    .unwrap_err()
                    .code,
                "INVALID_ARGUMENT"
            );
        }
    }

    #[test]
    fn the_entry_runs_the_helper_then_removes_itself_once_it_is_gone() {
        let scratch = Scratch::new("selfclean");
        let plugin = scratch.plugin();
        let helper = scratch.script(
            &format!("plugin/bin/{}/foamy-lock-helper", std::env::consts::ARCH),
            &format!("echo \"$*\" > '{}'", scratch.path("ran").display()),
        );
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        let env = scratch.env();
        install(&env, &plugin).unwrap();
        let desktop = desktop_file(&env).unwrap();
        let icon = icon_file(&env).unwrap();
        let run = || {
            let args = exec_args(value(&keys(&fs::read_to_string(&desktop).unwrap()), "Exec"));
            let status = Command::new(&args[0]).args(&args[1..]).status().unwrap();
            assert!(status.success());
        };

        run();
        assert_eq!(fs::read_to_string(scratch.path("ran")).unwrap(), "studio\n");
        assert!(desktop.exists() && icon.exists());

        fs::remove_file(&helper).unwrap();
        run();
        assert!(
            !desktop.exists() && !icon.exists(),
            "a removed plugin's entry goes"
        );
    }

    #[test]
    fn install_writes_the_entry_and_the_fallback_icon() {
        let scratch = Scratch::new("install");
        let plugin = plugin_with_helper(&scratch);
        let env = scratch.env();
        let reply = install(&env, &plugin).unwrap();
        let desktop = scratch.path("home/.local/share/applications/foamy-lock-studio.desktop");
        assert_eq!(reply["desktop"], desktop.to_str().unwrap());
        assert_eq!(reply["icon"], FALLBACK_ICON);
        assert_eq!(reply["iconFile"], Value::Null);
        let text = fs::read_to_string(&desktop).unwrap();
        let entries = keys(&text);
        assert_eq!(
            exec_args(value(&entries, "Exec"))[4],
            helper(&plugin).to_str().unwrap()
        );
        assert_eq!(value(&entries, "Icon"), FALLBACK_ICON);
        assert_eq!(
            fs::metadata(&desktop).unwrap().permissions().mode() & 0o777,
            0o644
        );
        // Again: replaced, not duplicated.
        install(&env, &plugin).unwrap();
        assert_eq!(fs::read_dir(desktop.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn a_shipped_icon_is_installed_and_removed_with_the_entry() {
        let scratch = Scratch::new("icon");
        let plugin = plugin_with_helper(&scratch);
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        let mut env = scratch.env();
        env.data = Some(scratch.path("data"));
        let reply = install(&env, &plugin).unwrap();
        let icon = scratch.path("data/icons/hicolor/scalable/apps/foamy-lock-studio.svg");
        assert_eq!(reply["icon"], APP_ID);
        assert_eq!(reply["iconFile"], icon.to_str().unwrap());
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg/>");
        let desktop = scratch.path("data/applications/foamy-lock-studio.desktop");
        assert!(
            fs::read_to_string(&desktop)
                .unwrap()
                .contains("\nIcon=foamy-lock-studio\n")
        );

        // The plugin stops shipping it: the old copy goes.
        fs::remove_file(scratch.path("plugin/studio/foamy-lock-studio.svg")).unwrap();
        install(&env, &plugin).unwrap();
        assert!(!icon.exists());
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        install(&env, &plugin).unwrap();

        let reply = uninstall(&env).unwrap();
        assert_eq!(reply["removed"], json!([desktop, icon]));
        assert!(!desktop.exists() && !icon.exists());
        assert_eq!(uninstall(&env).unwrap()["removed"], json!([]));
    }

    #[test]
    fn ensure_adds_the_entry_once_and_respects_an_uninstall() {
        let scratch = Scratch::new("ensure");
        let plugin = plugin_with_helper(&scratch);
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        let env = scratch.env();
        let desktop = desktop_file(&env).unwrap();
        let icon = icon_file(&env).unwrap();
        let marker = scratch.path("home/.local/state/foamy-lock/launcher-removed");

        let reply = ensure(&env, &plugin).unwrap();
        assert_eq!(reply["action"], "installed");
        assert_eq!(reply["desktop"], desktop.to_str().unwrap());
        let modified = fs::metadata(&desktop).unwrap().modified().unwrap();
        assert_eq!(
            ensure(&env, &plugin).unwrap(),
            json!({"ok": true, "action": "current"})
        );
        assert_eq!(
            fs::metadata(&desktop).unwrap().modified().unwrap(),
            modified,
            "nothing rewritten"
        );

        // The plugin moves, or the icon changes or goes: the entry follows.
        let moved = scratch.path("moved");
        fs::rename(&plugin, &moved).unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "updated");
        assert!(
            fs::read_to_string(&desktop)
                .unwrap()
                .contains(moved.to_str().unwrap())
        );
        fs::write(&icon, "<svg>edited</svg>").unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "updated");
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg/>");
        fs::remove_file(moved.join("studio/foamy-lock-studio.svg")).unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "updated");
        assert!(!icon.exists());
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "current");

        // Removed by hand: it comes back, as nothing says it shouldn't.
        fs::remove_file(&desktop).unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "installed");

        // `uninstall` is remembered until `install`.
        uninstall(&env).unwrap();
        assert!(marker.is_file());
        assert_eq!(
            ensure(&env, &moved).unwrap(),
            json!({"ok": true, "action": "declined"})
        );
        assert!(!desktop.exists());
        install(&env, &moved).unwrap();
        assert!(!marker.exists());
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "current");

        // Without the helper there is nothing to point at.
        let bare = Scratch::new("ensure-bare");
        assert_eq!(
            ensure(&bare.env(), &bare.plugin()).unwrap_err().code,
            "PLUGIN_NOT_FOUND"
        );
    }

    #[test]
    fn links_and_missing_helpers_are_refused() {
        let scratch = Scratch::new("refuse");
        let plugin = scratch.plugin();
        let env = scratch.env();
        assert_eq!(install(&env, &plugin).unwrap_err().code, "PLUGIN_NOT_FOUND");
        let plugin = plugin_with_helper(&scratch);
        let desktop = scratch.path("home/.local/share/applications/foamy-lock-studio.desktop");
        fs::create_dir_all(desktop.parent().unwrap()).unwrap();
        let target = scratch.file("elsewhere.desktop", "keep");
        symlink(&target, &desktop).unwrap();
        assert_eq!(install(&env, &plugin).unwrap_err().code, "IO");
        assert_eq!(ensure(&env, &plugin).unwrap_err().code, "IO");
        assert_eq!(uninstall(&env).unwrap_err().code, "IO");
        assert_eq!(fs::read_to_string(&target).unwrap(), "keep");
        assert!(
            fs::symlink_metadata(&desktop)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
}
