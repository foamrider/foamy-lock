//! `studio draft-save` / `draft-load` / `draft-clear`: the look being
//! edited, kept on disk so a crash or closing the window loses nothing.
//!
//! The file is `$XDG_STATE_HOME/foamy-lock/studio-draft.json` (directory
//! created 0700; file 0600, written atomically), one JSON line:
//! `{"version": 1, "savedAt": "<ISO 8601 UTC>", "look": <look>, "history":
//! [<look>, …]}`. A look is an object with only `preset` (string),
//! `layout`, `background` and `glass` (objects), each one at most 64 KiB as
//! compact JSON; the lock checks the rest when it's applied. `history` is
//! the undo history, oldest first, at most 100 looks.
//!
//! - **draft-save**: stdin (at most 2 MiB) `{"look": <look>, "history":
//!   [<look>, …]}` (`history` optional). A longer history keeps its newest
//!   (last) 100. `savedAt` is set here. Reply `{"ok": true, "path": …,
//!   "savedAt": …, "history": <count>, "trimmed": <dropped>}`. A bad
//!   request is `INVALID_REQUEST` (exit 1) and leaves the file alone.
//! - **draft-load**: no stdin. `{"ok": true, "status": "loaded", "draft":
//!   {"look": …, "history": […], "savedAt": …}}`, or `{"ok": true,
//!   "status": "none", "draft": null}`, or, when the file isn't a draft
//!   (not JSON, the wrong shape, too large, not a regular file),
//!   `{"ok": true, "status": "corrupt", "draft": null, "reason": …,
//!   "movedTo": "<…/studio-draft.corrupt.json>"}`: the file is moved
//!   there (replacing an older one), so the next load is `none`.
//! - **draft-clear**: `{"ok": true, "removed": true | false}`.

use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use foamy_helper::Failure;
use serde_json::{Map, Value, json};

use super::{Env, check_look, io_failure, iso8601};

pub const MAX_REQUEST: u64 = 2 * 1024 * 1024;
const MAX_FILE: u64 = MAX_REQUEST + 4096;
pub const MAX_HISTORY: usize = 100;
pub const MAX_LOOK: usize = 64 * 1024;
const VERSION: u64 = 1;

fn draft_file(env: &Env) -> Result<PathBuf, Failure> {
    Ok(env.lock_state()?.join("studio-draft.json"))
}

fn checked_look(look: &Value, what: &str) -> Result<(), String> {
    check_look(look).map_err(|reason| format!("{what}: {reason}"))?;
    let size = serde_json::to_vec(look)
        .map(|bytes| bytes.len())
        .unwrap_or(usize::MAX);
    if size > MAX_LOOK {
        return Err(format!("{what} is larger than {MAX_LOOK} bytes"));
    }
    Ok(())
}

fn checked_history(history: Option<&Value>) -> Result<Vec<Value>, String> {
    let items = match history {
        None => return Ok(Vec::new()),
        Some(Value::Array(items)) => items,
        Some(_) => return Err("history must be an array".into()),
    };
    for (index, look) in items.iter().enumerate() {
        checked_look(look, &format!("history[{index}]"))?;
    }
    Ok(items.clone())
}

/// The draft in a `draft-save` request: (look, history, dropped entries).
pub fn parse_request(bytes: &[u8]) -> Result<(Value, Vec<Value>, usize), String> {
    let Ok(Value::Object(request)) = serde_json::from_slice::<Value>(bytes) else {
        return Err("expected a JSON object".into());
    };
    if let Some(key) = request
        .keys()
        .find(|key| *key != "look" && *key != "history")
    {
        return Err(format!("unknown key {key}"));
    }
    let look = request.get("look").ok_or("look is missing")?;
    checked_look(look, "look")?;
    let mut history = checked_history(request.get("history"))?;
    let dropped = history.len().saturating_sub(MAX_HISTORY);
    history.drain(..dropped);
    Ok((look.clone(), history, dropped))
}

/// A stored draft, checked: the object `draft-load` replies with.
pub fn parse_stored(bytes: &[u8]) -> Result<Value, String> {
    let request: Map<String, Value> = match serde_json::from_slice(bytes) {
        Ok(Value::Object(object)) => object,
        Ok(_) => return Err("not a JSON object".into()),
        Err(error) => return Err(format!("not JSON: {error}")),
    };
    if request.get("version").and_then(Value::as_u64) != Some(VERSION) {
        return Err("unknown version".into());
    }
    let look = request.get("look").ok_or("look is missing")?;
    checked_look(look, "look")?;
    let history = checked_history(request.get("history"))?;
    if history.len() > MAX_HISTORY {
        return Err(format!("history has more than {MAX_HISTORY} entries"));
    }
    let saved_at = request
        .get("savedAt")
        .and_then(Value::as_str)
        .ok_or("savedAt is missing")?;
    Ok(json!({"look": look, "history": history, "savedAt": saved_at}))
}

