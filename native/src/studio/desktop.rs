//! `studio install` / `studio ensure` / `studio uninstall`: the app
//! launcher entry.
//!
//! - **install** writes `$XDG_DATA_HOME/applications/foamy-lock-studio.desktop`
//!   (0644, atomic) with `StartupWMClass=foamy-lock-studio`, English and
//!   Norwegian Bokmål (`nb`) names and comments, and
//!   `Exec=/bin/sh -c '<script>' sh <helper> <entry> <icon file> <record>`
//!   (each argument quoted per the Desktop Entry spec when it needs it). The
//!   script runs `<helper> studio` while the helper is there (it waits 2 s
//!   for one that is missing, as during a plugin update). Otherwise, once the
//!   plugin's `manifest.json` is gone too, it removes the entry and the icon,
//!   each only while its SHA-256 is in the record: a plugin removal has no
//!   hook, so an entry left behind goes away the first time it is chosen,
//!   and a file the user edited stays. There is no `TryExec`: Quickshell's
//!   DesktopEntries, which Omarchy's menu lists, ignores it, and gtk-launch,
//!   which the menu starts entries with, would then refuse to run the entry,
//!   so it could never clean itself up.
//!   When the plugin has `studio/foamy-lock-studio.svg` (at most 1 MiB) it
//!   is copied to `$XDG_DATA_HOME/icons/hicolor/scalable/apps/foamy-lock-studio.svg`
//!   (0644, atomic) and `Icon=foamy-lock-studio`; otherwise any icon this
//!   command installed before is removed and `Icon=` is the themed
//!   `preferences-desktop-screensaver`. The record,
//!   `$XDG_STATE_HOME/foamy-lock/launcher-files`, holds the SHA-256 of each
//!   file written. It also removes the opt-out marker (below). Reply:
//!   `{"ok": true, "desktop": "<path>", "icon": "<icon name>",
//!   "iconFile": "<path>" | null, "exec": "<helper path>"}`.
//! - **ensure**, which the lock's service runs once per shell start, does
//!   what install does, except that it does nothing after `uninstall` (the
//!   marker `$XDG_STATE_HOME/foamy-lock/launcher-removed` is there), writes
//!   nothing when both files already hold what install would write, and
//!   never replaces or removes a file the user changed. A file is this
//!   helper's when its SHA-256 is in the record, or (an entry from before the
//!   record) when it is one of the entries this helper writes, for any helper
//!   path and either icon. A missing file is added again. Reply:
//!   `{"ok": true, "action": "declined" | "current"}`, or install's reply
//!   with `"action": "installed" | "updated"`, or `"modified"` with
//!   `"modified": ["<path>", …]` when a changed file was left as it is (the
//!   other one is still brought up to date).
//! - **uninstall** removes both files and the record, and writes the marker.
//!   Reply: `{"ok": true, "removed": ["<path>", …]}` (only the entry and icon
//!   that existed).
//!
//! A path that is a symlink or someone else's file is refused (`IO`), never
//! followed or replaced.

use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use foamy_helper::Failure;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{APP_ID, Env, io_failure};

/// The themed icon when the plugin ships none.
pub const FALLBACK_ICON: &str = "preferences-desktop-screensaver";
const MAX_ICON: u64 = 1024 * 1024;
/// More than any entry [`entry`] writes; a bigger file is not ours.
const MAX_ENTRY: u64 = 64 * 1024;
/// More than the record ever holds.
const MAX_RECORD: u64 = 4096;

/// `$1` the helper, `$2` the entry, `$3` the icon file, `$4` the record.
/// A helper that is missing for a moment (a plugin update replacing it) gets
/// 2 s; a plugin that is still there (`manifest.json`) is never cleaned up.
pub const SCRIPT: &str = r#"[ -x "$1" ] || sleep 2; if [ -x "$1" ]; then exec "$1" studio; fi; [ -e "${1%/bin/*}/manifest.json" ] && exit 1; for f in "$2" "$3"; do s=$(sha256sum < "$f" 2>/dev/null) && grep -qxF "${s%% *}" "$4" 2>/dev/null && rm -f -- "$f"; done; exit 0"#;

/// The script entries written before the record (1.3.x): `$1` the helper,
/// `$2` the entry, `$3` the icon file. Only recognised, never written.
const SCRIPT_1_3: &str = r#"if [ -x "$1" ]; then exec "$1" studio; fi; rm -f -- "$2" "$3""#;

