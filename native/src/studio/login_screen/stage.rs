//! `studio login-screen stage`: the lock's applied look, sent by Lock Studio
//! on stdin, as a staging folder that the publisher later copies into
//! `/usr/share/sddm/themes/foamy-lock` as root
//! (docs/plans/lock-login-screen.md, "What is copied"). It runs as the user
//! and decodes nothing: the pictures were already made by the sandboxed
//! `background` and `avatar` kinds, and only their PNG header is read here.
//!
//! **stdin** (at most 256 KiB), one JSON object with exactly these keys:
//!
//! - `look`: the look the lock confirmed it applied, at most 64 KiB as
//!   compact JSON. Only its shape is checked here: `check_look`, `layout`
//!   keys among `Layout.js`'s element names, each element an object. The
//!   values are `Layout.js`'s job: the lock parsed this look with it, and
//!   the greeter runs the same `parseLook` on the snapshot.
//! - `showsPicture`: boolean, whether the look shows a picture. Studio
//!   computes it with `Layout.js`, which knows each preset's own source.
//! - `timeFormat`: `"24h"` or `"12h"`; `showUserInfo` and `rightToLeft`:
//!   booleans; `language` and `formatLocale`: 1 to 35 ASCII letters,
//!   digits, `-` and `_`.
//! - `colors`: every key of [`COLOR_KEYS`], nothing else, each `#rrggbb` or
//!   `#aarrggbb` (stored in lower case). They are `Commons.Color`'s values
//!   as the lock reads them: `background`, `foreground`, `accent`, `muted`,
//!   `urgent`; `lockBackground`, `lockBorder`, `lockBorderError`,
//!   `lockPlaceholder`, `lockSelection`, `lockText`, `lockTextError`
//!   (`Commons.Color.lock.*`); `popupsBackground`, `popupsBorder`,
//!   `popupsText` (`Commons.Color.popups.*`, read by `FoamyPalette`); and
//!   `FoamyPalette`'s `warning`, `success`, `error` and `info`.
//! - `lockThemed`: the `lock*` colour keys the theme sets itself (LockView's
//!   `themeLock` uses its own glass colours for the others), each at most
//!   once; stored in [`COLOR_KEYS`] order.
//! - `background`, `avatar`: null, or an absolute path to a regular file
//!   (not a symlink at the last component) of this user's, at most 25 MiB,
//!   with a PNG signature and an `IHDR` of at most 3840 × 2160: `avatar`
//!   exactly `<cache>/omarchy/foamy.lock/avatar.png`, `background`
//!   `<cache>/omarchy/foamy.lock/background/<64 hex>.png`, `<cache>` being
//!   `$XDG_CACHE_HOME` or `$HOME/.cache`. `background` must be null unless
//!   `showsPicture` is true.
//!
//! Anything else fails with `INVALID_REQUEST` (exit 1), naming the field.
//!
//! **The look, filtered**: `userPreset` goes. In `layout`, `media`,
//! `status` and `weather` are always `{"hidden": true}` (the greeter has no
//! player, status services or Foamy Weather); the other elements lose
//! `screens` (the greeter's outputs differ) and keep the rest. With
//! `showsPicture`, the background (or `{}`) becomes `source: "picture"`
//! without `path`, `motion`, `pauseOnBattery` and `color`; the picture is
//! the request's `background` file (else `BACKGROUND_MISSING`). Otherwise
//! it keeps everything but `path`. `preset` and `glass` stay. Then any
//! string left in the look (key or value) that starts with `/` or `~`, or
//! contains `://` or `file:`, fails with `INVALID_REQUEST` naming its JSON
//! path, so no path from the user's files reaches the snapshot.
//!
//! **The greeter bundle**: `<plugin>/sddm/bundle.txt` (at most 64 KiB of
//! UTF-8) lists the plugin files the theme needs, one plugin-relative path
//! per line (docs/plans/lock-login-screen.md, "Step 3 contract"). Each line
//! is trimmed; blank lines and lines starting with `#` are skipped. At most
//! [`MAX_BUNDLE_ENTRIES`] paths, each a `status::check_path` path (1 to 4
//! plain components of `[A-Za-z0-9._-]`, none starting with `.`). A path's
//! place in the theme is the path without its leading `sddm/` (`sddm/X` →
//! `X`); any other path keeps its place. Two paths with the same place, a
//! place that is one of [`STAGE_NAMES`], or a place that is a folder of
//! another (`kit` and `kit/X`) are refused. Each file is opened from the
//! plugin folder without following a symlink in any component; it must be
//! a regular file of at most 2 MiB, and all of them together at most
//! 32 MiB. A problem with `bundle.txt` (a missing one too) or a listed file
//! fails with `BUNDLE_INVALID`, naming the line or path: these are plugin
//! files, so the plugin is broken.
//!
//! **Strings**: the plugin's translation catalog for `language`:
//! `i18n/<language>.json`, else `i18n/<language before the first ->.json`,
//! else `{}`. Opened as the bundle files are, at most 128 KiB, it must be a
//! JSON object whose values are strings or objects of strings (plural forms,
//! `{"one": …, "other": …}`, as `kit/FoamyI18nText.js` reads them), else
//! `BUNDLE_INVALID`. The snapshot carries it as `strings`.
//!
//! **Output**: `$XDG_RUNTIME_DIR/foamy-lock/login-screen/stage-<random>/`
//! (0700; `NO_RUNTIME_DIR` without an absolute, existing
//! `$XDG_RUNTIME_DIR`). Under `login-screen/stage.lock` (waited for 5 s,
//! else `BUSY`) the older `stage-*` entries are removed first, so only the
//! newest stays. Each file is new (`O_EXCL`, no symlinks), 0600 and
//! fsynced; the bundle's subfolders are new and 0700. Then the folders are
//! fsynced. The folder holds:
//!
//! - `snapshot.json`, one compact JSON line, sorted keys (the same request
//!   gives the same bytes), at most 256 KiB: `{"version": 1, "user": <login
//!   name of the calling uid, from its passwd entry>, "timeFormat",
//!   "showUserInfo", "language", "formatLocale", "rightToLeft", "look":
//!   <filtered>, "colors", "lockThemed", "strings": <the catalog>, "files":
//!   {"background": "background.png" | null, "avatar": "avatar.png" |
//!   null}}`.
//! - `background.png`, `avatar.png` when given: byte copies.
//! - The bundle files at their places in the theme (`Main.qml`,
//!   `kit/FoamyStyle.qml`, `elements/ClockElement.qml`, …): byte copies.
//! - `manifest.json`, written last: `{"version": 1, "plugin": <version in
//!   <plugin>/manifest.json>, "hash": <64 hex>, "files": [{"name", "size",
//!   "sha256"}, …]}`, the files in the order `snapshot.json`,
//!   `background.png`, `avatar.png` (those present), then the bundle files
//!   sorted by their place (byte order). `hash` is the SHA-256
//!   (lowercase hex) of the UTF-8 text `plugin <version>\n` followed by one
//!   line `<name> <size> <sha256>\n` per listed file in that order (size in
//!   decimal bytes): the same request with the same plugin version and
//!   plugin files has the same hash in any folder.
//!
//! Reply `{"ok": true, "dir": <folder>, "hash": <hash>, "files": [<every
//! name in the manifest, in its order>]}`. A failure once the folder exists
//! removes it.
//!
//! Codes besides `studio`'s: `BACKGROUND_MISSING`, `BUNDLE_INVALID`,
//! `NO_RUNTIME_DIR`,
//! `NO_USER` (no passwd entry for this uid), and `PLUGIN_NOT_FOUND` for a
//! plugin manifest without a usable version.

use std::collections::BTreeMap;
use std::ffi::CStr;
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::fd::OwnedFd;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use foamy_helper::Failure;
use foamy_helper::lock::FileLock;
use rustix::fs::{AtFlags, FileType, Mode, OFlags};
use rustix::io::Errno;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::status::check_path;
use crate::studio::draft::MAX_LOOK;
use crate::studio::{Env, check_look, io_failure, random_suffix};

/// The largest request `stage` reads from stdin.
pub const MAX_REQUEST: u64 = 256 * 1024;
/// The look (at most 64 KiB) and the catalog (at most 128 KiB) fit with
/// room to spare: compact JSON is never longer than the text it was parsed
/// from, as every escape it writes was an escape in the input too.
pub const MAX_SNAPSHOT: usize = 256 * 1024;
/// Bytes in `sddm/bundle.txt`.
pub const MAX_BUNDLE_LIST: u64 = 64 * 1024;
/// Paths `sddm/bundle.txt` lists.
pub const MAX_BUNDLE_ENTRIES: usize = 200;
/// Bytes in one bundle file, and in all of them.
pub const MAX_BUNDLE_FILE: u64 = 2 * 1024 * 1024;
pub const MAX_BUNDLE_TOTAL: u64 = 32 * 1024 * 1024;
/// Bytes in the translation catalog.
pub const MAX_CATALOG: u64 = 128 * 1024;
/// The names in the theme folder that `stage` or the publisher write.
pub const STAGE_NAMES: [&str; 5] = [
    "snapshot.json",
    "background.png",
    "avatar.png",
    "manifest.json",
    "theme.conf",
];
const BUNDLE_LIST: &str = "sddm/bundle.txt";
/// Bytes in one picture. The helper's backgrounds are stored (uncompressed)
/// RGB PNGs (`image::encode_rgb`), so the largest allowed one, 3840 × 2160,
/// is 24,887,323 bytes.
pub const MAX_PICTURE: u64 = 25 * 1024 * 1024;
pub const MAX_WIDTH: u32 = 3840;
pub const MAX_HEIGHT: u32 = 2160;
const MAX_TAG: usize = 35;
const MAX_PLUGIN_MANIFEST: u64 = 64 * 1024;
const VERSION: u64 = 1;
const STAGE_PREFIX: &str = "stage-";
const LOCK_WAIT: Duration = Duration::from_secs(5);

/// The colours the greeter needs, in stored order (see the module doc).
pub const COLOR_KEYS: [&str; 19] = [
    "background",
    "foreground",
    "accent",
    "muted",
    "urgent",
    "lockBackground",
    "lockBorder",
    "lockBorderError",
    "lockPlaceholder",
    "lockSelection",
    "lockText",
    "lockTextError",
    "popupsBackground",
    "popupsBorder",
    "popupsText",
    "warning",
    "success",
    "error",
    "info",
];

const REQUEST_KEYS: [&str; 11] = [
    "look",
    "showsPicture",
    "timeFormat",
    "showUserInfo",
    "language",
    "formatLocale",
    "rightToLeft",
    "colors",
    "lockThemed",
    "background",
    "avatar",
];