/// `studio draft-save`.
pub fn save(env: &Env, request: &[u8]) -> Result<Value, Failure> {
    save_at(env, request, SystemTime::now())
}

fn save_at(env: &Env, request: &[u8], now: SystemTime) -> Result<Value, Failure> {
    let (look, history, dropped) =
        parse_request(request).map_err(|reason| Failure::coded("INVALID_REQUEST", reason))?;
    let path = draft_file(env)?;
    let dir = path.parent().unwrap_or(&path);
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(io_failure(dir.display()))?;
    let saved_at = iso8601(now);
    let count = history.len();
    let stored = json!({"version": VERSION, "savedAt": saved_at, "look": look, "history": history});
    let line =
        foamy_helper::json::to_line(&stored).map_err(io_failure("cannot encode the draft"))?;
    foamy_helper::fs::write_atomic(&path, &line, 0o600)
        .map_err(io_failure("cannot save the draft"))?;
    Ok(json!({"ok": true, "path": path, "savedAt": saved_at, "history": count, "trimmed": dropped}))
}

fn corrupt_file(path: &Path) -> PathBuf {
    path.with_file_name("studio-draft.corrupt.json")
}

/// `studio draft-load`.
pub fn load(env: &Env) -> Result<Value, Failure> {
    let path = draft_file(env)?;
    let problem = match foamy_helper::fs::read_file_limited(&path, MAX_FILE) {
        Ok(bytes) => match parse_stored(&bytes) {
            Ok(draft) => return Ok(json!({"ok": true, "status": "loaded", "draft": draft})),
            Err(reason) => reason,
        },
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Ok(json!({"ok": true, "status": "none", "draft": null}));
        }
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::InvalidInput | ErrorKind::InvalidData
            ) =>
        {
            error.to_string()
        }
        Err(error) => return Err(io_failure("cannot read the draft")(error)),
    };
    let aside = corrupt_file(&path);
    fs::rename(&path, &aside).map_err(io_failure("cannot move the broken draft aside"))?;
    Ok(json!({"ok": true, "status": "corrupt", "draft": null, "reason": problem, "movedTo": aside}))
}