const MARKER_TEXT: &[u8] =
    b"Lock Studio's launcher entry was removed with `studio uninstall`; `studio install` adds it again.\n";

const RECORD_HEADER: &str = "# SHA-256 of the Lock Studio launcher files foamy-lock-helper wrote; only these are replaced or removed.\n";

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

/// The SHA-256 of the files install and ensure wrote.
fn record_file(env: &Env) -> Result<PathBuf, Failure> {
    Ok(env.lock_state()?.join("launcher-files"))
}

/// The helper of `plugin` for this CPU.
pub fn helper(plugin: &Path) -> PathBuf {
    plugin
        .join("bin")
        .join(std::env::consts::ARCH)
        .join("foamy-lock-helper")
}

fn sha256(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
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

/// The argument [`exec_argument`] (then [`escape_value`]) wrote as `text`,
/// if it may be one. Callers regenerate the entry and compare, so this only
/// has to be right for what this helper writes.
fn unexec_argument(text: &str) -> Option<String> {
    let mut value = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        value.push(if c == '\\' { chars.next()? } else { c });
    }
    let value = match value.strip_prefix('"').and_then(|v| v.strip_suffix('"')) {
        Some(inner) => {
            let mut out = String::with_capacity(inner.len());
            let mut chars = inner.chars();
            while let Some(c) = chars.next() {
                out.push(if c == '\\' { chars.next()? } else { c });
            }
            out
        }
        None => value,
    };
    Some(value.replace("%%", "%"))
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

/// The start of an `Exec` value: `/bin/sh -c <script> sh`.
fn exec_head(script: &str) -> String {
    escape_value(&format!("/bin/sh -c {} sh", exec_argument(script)))
}

/// The rest of an `Exec` value: ` <arg>` for each argument.
fn exec_tail(args: &[&Path]) -> Result<String, Failure> {
    let mut tail = String::new();
    for arg in args {
        tail.push(' ');
        tail.push_str(&path_argument(arg)?);
    }
    Ok(escape_value(&tail))
}

/// The `Exec` value `/bin/sh -c <script> sh <args…>`.
fn exec_line(script: &str, args: &[&Path]) -> Result<String, Failure> {
    Ok(exec_head(script) + &exec_tail(args)?)
}

fn entry_text(exec: &str, icon: &str) -> String {
    format!(
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
    )
}

/// The entry that starts `helper`, with `icon`, and removes `desktop` and
/// `icon_file` once `helper` is gone, if their SHA-256 is in `record`.
pub fn entry(
    helper: &Path,
    icon: &str,
    desktop: &Path,
    icon_file: &Path,
    record: &Path,
) -> Result<String, Failure> {
    Ok(entry_text(
        &exec_line(SCRIPT, &[helper, desktop, icon_file, record])?,
        icon,
    ))
}

/// Whether `text` is an entry this helper writes (now, or before the record)
/// for these files: the same text for some plugin's helper and either icon.
fn generated(text: &str, desktop: &Path, icon_file: &Path, record: &Path) -> bool {
    let Some(exec) = text.lines().find_map(|line| line.strip_prefix("Exec=")) else {
        return false;
    };
    let variants: [(&str, &[&Path]); 2] = [
        (SCRIPT, &[desktop, icon_file, record]),
        (SCRIPT_1_3, &[desktop, icon_file]),
    ];
    let binary = format!("/bin/{}/foamy-lock-helper", std::env::consts::ARCH);
    variants.into_iter().any(|(script, files)| {
        let Ok(rest) = exec_tail(files) else {
            return false;
        };
        let Some(helper) = exec
            .strip_prefix(exec_head(script).as_str())
            .and_then(|tail| tail.strip_prefix(' '))
            .and_then(|tail| tail.strip_suffix(rest.as_str()))
            .and_then(unexec_argument)
        else {
            return false;
        };
        let helper = Path::new(&helper);
        if !helper.is_absolute() || !helper.to_str().is_some_and(|h| h.ends_with(&binary)) {
            return false;
        }
        let mut args = vec![helper];
        args.extend_from_slice(files);
        let Ok(exec) = exec_line(script, &args) else {
            return false;
        };
        [APP_ID, FALLBACK_ICON]
            .iter()
            .any(|icon| entry_text(&exec, icon) == text)
    })
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

/// What a launcher file holds, as far as ensure is concerned.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Held {
    /// Not there (or, for an icon the plugin doesn't ship, not there).
    Absent,
    /// Already what install would write.
    Current,
    /// Something this helper wrote: it may be replaced or removed.
    Ours,
    /// Changed by someone else, or never ours: left as it is.
    Theirs,
}

/// What `path` holds against `want` (`None`: it should not exist).
/// `ours` says whether other content is this helper's.
fn held(
    path: &Path,
    want: Option<&[u8]>,
    limit: u64,
    ours: impl Fn(&[u8]) -> bool,
) -> Result<Held, Failure> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Ok(if want.is_some() {
                Held::Absent
            } else {
                Held::Current
            });
        }
        Err(error) => return Err(io_failure(path.display())(error)),
        Ok(meta) if !meta.is_file() => {
            return Err(Failure::coded(
                "IO",
                format!("{} isn't a regular file; left alone", path.display()),
            ));
        }
        Ok(_) => {}
    }
    let data = match foamy_helper::fs::read_file_limited(path, limit) {
        Ok(data) => data,
        // Bigger than anything this helper writes.
        Err(error) if error.kind() == ErrorKind::InvalidData => return Ok(Held::Theirs),
        Err(error) => return Err(io_failure(path.display())(error)),
    };
    Ok(if want == Some(data.as_slice()) {
        Held::Current
    } else if ours(&data) {
        Held::Ours
    } else {
        Held::Theirs
    })
}