// Layout.js's element names (the_elements_match_layout_js compares them).
const ELEMENTS: [&str; 8] = [
    "date", "clock", "account", "password", "media", "status", "calendar", "weather",
];
/// Elements the greeter can't show: always hidden.
const GREETER_HIDDEN: [&str; 3] = ["media", "status", "weather"];
/// What a picture background loses: the user's path, the video-only keys
/// and the solid colour it doesn't show.
const PICTURE_DROPPED: [&str; 4] = ["path", "motion", "pauseOnBattery", "color"];

fn object<'a>(path: &str, value: &'a Value) -> Result<&'a Map<String, Value>, String> {
    value
        .as_object()
        .ok_or_else(|| format!("{path} must be an object"))
}

/// Whether `text` looks like a path or URL into the user's files.
fn is_user_path(text: &str) -> bool {
    text.starts_with('/') || text.starts_with('~') || text.contains("://") || text.contains("file:")
}

/// Refuses any string (key or value) in `value` that looks like a user
/// path, naming its JSON path. This replaces knowing every key that might
/// hold one, so it can't drift from Layout.js.
fn path_error(path: &str, value: &Value) -> Result<(), String> {
    match value {
        Value::String(text) if is_user_path(text) => {
            Err(format!("{path} looks like a path to the user's files"))
        }
        Value::Array(items) => items
            .iter()
            .enumerate()
            .try_for_each(|(index, item)| path_error(&format!("{path}[{index}]"), item)),
        Value::Object(map) => map.iter().try_for_each(|(key, item)| {
            let inner = format!("{path}.{key}");
            if is_user_path(key) {
                return Err(format!("{inner} looks like a path to the user's files"));
            }
            path_error(&inner, item)
        }),
        _ => Ok(()),
    }
}

/// Checks `look`'s shape and returns it as the login screen gets it (see
/// the module doc). `shows_picture` is Studio's answer from Layout.js.
/// Values are Layout.js's to check, in the lock and in the greeter.
pub fn filter_look(look: &Value, shows_picture: bool) -> Result<Value, String> {
    check_look(look).map_err(|reason| format!("look: {reason}"))?;
    let size = serde_json::to_vec(look).map_or(usize::MAX, |bytes| bytes.len());
    if size > MAX_LOOK {
        return Err(format!("look is larger than {MAX_LOOK} bytes"));
    }
    let look = object("look", look)?;
    let empty = Map::new();
    let layout = match look.get("layout") {
        Some(layout) => object("look.layout", layout)?,
        None => &empty,
    };
    for (name, item) in layout {
        if !ELEMENTS.contains(&name.as_str()) {
            return Err(format!("look.layout has an unknown element: {name}"));
        }
        object(&format!("look.layout.{name}"), item)?;
    }

    // `userPreset` is the only other key check_look lets past: it goes.
    let mut out = Map::new();
    for key in ["preset", "glass"] {
        if let Some(value) = look.get(key) {
            out.insert(key.into(), value.clone());
        }
    }
    let mut elements = Map::new();
    for name in ELEMENTS {
        if GREETER_HIDDEN.contains(&name) {
            elements.insert(name.into(), json!({"hidden": true}));
        } else if let Some(Value::Object(item)) = layout.get(name) {
            let mut item = item.clone();
            item.remove("screens");
            elements.insert(name.into(), Value::Object(item));
        }
    }
    out.insert("layout".into(), Value::Object(elements));
    let background = look.get("background").and_then(Value::as_object);
    if shows_picture {
        let mut kept = background.cloned().unwrap_or_default();
        kept.retain(|key, _| !PICTURE_DROPPED.contains(&key.as_str()));
        kept.insert("source".into(), json!("picture"));
        out.insert("background".into(), Value::Object(kept));
    } else if let Some(background) = background {
        let mut kept = background.clone();
        kept.remove("path");
        out.insert("background".into(), Value::Object(kept));
    }
    let out = Value::Object(out);
    path_error("look", &out)?;
    Ok(out)
}

fn tag(request: &Map<String, Value>, key: &str) -> Result<String, String> {
    request
        .get(key)
        .and_then(Value::as_str)
        .filter(|tag| {
            (1..=MAX_TAG).contains(&tag.len())
                && tag
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        })
        .map(str::to_owned)
        .ok_or_else(|| {
            format!("{key} must be 1 to {MAX_TAG} ASCII letters, digits, dashes and underscores")
        })
}

fn boolean(request: &Map<String, Value>, key: &str) -> Result<bool, String> {
    request
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| format!("{key} must be true or false"))
}

fn is_hex_color(text: &str) -> bool {
    (text.len() == 7 || text.len() == 9)
        && text.starts_with('#')
        && text[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

fn colors(value: &Value) -> Result<Map<String, Value>, String> {
    let colors = value.as_object().ok_or("colors must be an object")?;
    if colors.len() > 32 {
        return Err("colors has more than 32 entries".into());
    }
    if let Some(key) = colors
        .keys()
        .find(|key| !COLOR_KEYS.contains(&key.as_str()))
    {
        return Err(format!("colors has an unknown key: {key}"));
    }
    let mut out = Map::new();
    for key in COLOR_KEYS {
        let color = colors
            .get(key)
            .ok_or_else(|| format!("colors.{key} is missing"))?
            .as_str()
            .filter(|text| is_hex_color(text))
            .ok_or_else(|| format!("colors.{key} must be #rrggbb or #aarrggbb"))?;
        out.insert(key.into(), json!(color.to_ascii_lowercase()));
    }
    Ok(out)
}

fn lock_themed(value: &Value) -> Result<Vec<Value>, String> {
    let keys = value.as_array().ok_or("lockThemed must be an array")?;
    let lock_keys: Vec<&str> = COLOR_KEYS
        .into_iter()
        .filter(|key| key.starts_with("lock"))
        .collect();
    for (index, key) in keys.iter().enumerate() {
        if !key.as_str().is_some_and(|key| lock_keys.contains(&key)) {
            return Err(format!(
                "lockThemed[{index}] must be one of {}",
                lock_keys.join(", ")
            ));
        }
        if keys[..index].contains(key) {
            return Err(format!("lockThemed names {key} twice"));
        }
    }
    Ok(lock_keys
        .into_iter()
        .filter(|name| keys.iter().any(|key| key.as_str() == Some(name)))
        .map(Value::from)
        .collect())
}

/// A prepared picture the request names.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Picture {
    Background,
    Avatar,
}

impl Picture {
    fn key(self) -> &'static str {
        match self {
            Picture::Background => "background",
            Picture::Avatar => "avatar",
        }
    }

    fn file_name(self) -> &'static str {
        match self {
            Picture::Background => "background.png",
            Picture::Avatar => "avatar.png",
        }
    }

    /// Where the lock cache keeps it, for a message.
    fn place(self) -> &'static str {
        match self {
            Picture::Background => "omarchy/foamy.lock/background/<sha256>.png",
            Picture::Avatar => "omarchy/foamy.lock/avatar.png",
        }
    }

    /// Whether `path` is where the lock cache keeps this picture (the
    /// `background` and `avatar` kinds' output, see `store.rs`).
    fn in_cache(self, path: &Path, cache: &Path) -> bool {
        if path.components().any(|part| part == Component::ParentDir) {
            return false;
        }
        let lock = cache.join("omarchy/foamy.lock");
        match self {
            Picture::Avatar => path == lock.join("avatar.png"),
            Picture::Background => {
                let hashed = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| {
                        name.len() == 68
                            && name.ends_with(".png")
                            && name[..64]
                                .bytes()
                                .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                    });
                hashed && path.parent() == Some(lock.join("background").as_path())
            }
        }
    }
}

/// The width and height in a PNG's `IHDR`, from the header bytes alone.
pub fn png_size(data: &[u8]) -> Result<(u32, u32), String> {
    const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
    if data.len() < 24 || !data.starts_with(SIGNATURE) {
        return Err("is not a PNG".into());
    }
    if data[8..12] != [0, 0, 0, 13] || &data[12..16] != b"IHDR" {
        return Err("has no PNG IHDR".into());
    }
    let width = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
    let height = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
    if width == 0 || height == 0 || width > MAX_WIDTH || height > MAX_HEIGHT {
        return Err(format!(
            "is {width} x {height}; at most {MAX_WIDTH} x {MAX_HEIGHT} is allowed"
        ));
    }
    Ok((width, height))
}

fn invalid(reason: impl Into<String>) -> Failure {
    Failure::coded("INVALID_REQUEST", reason)
}

/// Reads a prepared picture the request names (see the module doc).
fn read_picture(env: &Env, which: Picture, value: &Value) -> Result<Option<Vec<u8>>, Failure> {
    let key = which.key();
    let text = match value {
        Value::Null => return Ok(None),
        Value::String(text)
            if text.starts_with('/') && !text.contains('\0') && text.len() <= 4096 =>
        {
            text
        }
        _ => return Err(invalid(format!("{key} must be null or an absolute path"))),
    };
    let path = Path::new(text);
    let cache = Env::base(&env.cache, "XDG_CACHE_HOME")?;
    if !which.in_cache(path, &cache) {
        return Err(invalid(format!(
            "{key} must be {}/{}",
            cache.display(),
            which.place()
        )));
    }
    let flags =
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY;
    let fd = rustix::fs::open(path, flags, Mode::empty()).map_err(|error| match error {
        Errno::LOOP => invalid(format!("{key} is a symlink")),
        Errno::NOENT => invalid(format!("{key} doesn't exist: {text}")),
        error => io_failure(format!("cannot open {text}"))(error.into()),
    })?;
    let stat = rustix::fs::fstat(&fd).map_err(|error| io_failure(text)(error.into()))?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(invalid(format!("{key} is not a regular file")));
    }
    if stat.st_uid != rustix::process::getuid().as_raw() {
        return Err(invalid(format!("{key} is not owned by this user")));
    }
    let too_large = || invalid(format!("{key} is larger than {MAX_PICTURE} bytes"));
    if stat.st_size as u64 > MAX_PICTURE {
        return Err(too_large());
    }
    // Bounded again while reading: the file may grow after the fstat.
    let data = foamy_helper::io::read_limited(File::from(fd), MAX_PICTURE).map_err(|error| {
        if foamy_helper::io::is_over_limit(&error) {
            too_large()
        } else {
            io_failure(format!("cannot read {text}"))(error)
        }
    })?;
    png_size(&data).map_err(|reason| invalid(format!("{key} {reason}")))?;
    Ok(Some(data))
}

/// A checked request; the pictures are only named, not read yet.
pub struct Request {
    /// The filtered look.
    pub look: Value,
    /// Whether the look shows a picture (Studio's `showsPicture`).
    pub picture: bool,
    /// timeFormat, showUserInfo, language, formatLocale, rightToLeft.
    pub settings: Map<String, Value>,
    /// The language, which picks the catalog.
    pub language: String,
    pub colors: Map<String, Value>,
    pub lock_themed: Vec<Value>,
    pub background: Value,
    pub avatar: Value,
}