/// `studio draft-clear`.
pub fn clear(env: &Env) -> Result<Value, Failure> {
    let path = draft_file(env)?;
    match fs::remove_file(&path) {
        Ok(()) => Ok(json!({"ok": true, "removed": true})),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            Ok(json!({"ok": true, "removed": false}))
        }
        Err(error) => Err(io_failure("cannot remove the draft")(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::time::{Duration, UNIX_EPOCH};

    fn look(preset: &str) -> Value {
        json!({"preset": preset, "layout": {"clock": {"zone": "center", "scale": 1.5}}, "glass": {}})
    }

    fn save_json(env: &Env, request: Value) -> Result<Value, Failure> {
        save_at(
            env,
            &serde_json::to_vec(&request).unwrap(),
            UNIX_EPOCH + Duration::from_secs(1_793_442_240),
        )
    }

    #[test]
    fn a_draft_round_trips() {
        let scratch = Scratch::new("draft");
        let env = scratch.env();
        assert_eq!(
            load(&env).unwrap(),
            json!({"ok": true, "status": "none", "draft": null})
        );
        let reply = save_json(
            &env,
            json!({"look": look("zen"), "history": [look("foamy"), {}]}),
        )
        .unwrap();
        let path = scratch.path("home/.local/state/foamy-lock/studio-draft.json");
        assert_eq!(
            reply,
            json!({"ok": true, "path": path, "savedAt": "2026-10-31T10:24:00Z", "history": 2, "trimmed": 0})
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let text = fs::read_to_string(&path).unwrap();
        assert_eq!(text.lines().count(), 1);
        assert_eq!(
            load(&env).unwrap(),
            json!({"ok": true, "status": "loaded", "draft": {
                "look": look("zen"), "history": [look("foamy"), {}], "savedAt": "2026-10-31T10:24:00Z"}})
        );
        // No history is an empty one.
        save_json(&env, json!({"look": {}})).unwrap();
        assert_eq!(load(&env).unwrap()["draft"]["history"], json!([]));
        assert_eq!(clear(&env).unwrap(), json!({"ok": true, "removed": true}));
        assert_eq!(clear(&env).unwrap(), json!({"ok": true, "removed": false}));
        assert_eq!(load(&env).unwrap()["status"], "none");
    }

    #[test]
    fn history_keeps_the_newest_hundred() {
        let scratch = Scratch::new("history");
        let env = scratch.env();
        let history: Vec<Value> = (0..130).map(|n| look(&format!("p{n}"))).collect();
        let reply = save_json(&env, json!({"look": {}, "history": history})).unwrap();
        assert_eq!(
            (reply["history"].as_u64(), reply["trimmed"].as_u64()),
            (Some(100), Some(30))
        );
        let stored = load(&env).unwrap();
        let history = stored["draft"]["history"].as_array().unwrap();
        assert_eq!(history.len(), 100);
        assert_eq!(history[0]["preset"], "p30");
        assert_eq!(history[99]["preset"], "p129");
    }

    #[test]
    fn bad_requests_leave_the_draft_alone() {
        let scratch = Scratch::new("badsave");
        let env = scratch.env();
        save_json(&env, json!({"look": look("zen")})).unwrap();
        let big = "x".repeat(MAX_LOOK);
        for (request, reason) in [
            (json!([]), "expected a JSON object"),
            (json!({}), "look is missing"),
            (json!({"look": {}, "extra": 1}), "unknown key extra"),
            (
                json!({"look": {"id": "foamy.lock"}}),
                "look: unknown look key id",
            ),
            (
                json!({"look": {"preset": 3}}),
                "look: preset must be a string",
            ),
            (
                json!({"look": {}, "history": {}}),
                "history must be an array",
            ),
            (
                json!({"look": {}, "history": [{}, []]}),
                "history[1]: a look must be an object",
            ),
            (
                json!({"look": {"layout": {"x": big}}}),
                "look is larger than 65536 bytes",
            ),
        ] {
            let failure = save_json(&env, request).unwrap_err();
            assert_eq!(
                (failure.code.as_str(), failure.message.as_str()),
                ("INVALID_REQUEST", reason)
            );
        }
        let failure = save_at(&env, b"{nope", SystemTime::now()).unwrap_err();
        assert_eq!(failure.code, "INVALID_REQUEST");
        assert_eq!(load(&env).unwrap()["draft"]["look"], look("zen"));
    }

    #[test]
    fn a_corrupt_draft_is_moved_aside() {
        let scratch = Scratch::new("corrupt");
        let env = scratch.env();
        let dir = scratch.path("home/.local/state/foamy-lock");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("studio-draft.json");
        let aside = dir.join("studio-draft.corrupt.json");
        for (text, reason) in [
            ("{\"version\": 1, \"look\": ", "not JSON"),
            ("[]", "not a JSON object"),
            (
                "{\"version\": 2, \"look\": {}, \"savedAt\": \"x\"}",
                "unknown version",
            ),
            (
                "{\"version\": 1, \"look\": {\"x\": 1}, \"savedAt\": \"x\"}",
                "look: unknown look key x",
            ),
            ("{\"version\": 1, \"look\": {}}", "savedAt is missing"),
        ] {
            fs::write(&path, text).unwrap();
            let reply = load(&env).unwrap();
            assert_eq!(reply["status"], "corrupt", "{text}");
            assert!(
                reply["reason"].as_str().unwrap().starts_with(reason),
                "{reply}"
            );
            assert_eq!(reply["movedTo"], aside.to_str().unwrap());
            assert_eq!(fs::read_to_string(&aside).unwrap(), text);
            assert_eq!(load(&env).unwrap()["status"], "none");
        }
        // Too many history entries, or too large a file.
        let history: Vec<Value> = (0..=MAX_HISTORY).map(|_| json!({})).collect();
        fs::write(
            &path,
            serde_json::to_vec(
                &json!({"version": 1, "look": {}, "savedAt": "x", "history": history}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            load(&env).unwrap()["reason"],
            "history has more than 100 entries"
        );
        fs::write(&path, vec![b' '; MAX_FILE as usize + 1]).unwrap();
        let reply = load(&env).unwrap();
        assert_eq!(reply["status"], "corrupt");
        assert!(
            reply["reason"].as_str().unwrap().contains("larger than"),
            "{reply}"
        );
        // A symlink is moved aside itself; its target is untouched.
        let target = scratch.file("target.json", "{}");
        symlink(&target, &path).unwrap();
        assert_eq!(load(&env).unwrap()["status"], "corrupt");
        assert!(
            fs::symlink_metadata(&aside)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
        // A save never writes through a symlink either.
        fs::remove_file(&aside).unwrap();
        symlink(&target, &path).unwrap();
        assert_eq!(save_json(&env, json!({"look": {}})).unwrap_err().code, "IO");
        assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
    }
}