/// The hashes in the record (none when there is no record).
fn read_record(path: &Path) -> Result<Vec<String>, Failure> {
    match foamy_helper::fs::read_file_limited(path, MAX_RECORD) {
        Ok(data) => Ok(String::from_utf8_lossy(&data)
            .lines()
            .filter(|line| line.len() == 64 && line.bytes().all(|b| b.is_ascii_hexdigit()))
            .map(str::to_string)
            .collect()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(io_failure(path.display())(error)),
    }
}

/// What install writes.
struct Plan {
    helper: PathBuf,
    desktop: PathBuf,
    icon_path: PathBuf,
    record: PathBuf,
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
        let record = record_file(env)?;
        let text = entry(
            &helper,
            Plan::icon_name(&svg),
            &desktop,
            &icon_path,
            &record,
        )?;
        Ok(Plan {
            helper,
            desktop,
            icon_path,
            record,
            svg,
            text,
        })
    }

    fn icon_name(svg: &Option<Vec<u8>>) -> &'static str {
        if svg.is_some() { APP_ID } else { FALLBACK_ICON }
    }

    fn write_icon(&self) -> Result<(), Failure> {
        match &self.svg {
            Some(svg) => {
                ensure_dir(self.icon_path.parent().unwrap_or(&self.icon_path))?;
                foamy_helper::fs::write_atomic(&self.icon_path, svg, 0o644)
                    .map_err(io_failure("cannot install the icon"))
            }
            None => remove(&self.icon_path).map(|_| ()),
        }
    }

    fn write_entry(&self) -> Result<(), Failure> {
        ensure_dir(self.desktop.parent().unwrap_or(&self.desktop))?;
        foamy_helper::fs::write_atomic(&self.desktop, self.text.as_bytes(), 0o644)
            .map_err(io_failure("cannot write the launcher entry"))
    }

    /// The record for the files that now hold what install writes
    /// (`entry`, `icon`: whether each does); written only when it changes.
    fn write_record(&self, old: &[String], entry: bool, icon: bool) -> Result<(), Failure> {
        let mut hashes = Vec::new();
        if entry {
            hashes.push(sha256(self.text.as_bytes()));
        }
        if let (true, Some(svg)) = (icon, &self.svg) {
            hashes.push(sha256(svg));
        }
        if hashes == old {
            return Ok(());
        }
        let mut text = String::from(RECORD_HEADER);
        for hash in &hashes {
            text.push_str(hash);
            text.push('\n');
        }
        ensure_dir(self.record.parent().unwrap_or(&self.record))?;
        foamy_helper::fs::write_atomic(&self.record, text.as_bytes(), 0o644)
            .map_err(io_failure("cannot record the launcher files"))
    }

    fn reply(&self) -> Value {
        json!({
            "ok": true,
            "desktop": self.desktop,
            "icon": Plan::icon_name(&self.svg),
            "iconFile": self.svg.as_ref().map(|_| &self.icon_path),
            "exec": self.helper,
        })
    }
}