pub fn parse_request(bytes: &[u8]) -> Result<Request, String> {
    let Ok(Value::Object(request)) = serde_json::from_slice::<Value>(bytes) else {
        return Err("expected a JSON object".into());
    };
    if let Some(key) = request
        .keys()
        .find(|key| !REQUEST_KEYS.contains(&key.as_str()))
    {
        return Err(format!("unknown key {key}"));
    }
    if let Some(key) = REQUEST_KEYS.iter().find(|key| !request.contains_key(**key)) {
        return Err(format!("{key} is missing"));
    }
    let picture = request["showsPicture"]
        .as_bool()
        .ok_or("showsPicture must be true or false")?;
    let look = filter_look(&request["look"], picture)?;
    let time_format = request["timeFormat"]
        .as_str()
        .filter(|format| ["24h", "12h"].contains(format))
        .ok_or("timeFormat must be \"24h\" or \"12h\"")?;
    let mut settings = Map::new();
    settings.insert("timeFormat".into(), json!(time_format));
    settings.insert(
        "showUserInfo".into(),
        json!(boolean(&request, "showUserInfo")?),
    );
    let language = tag(&request, "language")?;
    settings.insert("language".into(), json!(language));
    settings.insert("formatLocale".into(), json!(tag(&request, "formatLocale")?));
    settings.insert(
        "rightToLeft".into(),
        json!(boolean(&request, "rightToLeft")?),
    );
    Ok(Request {
        look,
        picture,
        settings,
        language,
        colors: colors(&request["colors"])?,
        lock_themed: lock_themed(&request["lockThemed"])?,
        background: request["background"].clone(),
        avatar: request["avatar"].clone(),
    })
}

/// The login name of this process's uid, from its passwd entry (never
/// `$USER`).
fn login_name() -> Result<String, Failure> {
    let uid = rustix::process::getuid().as_raw();
    let mut buffer = vec![0 as libc::c_char; 4096];
    loop {
        // SAFETY: passwd is plain data, for which all zeroes (null
        // pointers) is a valid value.
        let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call; getpwuid_r writes at
        // most `buffer.len()` bytes into `buffer` and points `entry`'s
        // strings into it.
        let status = unsafe {
            libc::getpwuid_r(
                uid,
                &mut entry,
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut found,
            )
        };
        if status == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if status != 0 {
            return Err(io_failure("cannot read this user's passwd entry")(
                io::Error::from_raw_os_error(status),
            ));
        }
        if found.is_null() || entry.pw_name.is_null() {
            return Err(Failure::coded(
                "NO_USER",
                format!("uid {uid} has no passwd entry"),
            ));
        }
        // SAFETY: pw_name points to a NUL-terminated string in `buffer`,
        // which is still alive and unchanged.
        let name = unsafe { CStr::from_ptr(entry.pw_name) };
        return name
            .to_str()
            .ok()
            .filter(|name| {
                !name.is_empty() && name.len() <= 256 && !name.chars().any(char::is_control)
            })
            .map(str::to_owned)
            .ok_or_else(|| {
                Failure::coded("NO_USER", format!("uid {uid} has an unusable login name"))
            });
    }
}

/// The plugin's version, from `<plugin>/manifest.json`.
fn plugin_version(plugin_dir: &Path) -> Result<String, Failure> {
    let path = plugin_dir.join("manifest.json");
    let unusable =
        |why: String| Failure::coded("PLUGIN_NOT_FOUND", format!("{}: {why}", path.display()));
    let bytes = foamy_helper::fs::read_file_limited(&path, MAX_PLUGIN_MANIFEST)
        .map_err(|error| unusable(error.to_string()))?;
    let manifest: Value =
        serde_json::from_slice(&bytes).map_err(|error| unusable(format!("not JSON: {error}")))?;
    manifest
        .get("version")
        .and_then(Value::as_str)
        .filter(|version| {
            (1..=64).contains(&version.len())
                && version
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._+~-".contains(&b))
        })
        .map(str::to_owned)
        .ok_or_else(|| unusable("no usable version".into()))
}

fn bundle_invalid(reason: impl Into<String>) -> Failure {
    Failure::coded("BUNDLE_INVALID", reason)
}

/// One file `sddm/bundle.txt` lists: its plugin path and its place in the
/// theme.
#[derive(Debug, PartialEq)]
pub struct BundleEntry {
    pub source: String,
    pub place: String,
}

/// The paths in `sddm/bundle.txt`'s text, sorted by place (see the module
/// doc). Errors name the line.
pub fn parse_bundle(bytes: &[u8]) -> Result<Vec<BundleEntry>, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| format!("{BUNDLE_LIST} isn't UTF-8"))?;
    // Place → line, to name both lines of a clash.
    let mut places: BTreeMap<String, (usize, String)> = BTreeMap::new();
    for (index, line) in text.split('\n').enumerate() {
        let number = index + 1;
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let at = |why: String| format!("{BUNDLE_LIST} line {number}: {why}");
        if places.len() == MAX_BUNDLE_ENTRIES {
            return Err(at(format!("more than {MAX_BUNDLE_ENTRIES} paths")));
        }
        check_path(line).map_err(at)?;
        let place = line.strip_prefix("sddm/").unwrap_or(line);
        if STAGE_NAMES.contains(&place) {
            return Err(at(format!(
                "{line} would replace {place}, which stage writes"
            )));
        }
        if let Some((other, _)) = places.get(place) {
            return Err(at(format!(
                "{line} has the same place as line {other}: {place}"
            )));
        }
        places.insert(place.to_string(), (number, line.to_string()));
    }
    // A place inside a folder that is another place (`kit` and `kit/X`) or
    // a name stage writes: each of its parent folders is looked up.
    for (place, (number, line)) in &places {
        for (end, _) in place.match_indices('/') {
            let folder = &place[..end];
            let clash = if STAGE_NAMES.contains(&folder) {
                Some("stage writes it".to_string())
            } else {
                places
                    .get(folder)
                    .map(|(other, _)| format!("line {other} lists it as a file"))
            };
            if let Some(clash) = clash {
                return Err(format!(
                    "{BUNDLE_LIST} line {number}: {line} needs a folder {folder}, but {clash}"
                ));
            }
        }
    }
    Ok(places
        .into_iter()
        .map(|(place, (_, source))| BundleEntry { source, place })
        .collect())
}

/// Why opening a plugin file failed.
enum PluginFileError {
    Missing,
    /// A broken plugin file, in English.
    Invalid(String),
}

/// Reads the plugin file `rel` (a [`check_path`] path) under `plugin`, at
/// most `limit` bytes. Only the plugin folder itself is followed through a
/// symlink (it is the binary's own folder, or the test override); every
/// component below it is opened with `O_NOFOLLOW`, so the read can't leave
/// the plugin.
fn read_plugin_file(plugin: &OwnedFd, rel: &str, limit: u64) -> Result<Vec<u8>, PluginFileError> {
    let invalid = |why: String| PluginFileError::Invalid(format!("{rel}: {why}"));
    let parts: Vec<&str> = rel.split('/').collect();
    let (last, folders) = parts.split_last().expect("split yields one piece");
    let mut owned: Option<OwnedFd> = None;
    for part in folders {
        let dir = owned.as_ref().unwrap_or(plugin);
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        owned = Some(match rustix::fs::openat(dir, *part, flags, Mode::empty()) {
            Ok(fd) => fd,
            Err(Errno::NOENT) => return Err(PluginFileError::Missing),
            Err(Errno::LOOP) => return Err(invalid(format!("{part} is a symlink"))),
            Err(Errno::NOTDIR) => {
                // O_NOFOLLOW | O_DIRECTORY on a symlink: tell the two apart.
                let link = rustix::fs::statat(dir, *part, AtFlags::SYMLINK_NOFOLLOW)
                    .is_ok_and(|stat| FileType::from_raw_mode(stat.st_mode) == FileType::Symlink);
                let why = if link {
                    "is a symlink"
                } else {
                    "isn't a folder"
                };
                return Err(invalid(format!("{part} {why}")));
            }
            Err(error) => return Err(invalid(format!("cannot open {part}: {error}"))),
        });
    }
    let dir = owned.as_ref().unwrap_or(plugin);
    let flags =
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC | OFlags::NOCTTY;
    let fd = match rustix::fs::openat(dir, *last, flags, Mode::empty()) {
        Ok(fd) => fd,
        Err(Errno::NOENT) => return Err(PluginFileError::Missing),
        Err(Errno::LOOP) => return Err(invalid("is a symlink".into())),
        Err(error) => return Err(invalid(format!("cannot open it: {error}"))),
    };
    let stat = rustix::fs::fstat(&fd).map_err(|error| invalid(error.to_string()))?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(invalid("isn't a regular file".into()));
    }
    let too_large = || invalid(format!("is larger than {limit} bytes"));
    if stat.st_size as u64 > limit {
        return Err(too_large());
    }
    // Bounded again while reading: the file may grow after the fstat.
    foamy_helper::io::read_limited(File::from(fd), limit).map_err(|error| {
        if foamy_helper::io::is_over_limit(&error) {
            too_large()
        } else {
            invalid(error.to_string())
        }
    })
}

fn open_plugin(plugin_dir: &Path) -> Result<OwnedFd, Failure> {
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC;
    rustix::fs::open(plugin_dir, flags, Mode::empty())
        .map_err(|error| bundle_invalid(format!("cannot open {}: {error}", plugin_dir.display())))
}

/// The bundle files as `(place, bytes)`, sorted by place.
fn read_bundle(plugin: &OwnedFd) -> Result<Vec<(String, Vec<u8>)>, Failure> {
    let list = match read_plugin_file(plugin, BUNDLE_LIST, MAX_BUNDLE_LIST) {
        Ok(list) => list,
        Err(PluginFileError::Missing) => {
            return Err(bundle_invalid(format!("{BUNDLE_LIST} is missing")));
        }
        Err(PluginFileError::Invalid(why)) => return Err(bundle_invalid(why)),
    };
    let entries = parse_bundle(&list).map_err(bundle_invalid)?;
    let mut total = 0u64;
    let mut files = Vec::with_capacity(entries.len());
    for entry in entries {
        let data = match read_plugin_file(plugin, &entry.source, MAX_BUNDLE_FILE) {
            Ok(data) => data,
            Err(PluginFileError::Missing) => {
                return Err(bundle_invalid(format!("{} is missing", entry.source)));
            }
            Err(PluginFileError::Invalid(why)) => return Err(bundle_invalid(why)),
        };
        total += data.len() as u64;
        if total > MAX_BUNDLE_TOTAL {
            return Err(bundle_invalid(format!(
                "the bundle files are larger than {MAX_BUNDLE_TOTAL} bytes together"
            )));
        }
        files.push((entry.place, data));
    }
    Ok(files)
}

