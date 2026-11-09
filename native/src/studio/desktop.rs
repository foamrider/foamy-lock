//! `studio install` / `studio uninstall`: the app launcher entry.
//!
//! - **install** writes `$XDG_DATA_HOME/applications/foamy-lock-studio.desktop`
//!   (0644, atomic) with `Exec=<plugin>/bin/<arch>/foamy-lock-helper studio`
//!   (quoted per the Desktop Entry spec when the path needs it), `TryExec=`
//!   the same binary, `StartupWMClass=foamy-lock-studio`, English and
//!   Norwegian Bokmål (`nb`) names and comments. When the plugin has
//!   `studio/foamy-lock-studio.svg` (at most 1 MiB) it is copied to
//!   `$XDG_DATA_HOME/icons/hicolor/scalable/apps/foamy-lock-studio.svg`
//!   (0644, atomic) and `Icon=foamy-lock-studio`; otherwise any icon this
//!   command installed before is removed and `Icon=` is the themed
//!   `preferences-desktop-screensaver`. Reply: `{"ok": true, "desktop":
//!   "<path>", "icon": "<icon name>", "iconFile": "<path>" | null, "exec":
//!   "<helper path>"}`.
//! - **uninstall** removes both files. Reply: `{"ok": true, "removed":
//!   ["<path>", …]}` (only those that existed).
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

/// The entry for `helper`, with `icon`.
pub fn entry(helper: &Path, icon: &str) -> Result<String, Failure> {
    let Some(path) = helper
        .to_str()
        .filter(|path| !path.chars().any(char::is_control))
    else {
        return Err(Failure::coded(
            "INVALID_ARGUMENT",
            format!(
                "{} can't go in a launcher entry (not UTF-8, or a control character)",
                helper.display()
            ),
        ));
    };
    let exec = escape_value(&format!("{} studio", exec_argument(path)));
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
         TryExec={}\n\
         Icon={}\n\
         Terminal=false\n\
         Categories=Settings;DesktopSettings;\n\
         StartupWMClass={APP_ID}\n",
        escape_value(path),
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

/// `studio install`.
pub fn install(env: &Env, plugin: &Path) -> Result<Value, Failure> {
    let helper = helper(plugin);
    if !fs::metadata(&helper).is_ok_and(|meta| meta.is_file()) {
        return Err(Failure::coded(
            "PLUGIN_NOT_FOUND",
            format!("{} is missing", helper.display()),
        ));
    }
    let source = plugin.join("studio").join(format!("{APP_ID}.svg"));
    let icon_path = icon_file(env)?;
    let icon = match foamy_helper::fs::read_file_limited(&source, MAX_ICON) {
        Ok(svg) => {
            ensure_dir(icon_path.parent().unwrap_or(&icon_path))?;
            foamy_helper::fs::write_atomic(&icon_path, &svg, 0o644)
                .map_err(io_failure("cannot install the icon"))?;
            Some(icon_path)
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {
            remove(&icon_path)?;
            None
        }
        Err(error) => return Err(io_failure("cannot read the icon")(error)),
    };
    let name = if icon.is_some() {
        APP_ID
    } else {
        FALLBACK_ICON
    };
    let text = entry(&helper, name)?;
    let desktop = desktop_file(env)?;
    ensure_dir(desktop.parent().unwrap_or(&desktop))?;
    foamy_helper::fs::write_atomic(&desktop, text.as_bytes(), 0o644)
        .map_err(io_failure("cannot write the launcher entry"))?;
    Ok(json!({"ok": true, "desktop": desktop, "icon": name, "iconFile": icon, "exec": helper}))
}

/// `studio uninstall`.
pub fn uninstall(env: &Env) -> Result<Value, Failure> {
    let mut removed = Vec::new();
    for path in [desktop_file(env)?, icon_file(env)?] {
        if remove(&path)? {
            removed.push(path);
        }
    }
    Ok(json!({"ok": true, "removed": removed}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::os::unix::fs::{PermissionsExt, symlink};

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

    #[test]
    fn the_entry_launches_the_helper() {
        let text = entry(
            Path::new("/p/bin/x86_64/foamy-lock-helper"),
            "foamy-lock-studio",
        )
        .unwrap();
        assert!(text.starts_with("[Desktop Entry]\n"));
        assert!(text.ends_with('\n'));
        let entries = keys(&text);
        assert_eq!(
            value(&entries, "Exec"),
            "/p/bin/x86_64/foamy-lock-helper studio"
        );
        assert_eq!(
            value(&entries, "TryExec"),
            "/p/bin/x86_64/foamy-lock-helper"
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
        let exec = |path: &str| {
            let text = entry(Path::new(path), "x").unwrap();
            value(&keys(&text), "Exec").to_string()
        };
        assert_eq!(exec("/a b/helper"), "\"/a b/helper\" studio");
        assert_eq!(exec("/a$b/h\"x"), "\"/a\\\\$b/h\\\\\"x\" studio");
        assert_eq!(exec("/a\\b"), "\"/a\\\\\\\\b\" studio");
        assert_eq!(exec("/100%/h"), "/100%%/h studio");
        let text = entry(Path::new("/a b/h"), "x").unwrap();
        assert_eq!(
            value(&keys(&text), "TryExec"),
            "/a b/h",
            "TryExec is a plain string"
        );
        assert_eq!(
            entry(Path::new("/a\nb"), "x").unwrap_err().code,
            "INVALID_ARGUMENT"
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
            value(&entries, "Exec"),
            format!("{} studio", helper(&plugin).display())
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