/// `studio install`.
pub fn install(env: &Env, plugin: &Path) -> Result<Value, Failure> {
    let plan = Plan::new(env, plugin)?;
    let old = read_record(&plan.record)?;
    plan.write_icon()?;
    plan.write_entry()?;
    plan.write_record(&old, true, true)?;
    remove(&marker_file(env)?)?;
    Ok(plan.reply())
}

/// `studio ensure`.
pub fn ensure(env: &Env, plugin: &Path) -> Result<Value, Failure> {
    if exists(&marker_file(env)?) {
        return Ok(json!({"ok": true, "action": "declined"}));
    }
    let plan = Plan::new(env, plugin)?;
    let record = read_record(&plan.record)?;
    let recorded = |data: &[u8]| record.contains(&sha256(data));
    let entry = held(
        &plan.desktop,
        Some(plan.text.as_bytes()),
        MAX_ENTRY,
        |data| {
            recorded(data)
                || std::str::from_utf8(data)
                    .is_ok_and(|text| generated(text, &plan.desktop, &plan.icon_path, &plan.record))
        },
    )?;
    let icon = held(&plan.icon_path, plan.svg.as_deref(), MAX_ICON, recorded)?;
    if entry == Held::Current && icon == Held::Current {
        plan.write_record(&record, true, true)?;
        return Ok(json!({"ok": true, "action": "current"}));
    }
    let mut modified = Vec::new();
    match icon {
        Held::Absent | Held::Ours => plan.write_icon()?,
        Held::Theirs => modified.push(&plan.icon_path),
        Held::Current => {}
    }
    match entry {
        Held::Absent | Held::Ours => plan.write_entry()?,
        Held::Theirs => modified.push(&plan.desktop),
        Held::Current => {}
    }
    plan.write_record(&record, entry != Held::Theirs, icon != Held::Theirs)?;
    let mut reply = plan.reply();
    if modified.is_empty() {
        reply["action"] = json!(if entry == Held::Absent {
            "installed"
        } else {
            "updated"
        });
    } else {
        reply["action"] = json!("modified");
        reply["modified"] = json!(modified);
    }
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
    remove(&record_file(env)?)?;
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

    fn expected(helper: &str, desktop: &str, icon: &str, record: &str) -> Vec<String> {
        ["/bin/sh", "-c", SCRIPT, "sh", helper, desktop, icon, record]
            .map(String::from)
            .to_vec()
    }

    /// What the entry's `Exec` runs, as a launcher would run it.
    fn launch(desktop: &Path) -> std::process::ExitStatus {
        let args = exec_args(value(&keys(&fs::read_to_string(desktop).unwrap()), "Exec"));
        Command::new(&args[0]).args(&args[1..]).status().unwrap()
    }

    #[test]
    fn the_entry_launches_the_helper() {
        let text = entry(
            Path::new("/p/bin/x86_64/foamy-lock-helper"),
            "foamy-lock-studio",
            Path::new("/d/applications/foamy-lock-studio.desktop"),
            Path::new("/d/icons/foamy-lock-studio.svg"),
            Path::new("/s/foamy-lock/launcher-files"),
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
                "/d/icons/foamy-lock-studio.svg",
                "/s/foamy-lock/launcher-files"
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
                Path::new("/r%"),
            )
            .unwrap();
            assert_eq!(
                exec_args(value(&keys(&text), "Exec")),
                expected(path, "/e f.desktop", "/i$.svg", "/r%"),
                "{path}"
            );
        }
        let text = entry(
            Path::new("/p/h"),
            "x",
            Path::new("/d.desktop"),
            Path::new("/i.svg"),
            Path::new("/r"),
        )
        .unwrap();
        assert!(
            value(&keys(&text), "Exec").ends_with(" sh /p/h /d.desktop /i.svg /r"),
            "plain paths stay bare"
        );
        for (helper, desktop) in [("/a\nb", "/d"), ("/h", "/d\tx")] {
            assert_eq!(
                entry(
                    Path::new(helper),
                    "x",
                    Path::new(desktop),
                    Path::new("/i"),
                    Path::new("/r")
                )
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

        assert!(launch(&desktop).success());
        assert_eq!(fs::read_to_string(scratch.path("ran")).unwrap(), "studio\n");
        assert!(desktop.exists() && icon.exists());

        fs::remove_file(&helper).unwrap();
        assert!(launch(&desktop).success());
        assert!(
            !desktop.exists() && !icon.exists(),
            "a removed plugin's entry goes"
        );
    }

    #[test]
    fn the_entry_keeps_itself_while_the_plugin_is_there_or_the_user_edited_it() {
        let scratch = Scratch::new("selfkeep");
        let plugin = scratch.plugin();
        let ran = scratch.path("ran");
        let body = format!("echo \"$*\" > '{}'", ran.display());
        let helper = scratch.script(
            &format!("plugin/bin/{}/foamy-lock-helper", std::env::consts::ARCH),
            &body,
        );
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        let env = scratch.env();
        install(&env, &plugin).unwrap();
        let desktop = desktop_file(&env).unwrap();
        let icon = icon_file(&env).unwrap();

        // A plugin update replacing the helper: it is back within the wait.
        let moved = scratch.path("helper-moved");
        fs::rename(&helper, &moved).unwrap();
        let restore = std::thread::spawn({
            let (moved, helper) = (moved.clone(), helper.clone());
            move || {
                std::thread::sleep(std::time::Duration::from_millis(500));
                fs::rename(moved, helper).unwrap();
            }
        });
        assert!(launch(&desktop).success());
        restore.join().unwrap();
        assert_eq!(
            fs::read_to_string(&ran).unwrap(),
            "studio\n",
            "the studio still starts"
        );
        assert!(desktop.exists() && icon.exists());

        // The helper is gone but the plugin is still installed: nothing goes.
        scratch.file("plugin/manifest.json", "{}");
        fs::remove_file(&helper).unwrap();
        assert!(!launch(&desktop).success());
        assert!(
            desktop.exists() && icon.exists(),
            "a plugin that is still there keeps its entry"
        );

        // The plugin is gone: an icon the user replaced stays, the entry goes.
        fs::remove_file(scratch.path("plugin/manifest.json")).unwrap();
        fs::write(&icon, "<svg>mine</svg>").unwrap();
        assert!(launch(&desktop).success());
        assert!(!desktop.exists());
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg>mine</svg>");

        // An entry the user edited stays too.
        scratch.script(
            &format!("plugin/bin/{}/foamy-lock-helper", std::env::consts::ARCH),
            &body,
        );
        install(&env, &plugin).unwrap();
        let edited = fs::read_to_string(&desktop).unwrap() + "NoDisplay=true\n";
        fs::write(&desktop, &edited).unwrap();
        fs::remove_file(&helper).unwrap();
        assert!(launch(&desktop).success());
        assert_eq!(fs::read_to_string(&desktop).unwrap(), edited);
        assert!(!icon.exists(), "the icon was still the one install wrote");
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
        fs::write(moved.join("studio/foamy-lock-studio.svg"), "<svg>new</svg>").unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "updated");
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg>new</svg>");
        fs::write(moved.join("studio/foamy-lock-studio.svg"), "<svg/>").unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "updated");
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
    fn ensure_leaves_files_the_user_changed() {
        let scratch = Scratch::new("ensure-edited");
        let plugin = plugin_with_helper(&scratch);
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        let env = scratch.env();
        let desktop = desktop_file(&env).unwrap();
        let icon = icon_file(&env).unwrap();
        assert_eq!(ensure(&env, &plugin).unwrap()["action"], "installed");

        // Hidden from the launcher by hand, and the plugin moves: the entry
        // stays as the user left it; the icon is still brought up to date.
        let edited = fs::read_to_string(&desktop).unwrap() + "NoDisplay=true\n";
        fs::write(&desktop, &edited).unwrap();
        let moved = scratch.path("moved");
        fs::rename(&plugin, &moved).unwrap();
        fs::write(moved.join("studio/foamy-lock-studio.svg"), "<svg>new</svg>").unwrap();
        let reply = ensure(&env, &moved).unwrap();
        assert_eq!(reply["action"], "modified");
        assert_eq!(reply["modified"], json!([desktop]));
        assert_eq!(fs::read_to_string(&desktop).unwrap(), edited);
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg>new</svg>");
        let modified = fs::metadata(&desktop).unwrap().modified().unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "modified");
        assert_eq!(
            fs::metadata(&desktop).unwrap().modified().unwrap(),
            modified
        );

        // A replaced icon stays too, even once the plugin ships none.
        install(&env, &moved).unwrap();
        fs::write(&icon, "<svg>mine</svg>").unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["modified"], json!([icon]));
        fs::remove_file(moved.join("studio/foamy-lock-studio.svg")).unwrap();
        let reply = ensure(&env, &moved).unwrap();
        assert_eq!(reply["modified"], json!([icon]));
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg>mine</svg>");
        assert!(
            fs::read_to_string(&desktop)
                .unwrap()
                .contains(&format!("\nIcon={FALLBACK_ICON}\n")),
            "the unchanged entry follows"
        );

        // `install` is the user asking: it replaces both.
        scratch.file("moved/studio/foamy-lock-studio.svg", "<svg/>");
        install(&env, &moved).unwrap();
        assert_eq!(fs::read_to_string(&icon).unwrap(), "<svg/>");
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "current");

        // Something else entirely at the entry's path is never ours.
        fs::write(&desktop, "[Desktop Entry]\nName=Mine\n").unwrap();
        assert_eq!(ensure(&env, &moved).unwrap()["action"], "modified");
        assert_eq!(
            fs::read_to_string(&desktop).unwrap(),
            "[Desktop Entry]\nName=Mine\n"
        );
    }

    #[test]
    fn ensure_updates_entries_from_before_the_record() {
        let scratch = Scratch::new("ensure-legacy");
        let plugin = plugin_with_helper(&scratch);
        scratch.file("plugin/studio/foamy-lock-studio.svg", "<svg/>");
        let env = scratch.env();
        let desktop = desktop_file(&env).unwrap();
        let icon = icon_file(&env).unwrap();
        let record = record_file(&env).unwrap();
        // What 1.3.x's ensure wrote, for a plugin since moved, and no record.
        let old_helper = scratch.path(&format!(
            "old plugin/bin/{}/foamy-lock-helper",
            std::env::consts::ARCH
        ));
        let legacy = |icon_name: &str| {
            entry_text(
                &exec_line(SCRIPT_1_3, &[&old_helper, &desktop, &icon]).unwrap(),
                icon_name,
            )
        };
        for icon_name in [APP_ID, FALLBACK_ICON] {
            fs::create_dir_all(desktop.parent().unwrap()).unwrap();
            fs::write(&desktop, legacy(icon_name)).unwrap();
            let _ = fs::remove_file(&record);
            assert!(generated(&legacy(icon_name), &desktop, &icon, &record));
            assert_eq!(
                ensure(&env, &plugin).unwrap()["action"],
                "updated",
                "{icon_name}"
            );
            let text = fs::read_to_string(&desktop).unwrap();
            assert!(text.contains(helper(&plugin).to_str().unwrap()));
            assert!(
                text.contains(record.to_str().unwrap()),
                "the new script, which checks the record"
            );
            assert!(
                read_record(&record)
                    .unwrap()
                    .contains(&sha256(text.as_bytes()))
            );
            assert_eq!(ensure(&env, &plugin).unwrap()["action"], "current");
        }
        // A current entry without a record gets one, so it can clean up.
        fs::remove_file(&record).unwrap();
        assert_eq!(ensure(&env, &plugin).unwrap()["action"], "current");
        assert_eq!(read_record(&record).unwrap().len(), 2);

        // Not one of ours: another program, a changed line or key, a helper
        // path that isn't a plugin's.
        let ours = legacy(APP_ID);
        for other in [
            ours.replace("Name=Lock Studio", "Name=My Studio"),
            ours.replace("Terminal=false\n", ""),
            ours.replace(old_helper.to_str().unwrap(), "/usr/bin/foamy-lock-helper2"),
            ours.replace(
                old_helper.to_str().unwrap(),
                "relative/bin/x/foamy-lock-helper",
            ),
            ours.replace(" studio;", " studio --verbose;"),
            ours.clone() + "NoDisplay=true\n",
        ] {
            assert!(!generated(&other, &desktop, &icon, &record), "{other}");
        }
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