/// Checks a catalog's shape (see the module doc) and returns it.
pub fn parse_catalog(rel: &str, bytes: &[u8]) -> Result<Map<String, Value>, String> {
    let Ok(Value::Object(catalog)) = serde_json::from_slice::<Value>(bytes) else {
        return Err(format!("{rel} isn't a JSON object"));
    };
    for (key, value) in &catalog {
        let plain = match value {
            Value::String(_) => true,
            Value::Object(forms) => forms.values().all(Value::is_string),
            _ => false,
        };
        if !plain {
            return Err(format!(
                "{rel}: {key:?} must be a string or an object of strings"
            ));
        }
    }
    Ok(catalog)
}

/// The catalog for `language` (see the module doc), or `{}`.
fn read_strings(plugin: &OwnedFd, language: &str) -> Result<Map<String, Value>, Failure> {
    let mut tags = vec![language];
    if let Some((base, _)) = language.split_once('-') {
        tags.push(base);
    }
    for tag in tags {
        let rel = format!("i18n/{tag}.json");
        match read_plugin_file(plugin, &rel, MAX_CATALOG) {
            Ok(bytes) => return parse_catalog(&rel, &bytes).map_err(bundle_invalid),
            Err(PluginFileError::Missing) => continue,
            Err(PluginFileError::Invalid(why)) => return Err(bundle_invalid(why)),
        }
    }
    Ok(Map::new())
}

/// The manifest's `hash` (see the module doc).
pub fn manifest_hash(plugin: &str, files: &[(&str, &[u8])]) -> String {
    let mut text = format!("plugin {plugin}\n");
    for (name, data) in files {
        text += &format!("{name} {} {:x}\n", data.len(), Sha256::digest(data));
    }
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

/// `manifest.json`'s content.
pub fn manifest(plugin: &str, files: &[(&str, &[u8])]) -> Value {
    let listed: Vec<Value> = files
        .iter()
        .map(|(name, data)| {
            json!({"name": name, "size": data.len(), "sha256": format!("{:x}", Sha256::digest(data))})
        })
        .collect();
    json!({"version": VERSION, "plugin": plugin, "hash": manifest_hash(plugin, files), "files": listed})
}

/// A new staging folder, removed on drop unless kept.
struct NewStage {
    path: Option<PathBuf>,
}

impl Drop for NewStage {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = fs::remove_dir_all(&path);
        }
    }
}

fn open_dir(path: &Path) -> io::Result<OwnedFd> {
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    Ok(rustix::fs::open(path, flags, Mode::empty())?)
}

fn write_new(dir: &OwnedFd, name: &str, data: &[u8]) -> io::Result<()> {
    let flags = OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let fd = rustix::fs::openat(dir, name, flags, Mode::from_raw_mode(0o600))?;
    rustix::fs::fchmod(&fd, Mode::from_raw_mode(0o600))?;
    let mut file = File::from(fd);
    file.write_all(data)?;
    file.sync_all()
}

fn is_stage_name(name: &str) -> bool {
    name.strip_prefix(STAGE_PREFIX).is_some_and(|rest| {
        rest.len() == 8
            && rest
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// Removes every older `stage-*` entry in `parent` (this user's private
/// folder, so they are all this user's).
fn remove_older(parent: &Path) -> Result<(), Failure> {
    let entries = fs::read_dir(parent).map_err(io_failure(parent.display()))?;
    for entry in entries {
        let entry = entry.map_err(io_failure(parent.display()))?;
        if !entry.file_name().to_str().is_some_and(is_stage_name) {
            continue;
        }
        let path = entry.path();
        let meta = fs::symlink_metadata(&path).map_err(io_failure(path.display()))?;
        let removed = if meta.is_dir() {
            fs::remove_dir_all(&path)
        } else {
            fs::remove_file(&path)
        };
        removed.map_err(io_failure(format!("cannot remove {}", path.display())))?;
    }
    Ok(())
}

/// The folder `folder` (`a/b`) under `top`, made 0700 with its parents on
/// first use. `made` holds the folders made so far, parents first. A name
/// that exists already (a file written before) is an error, so nothing here
/// is followed or reused.
fn sub_folder(top: &OwnedFd, made: &mut Vec<(String, OwnedFd)>, folder: &str) -> io::Result<usize> {
    let mut at = None;
    let mut prefix = String::new();
    for part in folder.split('/') {
        if !prefix.is_empty() {
            prefix.push('/');
        }
        prefix.push_str(part);
        if let Some(index) = made.iter().position(|(name, _)| *name == prefix) {
            at = Some(index);
            continue;
        }
        let parent = at.map_or(top, |index: usize| &made[index].1);
        rustix::fs::mkdirat(parent, part, Mode::from_raw_mode(0o700))?;
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        let fd = rustix::fs::openat(parent, part, flags, Mode::empty())?;
        rustix::fs::fchmod(&fd, Mode::from_raw_mode(0o700))?;
        made.push((prefix.clone(), fd));
        at = Some(made.len() - 1);
    }
    at.ok_or_else(|| io::Error::other("an empty folder name"))
}

/// Writes `files` (in order; a name may hold `/`) into a new
/// `stage-<random>` folder in `parent`; on any failure the folder is
/// removed.
fn write_stage(parent: &Path, files: &[(&str, &[u8])]) -> Result<PathBuf, Failure> {
    let parent_fd = open_dir(parent).map_err(io_failure(parent.display()))?;
    let mut created = None;
    for _ in 0..100 {
        let name = format!(
            "{STAGE_PREFIX}{}",
            random_suffix().map_err(io_failure("cannot pick a folder name"))?
        );
        match rustix::fs::mkdirat(&parent_fd, name.as_str(), Mode::from_raw_mode(0o700)) {
            Ok(()) => {
                created = Some(parent.join(name));
                break;
            }
            Err(Errno::EXIST) => continue,
            Err(error) => {
                return Err(io_failure("cannot create the staging folder")(error.into()));
            }
        }
    }
    let path = created.ok_or_else(|| Failure::coded("IO", "no free staging folder name"))?;
    let mut stage = NewStage {
        path: Some(path.clone()),
    };
    let written = (|| -> io::Result<()> {
        let dir = open_dir(&path)?;
        rustix::fs::fchmod(&dir, Mode::from_raw_mode(0o700))?;
        let mut made = Vec::new();
        for (name, data) in files {
            match name.rsplit_once('/') {
                None => write_new(&dir, name, data)?,
                Some((folder, file)) => {
                    let index = sub_folder(&dir, &mut made, folder)?;
                    write_new(&made[index].1, file, data)?;
                }
            }
        }
        // Children were made after their parents: sync them first.
        for (_, fd) in made.iter().rev() {
            rustix::fs::fsync(fd)?;
        }
        rustix::fs::fsync(&dir)?;
        rustix::fs::fsync(&parent_fd)?;
        Ok(())
    })();
    written.map_err(io_failure(format!("cannot write {}", path.display())))?;
    stage.path = None;
    Ok(path)
}

/// `$XDG_RUNTIME_DIR/foamy-lock/login-screen`, created 0700 and checked.
fn stage_parent(env: &Env) -> Result<PathBuf, Failure> {
    let runtime = env
        .runtime
        .clone()
        .filter(|runtime| runtime.is_dir())
        .ok_or_else(|| {
            Failure::coded(
                "NO_RUNTIME_DIR",
                "XDG_RUNTIME_DIR isn't an absolute path to a directory",
            )
        })?;
    let plugin = runtime.join("foamy-lock");
    let parent = plugin.join("login-screen");
    for dir in [&plugin, &parent] {
        foamy_helper::fs::ensure_private_dir(dir).map_err(io_failure(dir.display()))?;
    }
    Ok(parent)
}

pub fn run(env: &Env, plugin_dir: &Path, request: &[u8]) -> Result<Value, Failure> {
    stage(env, plugin_dir, request, LOCK_WAIT)
}

fn stage(env: &Env, plugin_dir: &Path, request: &[u8], wait: Duration) -> Result<Value, Failure> {
    let request = parse_request(request).map_err(invalid)?;
    let background = read_picture(env, Picture::Background, &request.background)?;
    if request.picture && background.is_none() {
        return Err(Failure::coded(
            "BACKGROUND_MISSING",
            "the look shows a picture, but the request has no background",
        ));
    }
    if !request.picture && background.is_some() {
        return Err(invalid("background must be null: showsPicture is false"));
    }
    let avatar = read_picture(env, Picture::Avatar, &request.avatar)?;
    let plugin = plugin_version(plugin_dir)?;
    let plugin_fd = open_plugin(plugin_dir)?;
    let bundle = read_bundle(&plugin_fd)?;
    let strings = read_strings(&plugin_fd, &request.language)?;

    let mut snapshot = request.settings;
    snapshot.insert("version".into(), json!(VERSION));
    snapshot.insert("user".into(), json!(login_name()?));
    snapshot.insert("look".into(), request.look);
    snapshot.insert("colors".into(), Value::Object(request.colors));
    snapshot.insert("lockThemed".into(), Value::Array(request.lock_themed));
    snapshot.insert("strings".into(), Value::Object(strings));
    let name = |data: &Option<Vec<u8>>, which: Picture| data.as_ref().map(|_| which.file_name());
    snapshot.insert(
        "files".into(),
        json!({"background": name(&background, Picture::Background),
               "avatar": name(&avatar, Picture::Avatar)}),
    );
    let snapshot = foamy_helper::json::to_line(&Value::Object(snapshot))
        .map_err(io_failure("cannot encode the snapshot"))?;
    if snapshot.len() > MAX_SNAPSHOT {
        return Err(invalid(format!(
            "the snapshot would be larger than {MAX_SNAPSHOT} bytes"
        )));
    }
    let mut files: Vec<(&str, &[u8])> = vec![("snapshot.json", snapshot.as_slice())];
    if let Some(data) = &background {
        files.push((Picture::Background.file_name(), data.as_slice()));
    }
    if let Some(data) = &avatar {
        files.push((Picture::Avatar.file_name(), data.as_slice()));
    }
    files.extend(
        bundle
            .iter()
            .map(|(place, data)| (place.as_str(), data.as_slice())),
    );
    let manifest = manifest(&plugin, &files);
    let manifest_line =
        foamy_helper::json::to_line(&manifest).map_err(io_failure("cannot encode the manifest"))?;
    let names: Vec<&str> = files.iter().map(|(name, _)| *name).collect();
    // The manifest goes last, so a folder with one has every file.
    files.push(("manifest.json", manifest_line.as_slice()));

    let parent = stage_parent(env)?;
    let lock_path = parent.join("stage.lock");
    // Held while the older folders go and the new one is written, so two
    // stages never remove each other's folder half-way.
    let _lock = FileLock::exclusive_within(&lock_path, wait)
        .map_err(io_failure(lock_path.display()))?
        .ok_or_else(|| Failure::coded("BUSY", "another login-screen stage is running"))?;
    remove_older(&parent)?;
    let dir = write_stage(&parent, &files)?;
    Ok(json!({"ok": true, "dir": dir, "hash": manifest["hash"], "files": names}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::os::unix::fs::{PermissionsExt, symlink};

    /// A PNG header of `width` x `height` (never decoded, so no pixels).
    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut data = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
        data.extend_from_slice(&width.to_be_bytes());
        data.extend_from_slice(&height.to_be_bytes());
        data.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
        data
    }

    fn colors() -> Value {
        let mut colors = Map::new();
        for (index, key) in COLOR_KEYS.iter().enumerate() {
            colors.insert((*key).into(), json!(format!("#10{index:02}AB")));
        }
        Value::Object(colors)
    }

    fn request(look: Value, shows_picture: bool) -> Value {
        json!({"look": look, "showsPicture": shows_picture, "timeFormat": "24h",
               "showUserInfo": true, "language": "nb", "formatLocale": "nb-NO",
               "rightToLeft": false, "colors": colors(),
               "lockThemed": ["lockText", "lockBorder"], "background": null, "avatar": null})
    }

    fn filtered(look: Value, shows_picture: bool) -> Value {
        filter_look(&look, shows_picture).unwrap()
    }

    struct Setup {
        scratch: Scratch,
        env: Env,
        plugin: PathBuf,
    }

    impl Setup {
        fn new(tag: &str) -> Setup {
            let scratch = Scratch::new(tag);
            let env = scratch.env();
            fs::create_dir_all(scratch.path("run")).unwrap();
            let plugin = scratch.plugin();
            scratch.file(
                "plugin/manifest.json",
                "{\"id\": \"foamy.lock\", \"version\": \"1.4.1\"}",
            );
            scratch.file("plugin/sddm/Main.qml", "Item {}\n");
            scratch.file("plugin/sddm/kit/FoamyStyle.qml", "QtObject {}\n");
            scratch.file("plugin/elements/shaders/aurora.frag.qsb", "qsb");
            scratch.file(
                "plugin/sddm/bundle.txt",
                "# The greeter\nsddm/Main.qml\nsddm/kit/FoamyStyle.qml\n\nelements/shaders/aurora.frag.qsb\nLayout.js\n",
            );
            Setup {
                scratch,
                env,
                plugin,
            }
        }

        fn lock_cache(&self) -> PathBuf {
            self.scratch.path("home/.cache/omarchy/foamy.lock")
        }

        fn background(&self, data: &[u8]) -> PathBuf {
            let path = self
                .lock_cache()
                .join(format!("background/{}.png", "ab".repeat(32)));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, data).unwrap();
            path
        }

        fn avatar(&self, data: &[u8]) -> PathBuf {
            let path = self.lock_cache().join("avatar.png");
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, data).unwrap();
            path
        }

        /// The default request's stage failure, with `bundle.txt` set to
        /// `list` (when given).
        fn bundle_failure(&self, list: Option<&str>) -> Failure {
            if let Some(list) = list {
                self.scratch.file("plugin/sddm/bundle.txt", list);
            }
            self.run(&request(json!({"preset": "zen"}), false))
                .unwrap_err()
        }

        fn run(&self, request: &Value) -> Result<Value, Failure> {
            run(
                &self.env,
                &self.plugin,
                &serde_json::to_vec(request).unwrap(),
            )
        }

        fn stages(&self) -> Vec<PathBuf> {
            let parent = self.scratch.path("run/foamy-lock/login-screen");
            let mut found: Vec<PathBuf> = fs::read_dir(parent)
                .map(|entries| {
                    entries
                        .flatten()
                        .map(|entry| entry.path())
                        .filter(|path| {
                            path.file_name()
                                .and_then(|name| name.to_str())
                                .is_some_and(|name| name.starts_with(STAGE_PREFIX))
                        })
                        .collect()
                })
                .unwrap_or_default();
            found.sort();
            found
        }
    }

    #[test]
    fn each_element_is_kept_hidden_or_changed() {
        // Values aren't checked here (Layout.js does), so any will do.
        let item = json!({"zone": "middle-center", "style": "thin", "scale": 1.15,
                          "offset": {"x": 0.1, "y": -0.2}, "screens": "primary"});
        let mut kept = item.clone();
        kept.as_object_mut().unwrap().remove("screens");
        for name in ELEMENTS {
            let expected = if GREETER_HIDDEN.contains(&name) {
                json!({"hidden": true})
            } else {
                kept.clone()
            };
            let look = filtered(json!({"preset": "zen", "layout": {name: item}}), false);
            assert_eq!(look["layout"][name], expected, "{name}");
        }
        // The left-out elements are hidden whatever the look says, an
        // element the look doesn't name stays the preset's, and the
        // user preset goes.
        let look = filtered(json!({"preset": "music", "userPreset": "mine"}), true);
        assert_eq!(
            look,
            json!({"preset": "music", "layout": {"media": {"hidden": true}, "status": {"hidden": true},
                   "weather": {"hidden": true}}, "background": {"source": "picture"}})
        );
    }

    #[test]
    fn the_background_is_kept_or_becomes_the_picture() {
        let full = json!({"source": "omarchy", "blur": 0.5, "dim": 0.3,
                          "path": "/home/me/Pictures/sea.mp4", "motion": "play",
                          "pauseOnBattery": false, "color": "#1a1b26",
                          "shapes": [{"kind": "frame"}]});
        let mut drawn = full.clone();
        drawn["source"] = json!("aurora");
        let mut drawn_kept = drawn.clone();
        drawn_kept.as_object_mut().unwrap().remove("path");
        for (background, shows_picture, expected) in [
            (
                Some(full.clone()),
                true,
                Some(json!({"source": "picture", "blur": 0.5, "dim": 0.3,
                            "shapes": [{"kind": "frame"}]})),
            ),
            (Some(drawn), false, Some(drawn_kept)),
            // Studio's answer decides, not the source.
            (
                Some(json!({"source": "rain", "dim": 0.4})),
                true,
                Some(json!({"source": "picture", "dim": 0.4})),
            ),
            (None, true, Some(json!({"source": "picture"}))),
            (None, false, None),
        ] {
            let mut look = json!({"preset": "zen"});
            if let Some(background) = &background {
                look["background"] = background.clone();
            }
            let look = filtered(look, shows_picture);
            assert_eq!(look.get("background"), expected.as_ref(), "{background:?}");
        }
        // The glass and preset stay as they are.
        let glass = json!({"opacity": 0.4, "tint": "accent"});
        let look = filtered(json!({"preset": "card", "glass": glass}), false);
        assert_eq!((&look["preset"], &look["glass"]), (&json!("card"), &glass));
    }

    #[test]
    fn bad_looks_are_refused_naming_the_field() {
        for (look, reason) in [
            (json!([]), "look: a look must be an object"),
            (json!({"id": 1}), "look: unknown look key id"),
            (
                json!({"background": []}),
                "look: background must be an object",
            ),
            (
                json!({"layout": {"clock2": {}}}),
                "look.layout has an unknown element: clock2",
            ),
            (
                json!({"layout": {"clock": []}}),
                "look.layout.clock must be an object",
            ),
            (
                json!({"layout": {"clock": {"style": "x".repeat(MAX_LOOK)}}}),
                "look is larger than",
            ),
            // A user path in a key nothing here knows about.
            (
                json!({"layout": {"clock": {"font": "/home/me/fonts/a.ttf"}}}),
                "look.layout.clock.font looks like a path",
            ),
            (
                json!({"layout": {"account": {"picture": "~/me.png"}}}),
                "look.layout.account.picture looks like a path",
            ),
            (
                json!({"background": {"shapes": [{"kind": "frame", "image": "file:a.png"}]}}),
                "look.background.shapes[0].image looks like a path",
            ),
            (
                json!({"glass": {"texture": "https://example.com/a.png"}}),
                "look.glass.texture looks like a path",
            ),
            (json!({"preset": "/zen"}), "look.preset looks like a path"),
            (
                json!({"layout": {"clock": {"/home/me": 1}}}),
                "look.layout.clock./home/me looks like a path",
            ),
        ] {
            let problem = filter_look(&look, false).map(|_| ()).unwrap_err();
            assert!(problem.starts_with(reason), "{look}: {problem}");
        }
        // Values are Layout.js's to check, and the paths that the filter
        // drops don't count.
        for (look, shows_picture) in [
            (
                json!({"preset": "nope", "glass": {"tint": "red", "x": 9}}),
                false,
            ),
            (
                json!({"layout": {"clock": {"scale": 99, "screens": "/a"}}}),
                false,
            ),
            (
                json!({"background": {"source": "color", "path": "/home/me/a.png"}}),
                false,
            ),
            (
                json!({"background": {"path": "/home/me/a.mp4", "motion": "/x", "color": "~"}}),
                true,
            ),
        ] {
            filter_look(&look, shows_picture).unwrap();
        }
    }
    #[test]
    fn bad_requests_are_refused_naming_the_field() {
        let mut unknown = colors();
        unknown["extra"] = json!("#000000");
        let mut missing = colors();
        missing.as_object_mut().unwrap().remove("info");
        let mut not_hex = colors();
        not_hex["accent"] = json!("red");
        let mut too_many = colors();
        for index in 0..14 {
            too_many[format!("x{index}")] = json!("#000000");
        }
        for (key, value, reason) in [
            ("timeFormat", json!("am"), "timeFormat must be"),
            ("timeFormat", json!(24), "timeFormat must be"),
            (
                "showUserInfo",
                json!("yes"),
                "showUserInfo must be true or false",
            ),
            (
                "rightToLeft",
                json!(null),
                "rightToLeft must be true or false",
            ),
            ("language", json!(""), "language must be"),
            ("language", json!("nb NO"), "language must be"),
            ("language", json!("a".repeat(36)), "language must be"),
            ("formatLocale", json!("nb/NO"), "formatLocale must be"),
            ("colors", json!([]), "colors must be an object"),
            ("colors", unknown, "colors has an unknown key: extra"),
            ("colors", too_many, "colors has more than 32 entries"),
            ("colors", missing, "colors.info is missing"),
            ("colors", not_hex, "colors.accent must be"),
            ("lockThemed", json!({}), "lockThemed must be an array"),
            (
                "lockThemed",
                json!(["accent"]),
                "lockThemed[0] must be one of",
            ),
            (
                "lockThemed",
                json!(["lockText", "lockText"]),
                "lockThemed names \"lockText\" twice",
            ),
            (
                "look",
                json!({"preset": 3}),
                "look: preset must be a string",
            ),
            (
                "showsPicture",
                json!("yes"),
                "showsPicture must be true or false",
            ),
        ] {
            let mut request = request(json!({"preset": "zen"}), false);
            request[key] = value;
            let problem = parse_request(&serde_json::to_vec(&request).unwrap())
                .map(|_| ())
                .unwrap_err();
            assert!(problem.starts_with(reason), "{key}: {problem}");
        }
        let parse = |request: &Value| {
            parse_request(&serde_json::to_vec(request).unwrap())
                .map(|_| ())
                .unwrap_err()
        };
        let mut extra = request(json!({}), false);
        extra["shell"] = json!({});
        assert_eq!(parse(&extra), "unknown key shell");
        let mut partial = request(json!({}), false);
        partial.as_object_mut().unwrap().remove("avatar");
        assert_eq!(parse(&partial), "avatar is missing");
        assert_eq!(parse(&json!([])), "expected a JSON object");
        assert!(parse_request(b"{nope").is_err());
        // Colours are stored in lower case, the themed keys in a fixed order.
        let parsed =
            parse_request(&serde_json::to_vec(&request(json!({"preset": "zen"}), false)).unwrap())
                .unwrap();
        assert_eq!(parsed.colors["background"], "#1000ab");
        assert_eq!(
            parsed.lock_themed,
            vec![json!("lockBorder"), json!("lockText")]
        );
    }

    #[test]
    fn pictures_must_be_small_pngs_of_this_users_in_the_lock_cache() {
        let setup = Setup::new("pictures");
        let good = setup.background(&png(1920, 1080));
        let avatar = setup.avatar(&png(256, 256));
        let outside = setup.scratch.path("elsewhere.png");
        fs::write(&outside, png(10, 10)).unwrap();
        let link = setup
            .lock_cache()
            .join(format!("background/{}.png", "cd".repeat(32)));
        symlink(&good, &link).unwrap();
        let unhashed = setup.lock_cache().join("background/sea.png");
        fs::write(&unhashed, png(10, 10)).unwrap();
        let dir = setup
            .lock_cache()
            .join(format!("background/{}.png", "ef".repeat(32)));
        fs::create_dir_all(&dir).unwrap();
        let dotted = format!(
            "{}/background/../background/{}.png",
            setup.lock_cache().display(),
            "ab".repeat(32)
        );
        let check = |key: &str, value: Value| {
            let mut request = request(json!({"preset": "foamy"}), true);
            request["background"] = json!(good);
            request[key] = value;
            setup.run(&request).unwrap_err()
        };
        for (key, value, reason) in [
            ("background", json!(outside), "background must be /"),
            ("background", json!(dotted), "background must be /"),
            ("background", json!(unhashed), "background must be /"),
            ("background", json!(avatar), "background must be /"),
            (
                "background",
                json!("relative.png"),
                "background must be null or an absolute path",
            ),
            (
                "background",
                json!(5),
                "background must be null or an absolute path",
            ),
            ("background", json!(link), "background is a symlink"),
            ("background", json!(dir), "background is not a regular file"),
            ("avatar", json!(good), "avatar must be /"),
            (
                "avatar",
                json!(setup.lock_cache().join("avatar2.png")),
                "avatar must be /",
            ),
        ] {
            let failure = check(key, value.clone());
            assert_eq!(failure.code, "INVALID_REQUEST", "{value}: {failure}");
            assert!(failure.message.starts_with(reason), "{value}: {failure}");
        }
        // Size, signature and IHDR.
        for (data, reason) in [
            (vec![0u8; 64], "avatar is not a PNG"),
            (
                b"\x89PNG\r\n\x1a\n\0\0\0\x0dIDAT\0\0\0\0\0\0\0\0".to_vec(),
                "avatar has no PNG IHDR",
            ),
            (png(3841, 100), "avatar is 3841 x 100"),
            (png(100, 2161), "avatar is 100 x 2161"),
            (png(0, 10), "avatar is 0 x 10"),
            (vec![0u8; MAX_PICTURE as usize + 1], "avatar is larger than"),
        ] {
            setup.avatar(&data);
            let failure = check("avatar", json!(avatar));
            assert_eq!(failure.code, "INVALID_REQUEST", "{reason}");
            assert!(failure.message.starts_with(reason), "{failure}");
        }
        fs::remove_file(&avatar).unwrap();
        assert!(
            check("avatar", json!(avatar))
                .message
                .starts_with("avatar doesn't exist")
        );
        assert!(setup.stages().is_empty());
        // The largest picture allowed passes.
        setup.avatar(&png(MAX_WIDTH, MAX_HEIGHT));
        let mut request = request(json!({"preset": "foamy"}), true);
        request["background"] = json!(good);
        request["avatar"] = json!(avatar);
        setup.run(&request).unwrap();
        assert_eq!(setup.stages().len(), 1);
        // The largest background the helper itself writes passes: an
        // uncompressed RGB PNG at the size limit.
        let largest = crate::image::encode_rgb(
            MAX_WIDTH as usize,
            MAX_HEIGHT as usize,
            &vec![0; MAX_WIDTH as usize * MAX_HEIGHT as usize * 3],
        )
        .unwrap();
        assert_eq!(largest.len(), 24_887_323);
        setup.background(&largest);
        setup.run(&request).unwrap();
        setup.background(&png(1920, 1080));
        // A background for a look that shows none is refused.
        request["showsPicture"] = json!(false);
        let failure = setup.run(&request).unwrap_err();
        assert_eq!(failure.code, "INVALID_REQUEST");
        assert!(
            failure.message.starts_with("background must be null"),
            "{failure}"
        );
    }

    #[test]
    fn a_picture_look_without_a_background_fails() {
        let setup = Setup::new("missing");
        for look in [
            json!({}),
            json!({"preset": "zen"}),
            json!({"background": {"source": "picture", "path": "/home/me/a.png"}}),
        ] {
            let failure = setup.run(&request(look.clone(), true)).unwrap_err();
            assert_eq!(failure.code, "BACKGROUND_MISSING", "{look}");
        }
        assert!(setup.stages().is_empty());
    }

    #[test]
    fn a_stage_is_deterministic_private_and_the_only_one() {
        let setup = Setup::new("stage");
        let background = setup.background(&png(1920, 1080));
        let avatar = setup.avatar(&png(256, 256));
        let home = setup.scratch.path("home");
        let mut request = request(
            json!({
            "preset": "foamy", "userPreset": "mine",
            "background": {"source": "omarchy", "blur": 0.2,
                           "path": format!("{}/Pictures/sea.png", home.display())},
            "layout": {"clock": {"screens": "primary", "scale": 1.5}, "media": {"zone": "top-start"}}}),
            true,
        );
        request["background"] = json!(background);
        request["avatar"] = json!(avatar);
        let first = setup.run(&request).unwrap();
        let first_dir = PathBuf::from(first["dir"].as_str().unwrap());
        assert_eq!(first["ok"], true);
        assert_eq!(
            first["files"],
            json!([
                "snapshot.json",
                "background.png",
                "avatar.png",
                "Layout.js",
                "Main.qml",
                "elements/shaders/aurora.frag.qsb",
                "kit/FoamyStyle.qml"
            ])
        );
        assert_eq!(setup.stages(), vec![first_dir.clone()]);
        let mode = |path: &Path| fs::symlink_metadata(path).unwrap().permissions().mode() & 0o7777;
        assert_eq!(mode(&first_dir), 0o700);
        for name in [
            "snapshot.json",
            "background.png",
            "avatar.png",
            "manifest.json",
            "Layout.js",
            "Main.qml",
            "kit/FoamyStyle.qml",
            "elements/shaders/aurora.frag.qsb",
        ] {
            assert_eq!(mode(&first_dir.join(name)), 0o600, "{name}");
        }
        for folder in ["kit", "elements", "elements/shaders"] {
            assert_eq!(mode(&first_dir.join(folder)), 0o700, "{folder}");
        }
        assert_eq!(
            fs::read_to_string(first_dir.join("kit/FoamyStyle.qml")).unwrap(),
            "QtObject {}\n"
        );
        // Nothing else: the list itself and unlisted plugin files stay out.
        let mut top: Vec<String> = fs::read_dir(&first_dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        top.sort();
        assert_eq!(
            top,
            [
                "Layout.js",
                "Main.qml",
                "avatar.png",
                "background.png",
                "elements",
                "kit",
                "manifest.json",
                "snapshot.json"
            ]
        );
        assert_eq!(
            fs::read(first_dir.join("background.png")).unwrap(),
            png(1920, 1080)
        );
        assert_eq!(
            fs::read(first_dir.join("avatar.png")).unwrap(),
            png(256, 256)
        );
        let snapshot_bytes = fs::read(first_dir.join("snapshot.json")).unwrap();
        let snapshot: Value = serde_json::from_slice(&snapshot_bytes).unwrap();
        assert_eq!(snapshot["version"], 1);
        assert_eq!(snapshot["user"], login_name().unwrap());
        assert_eq!(
            snapshot["files"],
            json!({"background": "background.png", "avatar": "avatar.png"})
        );
        assert_eq!(
            snapshot["look"],
            json!({"preset": "foamy", "background": {"source": "picture", "blur": 0.2},
                   "layout": {"clock": {"scale": 1.5}, "media": {"hidden": true},
                              "status": {"hidden": true}, "weather": {"hidden": true}}})
        );
        assert_eq!(snapshot["lockThemed"], json!(["lockBorder", "lockText"]));
        assert_eq!(
            (
                &snapshot["timeFormat"],
                &snapshot["formatLocale"],
                &snapshot["rightToLeft"]
            ),
            (&json!("24h"), &json!("nb-NO"), &json!(false))
        );
        // No path from the user's files anywhere.
        let text = String::from_utf8(snapshot_bytes.clone()).unwrap();
        assert!(!text.contains(home.to_str().unwrap()), "{text}");
        assert!(
            !text.contains("/home/") && !text.contains("Pictures"),
            "{text}"
        );
        assert!(text.ends_with("}\n") && text.matches('\n').count() == 1);
        let manifest: Value =
            serde_json::from_slice(&fs::read(first_dir.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest["version"], 1);
        assert_eq!(manifest["plugin"], "1.4.1");
        assert_eq!(manifest["hash"], first["hash"]);
        assert_eq!(manifest["files"][0]["name"], "snapshot.json");
        assert_eq!(manifest["files"][0]["size"], snapshot_bytes.len());
        assert_eq!(manifest["files"][1]["name"], "background.png");
        assert_eq!(
            manifest["files"][1]["sha256"],
            format!("{:x}", Sha256::digest(png(1920, 1080)))
        );
        assert_eq!(manifest["files"][2]["name"], "avatar.png");
        let names: Vec<&Value> = manifest["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|file| &file["name"])
            .collect();
        assert_eq!(json!(names), first["files"]);
        assert_eq!(manifest["files"][6]["size"], 12);
        assert_eq!(
            manifest["files"][6]["sha256"],
            format!("{:x}", Sha256::digest(b"QtObject {}\n"))
        );
        // The hash covers every listed file in the manifest's order.
        let listed: Vec<(String, Vec<u8>)> = manifest["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|file| {
                let name = file["name"].as_str().unwrap().to_string();
                let data = fs::read(first_dir.join(&name)).unwrap();
                (name, data)
            })
            .collect();
        let borrowed: Vec<(&str, &[u8])> = listed
            .iter()
            .map(|(name, data)| (name.as_str(), data.as_slice()))
            .collect();
        assert_eq!(manifest["hash"], manifest_hash("1.4.1", &borrowed));
        assert_eq!(snapshot["strings"], json!({}));
        // Again: a new folder with the same bytes and hash; the older one goes.
        let second = setup.run(&request).unwrap();
        let second_dir = PathBuf::from(second["dir"].as_str().unwrap());
        assert_ne!(first_dir, second_dir);
        assert_eq!(setup.stages(), vec![second_dir.clone()]);
        assert_eq!(second["hash"], first["hash"]);
        assert_eq!(
            fs::read(second_dir.join("snapshot.json")).unwrap(),
            snapshot_bytes
        );
        // A changed bundle file hashes differently; the same bytes again
        // give the first hash.
        setup
            .scratch
            .file("plugin/sddm/kit/FoamyStyle.qml", "QtObject { }\n");
        let changed = setup.run(&request).unwrap();
        assert_ne!(changed["hash"], first["hash"]);
        setup
            .scratch
            .file("plugin/sddm/kit/FoamyStyle.qml", "QtObject {}\n");
        assert_eq!(setup.run(&request).unwrap()["hash"], first["hash"]);
        // The list's order and comments don't matter.
        setup.scratch.file(
            "plugin/sddm/bundle.txt",
            "Layout.js\n  elements/shaders/aurora.frag.qsb  \n# x\nsddm/kit/FoamyStyle.qml\r\nsddm/Main.qml",
        );
        assert_eq!(setup.run(&request).unwrap()["hash"], first["hash"]);
        // Another plugin version or another setting hashes differently.
        setup
            .scratch
            .file("plugin/manifest.json", "{\"version\": \"1.5.0\"}");
        let newer = setup.run(&request).unwrap();
        assert_ne!(newer["hash"], first["hash"]);
        request["timeFormat"] = json!("12h");
        assert_ne!(setup.run(&request).unwrap()["hash"], newer["hash"]);
        // Other entries next to the folders are left alone.
        let other = setup
            .scratch
            .file("run/foamy-lock/login-screen/notes", "keep");
        setup.run(&request).unwrap();
        assert_eq!(fs::read_to_string(other).unwrap(), "keep");
        assert_eq!(setup.stages().len(), 1);
    }

    #[test]
    fn the_hash_follows_the_plugin_and_every_file() {
        let base = manifest_hash("1.4.1", &[("snapshot.json", b"{}"), ("avatar.png", b"a")]);
        assert_eq!(base.len(), 64);
        assert!(base.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')));
        for other in [
            manifest_hash("1.4.2", &[("snapshot.json", b"{}"), ("avatar.png", b"a")]),
            manifest_hash("1.4.1", &[("snapshot.json", b"{ }"), ("avatar.png", b"a")]),
            manifest_hash("1.4.1", &[("snapshot.json", b"{}"), ("avatar.png", b"b")]),
            manifest_hash(
                "1.4.1",
                &[("snapshot.json", b"{}"), ("background.png", b"a")],
            ),
            manifest_hash("1.4.1", &[("snapshot.json", b"{}")]),
        ] {
            assert_ne!(other, base);
        }
    }

    #[test]
    fn a_failure_while_writing_removes_the_new_folder() {
        let setup = Setup::new("halfway");
        let parent = stage_parent(&setup.env).unwrap();
        // The second write fails: O_EXCL on a name already written.
        let failure = write_stage(
            &parent,
            &[("snapshot.json", b"{}"), ("snapshot.json", b"{}")],
        )
        .unwrap_err();
        assert_eq!(failure.code, "IO");
        assert!(setup.stages().is_empty());
        // A folder where a file was written.
        let failure = write_stage(&parent, &[("a", b"1"), ("a/b", b"2")]).unwrap_err();
        assert_eq!(failure.code, "IO");
        assert!(setup.stages().is_empty());
        // A file where a folder was made.
        let failure = write_stage(&parent, &[("a/b", b"1"), ("a", b"2")]).unwrap_err();
        assert_eq!(failure.code, "IO");
        assert!(setup.stages().is_empty());
        let dir = write_stage(&parent, &[("a", b"1"), ("b/c/d", b"2"), ("b/e", b"3")]).unwrap();
        assert_eq!(setup.stages(), vec![dir.clone()]);
        assert_eq!(fs::read(dir.join("b/c/d")).unwrap(), b"2");
        assert_eq!(fs::read(dir.join("b/e")).unwrap(), b"3");
    }

    #[test]
    fn the_runtime_dir_plugin_version_and_lock_are_checked() {
        let setup = Setup::new("runtime");
        let look = serde_json::to_vec(&request(json!({"preset": "zen"}), false)).unwrap();
        let mut env = setup.env.clone();
        env.runtime = None;
        assert_eq!(
            run(&env, &setup.plugin, &look).unwrap_err().code,
            "NO_RUNTIME_DIR"
        );
        env.runtime = Some(setup.scratch.path("no-such-run"));
        assert_eq!(
            run(&env, &setup.plugin, &look).unwrap_err().code,
            "NO_RUNTIME_DIR"
        );
        assert!(!setup.scratch.path("no-such-run").exists());
        // A plugin runtime folder others can enter.
        let shared = setup.scratch.path("run/foamy-lock");
        fs::create_dir_all(&shared).unwrap();
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            run(&setup.env, &setup.plugin, &look).unwrap_err().code,
            "IO"
        );
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o700)).unwrap();
        // The plugin's version.
        for text in ["{}", "{\"version\": \"1 2\"}", "[]", "nope"] {
            setup.scratch.file("plugin/manifest.json", text);
            assert_eq!(
                run(&setup.env, &setup.plugin, &look).unwrap_err().code,
                "PLUGIN_NOT_FOUND",
                "{text}"
            );
        }
        fs::remove_file(setup.plugin.join("manifest.json")).unwrap();
        assert_eq!(
            run(&setup.env, &setup.plugin, &look).unwrap_err().code,
            "PLUGIN_NOT_FOUND"
        );
        setup
            .scratch
            .file("plugin/manifest.json", "{\"version\": \"2.0.0-rc.1\"}");
        // Another stage holds the lock.
        let parent = stage_parent(&setup.env).unwrap();
        let held = FileLock::try_exclusive(&parent.join("stage.lock"))
            .unwrap()
            .unwrap();
        assert_eq!(
            stage(&setup.env, &setup.plugin, &look, Duration::ZERO)
                .unwrap_err()
                .code,
            "BUSY"
        );
        assert!(setup.stages().is_empty());
        drop(held);
        let reply = stage(&setup.env, &setup.plugin, &look, Duration::ZERO).unwrap();
        assert_eq!(reply["files"][0], json!("snapshot.json"));
        assert_eq!(reply["files"].as_array().unwrap().len(), 5);
    }

    #[test]
    fn bundle_lists_are_parsed() {
        let entries = parse_bundle(
            b"# The greeter\n\n  sddm/Main.qml  \n\t# indented comment\nsddm/kit/FoamyStyle.qml\r\nLayout.js\nelements/shaders/aurora.frag.qsb\nsddm\nkit-x.qml",
        )
        .unwrap();
        let pairs: Vec<(&str, &str)> = entries
            .iter()
            .map(|entry| (entry.source.as_str(), entry.place.as_str()))
            .collect();
        assert_eq!(
            pairs,
            [
                ("Layout.js", "Layout.js"),
                ("sddm/Main.qml", "Main.qml"),
                (
                    "elements/shaders/aurora.frag.qsb",
                    "elements/shaders/aurora.frag.qsb"
                ),
                ("kit-x.qml", "kit-x.qml"),
                ("sddm/kit/FoamyStyle.qml", "kit/FoamyStyle.qml"),
                // Only a leading `sddm/` is dropped.
                ("sddm", "sddm"),
            ]
        );
        assert_eq!(parse_bundle(b"").unwrap(), []);
        assert_eq!(parse_bundle(b"# nothing\n\n").unwrap(), []);
        let many = |count: usize| {
            (0..count)
                .map(|index| format!("f{index}.qml\n"))
                .collect::<String>()
        };
        assert_eq!(
            parse_bundle(many(MAX_BUNDLE_ENTRIES).as_bytes())
                .unwrap()
                .len(),
            MAX_BUNDLE_ENTRIES
        );
        for (text, reason) in [
            (
                "/etc/passwd".to_string(),
                "line 1: \"/etc/passwd\" isn't a relative path",
            ),
            ("../x.qml".into(), "line 1: \"../x.qml\" isn't"),
            ("a/./x.qml".into(), "line 1: \"a/./x.qml\" isn't"),
            ("#\nsddm/.hidden".into(), "line 2: \"sddm/.hidden\" isn't"),
            ("a//b".into(), "line 1: \"a//b\" isn't"),
            ("kit/".into(), "line 1: \"kit/\" isn't"),
            ("a b.qml".into(), "line 1: \"a b.qml\" isn't"),
            ("a\\b.qml".into(), "line 1: \"a\\\\b.qml\" isn't"),
            (
                "a/b/c/d/e.qml".into(),
                "line 1: \"a/b/c/d/e.qml\" has more than 4 levels",
            ),
            (
                "Main.qml\nsddm/Main.qml".into(),
                "line 2: sddm/Main.qml has the same place as line 1: Main.qml",
            ),
            (
                "Main.qml\n\nMain.qml".into(),
                "line 3: Main.qml has the same place as line 1",
            ),
            (
                "sddm/theme.conf".into(),
                "line 1: sddm/theme.conf would replace theme.conf",
            ),
            (
                "snapshot.json".into(),
                "line 1: snapshot.json would replace snapshot.json",
            ),
            (
                "sddm/manifest.json".into(),
                "line 1: sddm/manifest.json would replace",
            ),
            (
                "sddm/background.png".into(),
                "line 1: sddm/background.png would replace",
            ),
            ("avatar.png".into(), "line 1: avatar.png would replace"),
            (
                "kit\nsddm/kit/FoamyStyle.qml".into(),
                "line 2: sddm/kit/FoamyStyle.qml needs a folder kit, but line 1 lists it as a file",
            ),
            (
                "a/b/c.qml\nsddm/a/b".into(),
                "line 1: a/b/c.qml needs a folder a/b, but line 2 lists it",
            ),
            (
                "sddm/theme.conf/x".into(),
                "line 1: sddm/theme.conf/x needs a folder theme.conf, but stage writes it",
            ),
            (
                many(MAX_BUNDLE_ENTRIES + 1),
                "line 201: more than 200 paths",
            ),
        ] {
            let problem = parse_bundle(text.as_bytes()).unwrap_err();
            let expected = format!("sddm/bundle.txt {reason}");
            assert!(problem.starts_with(&expected), "{text:?}: {problem}");
        }
        assert_eq!(
            parse_bundle(b"Main.qml\n\xff\n").unwrap_err(),
            "sddm/bundle.txt isn't UTF-8"
        );
    }

    #[test]
    fn bundle_files_are_read_without_symlinks_and_within_bounds() {
        let setup = Setup::new("bundle");
        let plugin = |rel: &str| setup.plugin.join(rel);
        let outside = setup.scratch.file("outside/Secret.qml", "secret\n");
        // (bundle.txt, a change to the plugin, part of the message)
        type Change<'a> = Box<dyn Fn() + 'a>;
        let cases: Vec<(&str, Change, &str)> = vec![
            (
                "sddm/Missing.qml\n",
                Box::new(|| {}),
                "sddm/Missing.qml is missing",
            ),
            (
                "nope/Main.qml\n",
                Box::new(|| {}),
                "nope/Main.qml is missing",
            ),
            (
                "sddm/Link.qml\n",
                Box::new(|| symlink(&outside, plugin("sddm/Link.qml")).unwrap()),
                "sddm/Link.qml: is a symlink",
            ),
            (
                "linked/Secret.qml\n",
                Box::new(|| symlink(outside.parent().unwrap(), plugin("linked")).unwrap()),
                "linked/Secret.qml: linked is a symlink",
            ),
            (
                "sddm/deep/Secret.qml\n",
                Box::new(|| symlink(outside.parent().unwrap(), plugin("sddm/deep")).unwrap()),
                "sddm/deep/Secret.qml: deep is a symlink",
            ),
            (
                "Layout.js/x.qml\n",
                Box::new(|| {}),
                "Layout.js/x.qml: Layout.js isn't a folder",
            ),
            (
                "elements\n",
                Box::new(|| {}),
                "elements: isn't a regular file",
            ),
            (
                "sddm/Big.qml\n",
                Box::new(|| {
                    fs::write(
                        plugin("sddm/Big.qml"),
                        vec![b' '; MAX_BUNDLE_FILE as usize + 1],
                    )
                    .unwrap();
                }),
                "sddm/Big.qml: is larger than 2097152 bytes",
            ),
        ];
        for (list, change, reason) in cases {
            change();
            let failure = setup.bundle_failure(Some(list));
            assert_eq!(failure.code, "BUNDLE_INVALID", "{list}: {failure}");
            assert!(failure.message.starts_with(reason), "{list}: {failure}");
        }
        // Exactly the file bound passes.
        fs::write(plugin("sddm/Big.qml"), vec![b' '; MAX_BUNDLE_FILE as usize]).unwrap();
        setup
            .scratch
            .file("plugin/sddm/bundle.txt", "sddm/Big.qml\n");
        assert!(setup.stages().is_empty());
        setup
            .run(&request(json!({"preset": "zen"}), false))
            .unwrap();
        // A failure later leaves the stage that worked alone.
        let kept = setup.stages();
        // Too much together.
        let count = (MAX_BUNDLE_TOTAL / MAX_BUNDLE_FILE) as usize + 1;
        let mut list = String::new();
        for index in 0..count {
            fs::write(
                plugin(&format!("sddm/Big{index}.qml")),
                vec![b' '; MAX_BUNDLE_FILE as usize],
            )
            .unwrap();
            list += &format!("sddm/Big{index}.qml\n");
        }
        let failure = setup.bundle_failure(Some(&list));
        assert_eq!(failure.code, "BUNDLE_INVALID");
        assert!(
            failure
                .message
                .contains("larger than 33554432 bytes together"),
            "{failure}"
        );
        // The list itself: too large, a symlink, missing, not a file, bad.
        for (change, reason) in [
            (
                Box::new(|| {
                    setup.scratch.file(
                        "plugin/sddm/bundle.txt",
                        &"#".repeat(MAX_BUNDLE_LIST as usize + 1),
                    );
                }) as Change,
                "sddm/bundle.txt: is larger than 65536 bytes",
            ),
            (
                Box::new(|| {
                    let list = plugin("sddm/bundle.txt");
                    fs::remove_file(&list).unwrap();
                    let target = setup.scratch.file("outside/bundle.txt", "Layout.js\n");
                    symlink(target, list).unwrap();
                }),
                "sddm/bundle.txt: is a symlink",
            ),
            (
                Box::new(|| fs::remove_file(plugin("sddm/bundle.txt")).unwrap()),
                "sddm/bundle.txt is missing",
            ),
            (
                Box::new(|| fs::create_dir(plugin("sddm/bundle.txt")).unwrap()),
                "sddm/bundle.txt: isn't a regular file",
            ),
            (
                Box::new(|| {
                    fs::remove_dir(plugin("sddm/bundle.txt")).unwrap();
                    setup
                        .scratch
                        .file("plugin/sddm/bundle.txt", "Main.qml\n../x\n");
                }),
                "sddm/bundle.txt line 2:",
            ),
            (
                Box::new(|| {
                    fs::remove_file(plugin("sddm/bundle.txt")).unwrap();
                    let sddm = plugin("sddm");
                    fs::rename(&sddm, setup.scratch.path("real-sddm")).unwrap();
                    symlink(setup.scratch.path("real-sddm"), sddm).unwrap();
                    setup.scratch.file("real-sddm/bundle.txt", "Layout.js\n");
                }),
                "sddm/bundle.txt: sddm is a symlink",
            ),
        ] {
            change();
            let failure = setup.bundle_failure(None);
            assert_eq!(failure.code, "BUNDLE_INVALID", "{failure}");
            assert!(failure.message.starts_with(reason), "{failure}");
        }
        assert_eq!(setup.stages(), kept);
    }

    #[test]
    fn strings_follow_the_language() {
        let setup = Setup::new("strings");
        let catalog = |rel: &str, text: &str| {
            setup.scratch.file(&format!("plugin/i18n/{rel}"), text);
        };
        catalog("en.json", r#"{"lock.password": "Password"}"#);
        catalog(
            "nb.json",
            r#"{"lock.password": "Passord", "lock.tries": {"one": "%1 forsøk", "other": "%1 forsøk"}}"#,
        );
        catalog("nb-NO.json", r#"{"lock.password": "Passord (NO)"}"#);
        let strings = |language: &str| {
            let mut request = request(json!({"preset": "zen"}), false);
            request["language"] = json!(language);
            let reply = setup.run(&request)?;
            let dir = PathBuf::from(reply["dir"].as_str().unwrap());
            let snapshot: Value =
                serde_json::from_slice(&fs::read(dir.join("snapshot.json")).unwrap()).unwrap();
            Ok::<Value, Failure>(snapshot["strings"].clone())
        };
        for (language, expected) in [
            ("nb-NO", json!({"lock.password": "Passord (NO)"})),
            (
                "nb",
                json!({"lock.password": "Passord", "lock.tries": {"one": "%1 forsøk", "other": "%1 forsøk"}}),
            ),
            // The base language before the first dash.
            (
                "nb-SJ",
                json!({"lock.password": "Passord", "lock.tries": {"one": "%1 forsøk", "other": "%1 forsøk"}}),
            ),
            ("en-GB-x", json!({"lock.password": "Password"})),
            // Not the part before an underscore, and no catalog is {}.
            ("nb_NO", json!({})),
            ("da", json!({})),
            ("da-DK", json!({})),
        ] {
            assert_eq!(strings(language).unwrap(), expected, "{language}");
        }
        for (text, reason) in [
            ("[]", "i18n/da.json isn't a JSON object"),
            ("nope", "i18n/da.json isn't a JSON object"),
            (
                r#"{"a": 1}"#,
                "i18n/da.json: \"a\" must be a string or an object of strings",
            ),
            (r#"{"a": null}"#, "i18n/da.json: \"a\" must be"),
            (r#"{"a": ["x"]}"#, "i18n/da.json: \"a\" must be"),
            (
                r#"{"a": {"one": "x", "other": 2}}"#,
                "i18n/da.json: \"a\" must be",
            ),
            (
                r#"{"a": {"one": {"x": "y"}}}"#,
                "i18n/da.json: \"a\" must be",
            ),
        ] {
            catalog("da.json", text);
            let failure = strings("da-DK").unwrap_err();
            assert_eq!(failure.code, "BUNDLE_INVALID", "{text}");
            assert!(failure.message.starts_with(reason), "{text}: {failure}");
        }
        // A catalog too large, or a symlink, is a broken plugin too.
        catalog(
            "da.json",
            &format!("{{\"a\": \"{}\"}}", "x".repeat(MAX_CATALOG as usize)),
        );
        let failure = strings("da").unwrap_err();
        assert_eq!(failure.code, "BUNDLE_INVALID");
        assert!(
            failure
                .message
                .starts_with("i18n/da.json: is larger than 131072"),
            "{failure}"
        );
        fs::remove_file(setup.plugin.join("i18n/da.json")).unwrap();
        symlink(
            setup.plugin.join("i18n/en.json"),
            setup.plugin.join("i18n/da.json"),
        )
        .unwrap();
        let failure = strings("da").unwrap_err();
        assert_eq!(
            (failure.code.as_str(), failure.message.as_str()),
            ("BUNDLE_INVALID", "i18n/da.json: is a symlink")
        );
        // The plugin's own catalogs have that shape and fit.
        let real = Path::new(env!("CARGO_MANIFEST_DIR")).join("../i18n");
        for entry in fs::read_dir(real).unwrap() {
            let path = entry.unwrap().path();
            let bytes = fs::read(&path).unwrap();
            assert!(bytes.len() as u64 <= MAX_CATALOG, "{}", path.display());
            parse_catalog("x", &bytes).unwrap_or_else(|why| panic!("{}: {why}", path.display()));
        }
    }

    #[test]
    fn the_elements_match_layout_js() {
        let source =
            fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../Layout.js")).unwrap();
        let start = source
            .find("var ELEMENTS = [")
            .expect("Layout.js has no ELEMENTS");
        let rest = &source[start..];
        let list = &rest[rest.find('[').unwrap() + 1..rest.find(']').unwrap()];
        let names: Vec<&str> = list.split('"').skip(1).step_by(2).collect();
        assert_eq!(names, ELEMENTS);
    }
}
