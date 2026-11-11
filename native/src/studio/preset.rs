//! `studio preset save` / `preset rename` / `preset delete`: one user
//! preset at a time, through the running lock.
//!
//! **stdin** (at most 256 KiB), a JSON object with only these keys:
//! - `save`: `{"id", "name", "look"}`. `look` is a look (see `check_look`)
//!   without `userPreset`; at most 64 KiB once compacted.
//! - `rename`: `{"id", "name"}`. The new name must not start with `-`: it
//!   is its own argument to omarchy-shell (Layout.userPresetNewNameError).
//! - `delete`: `{"id"}`.
//!
//! `id` is the client's own (1 to 40 lowercase letters, digits and dashes,
//! not starting with a dash), so a retry is the same request. `name` is
//! 1 to 64 UTF-16 code units with no control characters and no leading or
//! trailing whitespace, as the lock counts. Anything else is
//! `INVALID_REQUEST` (exit 1) and nothing is called.
//!
//! **The calls**: `omarchy-shell foamy.lock savePreset <item>` (the item
//! compacted, key order and numbers as sent), `renamePreset <id> <name>`
//! and `deletePreset <id>`, found and bounded as `apply` does, with its
//! single retry when the shell doesn't answer: each operation is
//! idempotent (a save or rename that landed answers `unchanged` the second
//! time, and so does a delete of an id that's gone).
//!
//! **stdout**: `apply`'s reply line and results; `full` (50 presets
//! already), `too-large` (more than 256 KiB of presets) and
//! `unknown-preset` (renaming an id that isn't there) come from these.

use foamy_helper::Failure;
use serde_json::{Map, Value};

use super::apply::{self, MAX_ARGUMENT, Options};
use super::{Env, LINK_KEY, check_look, check_preset_id, compact_json};

pub const MAX_REQUEST: u64 = 256 * 1024;
pub const MAX_NAME: usize = 64;

fn invalid(reason: impl Into<String>) -> Failure {
    Failure::coded("INVALID_REQUEST", reason.into())
}

/// The lock's name rule (Layout.userPresetNameError).
pub fn check_name(name: &Value) -> Result<(), String> {
    let Some(name) = name.as_str() else {
        return Err("name must be a string".into());
    };
    if name.is_empty() || name.trim() != name {
        return Err("name must be non-empty, without leading or trailing whitespace".into());
    }
    if name.encode_utf16().count() > MAX_NAME {
        return Err(format!("name must be at most {MAX_NAME} characters"));
    }
    let control =
        |c: char| matches!(c, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{2028}' | '\u{2029}');
    if name.chars().any(control) {
        return Err("name must not contain control characters".into());
    }
    Ok(())
}

fn object<'a>(value: &'a Value, keys: &[&str]) -> Result<&'a Map<String, Value>, Failure> {
    let Value::Object(map) = value else {
        return Err(invalid("the request must be an object"));
    };
    for key in map.keys() {
        if !keys.contains(&key.as_str()) {
            return Err(invalid(format!("unknown key {key}")));
        }
    }
    for key in keys {
        if !map.contains_key(*key) {
            return Err(invalid(format!("{key} is missing")));
        }
    }
    Ok(map)
}

/// The `omarchy-shell foamy.lock` arguments for `op` and its request.
pub fn arguments(op: &str, request: &[u8]) -> Result<Vec<String>, Failure> {
    let text = std::str::from_utf8(request).map_err(|_| invalid("the request isn't UTF-8"))?;
    let value: Value = serde_json::from_str(text)
        .map_err(|error| invalid(format!("the request isn't JSON: {error}")))?;
    let keys: &[&str] = match op {
        "save" => &["id", "name", "look"],
        "rename" => &["id", "name"],
        "delete" => &["id"],
        _ => {
            return Err(Failure::coded(
                "INVALID_ARGUMENT",
                format!("unknown preset operation {op}"),
            ));
        }
    };
    let map = object(&value, keys)?;
    check_preset_id(&map["id"]).map_err(|reason| invalid(format!("id: {reason}")))?;
    if let Some(name) = map.get("name") {
        check_name(name).map_err(invalid)?;
    }
    let id = map["id"].as_str().unwrap_or_default().to_string();
    match op {
        "save" => {
            let look = &map["look"];
            check_look(look).map_err(|reason| invalid(format!("look: {reason}")))?;
            if look.get(LINK_KEY).is_some() {
                return Err(invalid(format!(
                    "look: a user preset's look has no {LINK_KEY}"
                )));
            }
            let compact = compact_json(text.trim());
            if compact.len() > MAX_ARGUMENT {
                return Err(invalid(format!(
                    "the preset is larger than {MAX_ARGUMENT} bytes"
                )));
            }
            Ok(vec!["savePreset".into(), compact])
        }
        "rename" => {
            let name = map["name"].as_str().unwrap_or_default().to_string();
            // The name is an argument of its own here (a save carries it
            // inside the item's JSON), and `qs ipc`, omarchy-shell's
            // fallback, could take one starting with `-` for an option.
            if name.starts_with('-') {
                return Err(invalid("name must not start with -"));
            }
            Ok(vec!["renamePreset".into(), id, name])
        }
        _ => Ok(vec!["deletePreset".into(), id]),
    }
}

/// `studio preset <op>`.
pub fn run(env: &Env, op: &str, request: &[u8], options: &Options) -> Result<Value, Failure> {
    let args = arguments(op, request)?;
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    Ok(apply::run(env, &args, options))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use serde_json::json;
    use std::fs;
    use std::time::Duration;

    /// A fake omarchy-shell whose n-th run runs `steps[n - 1]` (the last one
    /// from then on) and records its arguments in `args-<n>`.
    fn fake(scratch: &Scratch, steps: &[&str]) {
        let dir = scratch.0.display();
        let mut body = format!(
            "dir='{dir}'\nn=$(( $(cat \"$dir/count\" 2>/dev/null || echo 0) + 1 ))\necho $n > \"$dir/count\"\n\
             printf '%s\\n' \"$@\" > \"$dir/args-$n\"\ncase $n in\n"
        );
        for (index, step) in steps.iter().enumerate() {
            let pattern = if index + 1 == steps.len() {
                "*".to_string()
            } else {
                (index + 1).to_string()
            };
            body.push_str(&format!("  {pattern}) {step};;\n"));
        }
        body.push_str("esac\n");
        scratch.script("bin/omarchy-shell", &body);
    }

    fn quick() -> Options {
        Options {
            timeout: Duration::from_secs(3),
            retry_wait: Duration::from_millis(10),
        }
    }

    const SAVE: &str = "{ \"id\": \"mine-1\", \"name\": \"Ålesund (min) نمط\",\n \"look\": {\"preset\": \"zen\", \"glass\": {\"opacity\": 0.50}} }\n";
    const NOT_RESPONDING: &str = "echo 'omarchy-shell is not responding' >&2; exit 1";

    fn run_op(op: &str, request: &str, steps: &[&str]) -> (Value, Scratch) {
        let scratch = Scratch::new("preset");
        fake(&scratch, steps);
        let reply = run(&scratch.env(), op, request.as_bytes(), &quick()).unwrap();
        (reply, scratch)
    }

    #[test]
    fn each_operation_is_one_call_with_its_arguments() {
        let (reply, scratch) = run_op("save", SAVE, &["echo ok"]);
        assert_eq!(
            reply,
            json!({"ok": true, "result": "ok", "message": "Saved.", "confirmed": true, "attempts": 1})
        );
        assert_eq!(
            fs::read_to_string(scratch.path("args-1")).unwrap(),
            "foamy.lock\nsavePreset\n{\"id\":\"mine-1\",\"name\":\"Ålesund (min) نمط\",\"look\":{\"preset\":\"zen\",\"glass\":{\"opacity\":0.50}}}\n",
            "the item goes as one compact argument, as sent"
        );
        let (_, scratch) = run_op(
            "rename",
            "{\"id\": \"mine-1\", \"name\": \"Bee: \\\"b\\\" $(x)\"}",
            &["echo ok"],
        );
        assert_eq!(
            fs::read_to_string(scratch.path("args-1")).unwrap(),
            "foamy.lock\nrenamePreset\nmine-1\nBee: \"b\" $(x)\n",
            "the name is one argument, never a shell word"
        );
        let (reply, scratch) = run_op("delete", "{\"id\": \"mine-1\"}", &["echo unchanged"]);
        assert_eq!(
            (reply["result"].as_str(), reply["ok"].as_bool()),
            (Some("unchanged"), Some(true))
        );
        assert_eq!(
            fs::read_to_string(scratch.path("args-1")).unwrap(),
            "foamy.lock\ndeletePreset\nmine-1\n"
        );
    }

    #[test]
    fn the_preset_replies_are_classified() {
        for (step, result, ok) in [
            ("echo full", "full", false),
            ("echo too-large", "too-large", false),
            ("echo unknown-preset", "unknown-preset", false),
            ("echo write-failed", "write-failed", false),
            ("echo no-entry", "no-entry", false),
            ("echo locked", "locked", false),
        ] {
            let (reply, _) = run_op("save", SAVE, &[step]);
            assert_eq!(
                (
                    reply["result"].as_str(),
                    reply["ok"].as_bool(),
                    reply["confirmed"].as_bool()
                ),
                (Some(result), Some(ok), Some(true)),
                "{step}"
            );
            assert!(!reply["message"].as_str().unwrap().is_empty());
        }
        let (reply, _) = run_op(
            "save",
            SAVE,
            &["echo 'invalid: name must be at most 64 characters'"],
        );
        assert_eq!(reply["reason"], "name must be at most 64 characters");
    }

    #[test]
    fn an_unclear_answer_is_retried_once_and_idempotent() {
        let (reply, scratch) = run_op("save", SAVE, &[NOT_RESPONDING, "echo unchanged"]);
        assert_eq!(
            (
                reply["result"].as_str(),
                reply["confirmed"].as_bool(),
                reply["attempts"].as_u64()
            ),
            (Some("unchanged"), Some(true), Some(2))
        );
        assert_eq!(
            fs::read_to_string(scratch.path("args-2")).unwrap(),
            fs::read_to_string(scratch.path("args-1")).unwrap(),
            "the same call again, with the same id"
        );
        // A first save that didn't land: these refusals are certain.
        for step in ["echo full", "echo too-large"] {
            let (reply, _) = run_op("save", SAVE, &[NOT_RESPONDING, step]);
            assert_eq!(reply["confirmed"], true, "{step}");
        }
        let (reply, _) = run_op(
            "rename",
            "{\"id\": \"a\", \"name\": \"B\"}",
            &[NOT_RESPONDING, "echo unknown-preset"],
        );
        assert_eq!(
            (reply["result"].as_str(), reply["confirmed"].as_bool()),
            (Some("unknown-preset"), Some(true))
        );
        // write-failed and locked now say nothing about the first call.
        for step in ["echo write-failed", "echo locked"] {
            let (reply, _) = run_op("delete", "{\"id\": \"a\"}", &[NOT_RESPONDING, step]);
            assert_eq!(reply["confirmed"], false, "{step}");
        }
        let (reply, scratch) = run_op("delete", "{\"id\": \"a\"}", &[NOT_RESPONDING]);
        assert_eq!(
            (
                reply["result"].as_str(),
                reply["confirmed"].as_bool(),
                reply["attempts"].as_u64()
            ),
            (Some("not-responding"), Some(false), Some(2))
        );
        assert!(!scratch.path("args-3").exists(), "only one retry");
    }

    #[test]
    fn bad_requests_call_nothing() {
        let scratch = Scratch::new("badpreset");
        fake(&scratch, &["echo ok"]);
        let env = scratch.env();
        let long = format!("{{\"id\": \"a\", \"name\": \"{}\"}}", "x".repeat(65));
        let wide = format!("{{\"id\": \"a\", \"name\": \"{}\"}}", "😀".repeat(33));
        let big = format!(
            "{{\"id\": \"a\", \"name\": \"A\", \"look\": {{\"layout\": {{\"x\": \"{}\"}}}}}}",
            "x".repeat(MAX_ARGUMENT)
        );
        for (op, request) in [
            ("save", ""),
            ("save", "[]"),
            ("save", "{\"id\": \"a\", \"name\": \"A\"}"),
            (
                "save",
                "{\"id\": \"a\", \"name\": \"A\", \"look\": {}, \"extra\": 1}",
            ),
            (
                "save",
                "{\"id\": \"a\", \"name\": \"A\", \"look\": {\"userPreset\": \"b\"}}",
            ),
            (
                "save",
                "{\"id\": \"a\", \"name\": \"A\", \"look\": {\"preset\": 1}}",
            ),
            ("save", "{\"id\": \"a\", \"name\": \"A\", \"look\": []}"),
            ("save", big.as_str()),
            ("rename", "{\"id\": \"A\", \"name\": \"A\"}"),
            ("rename", "{\"id\": \"-a\", \"name\": \"A\"}"),
            ("rename", "{\"id\": \"a\", \"name\": \" A\"}"),
            ("rename", "{\"id\": \"a\", \"name\": \"\"}"),
            ("rename", "{\"id\": \"a\", \"name\": \"a\\nb\"}"),
            ("rename", "{\"id\": \"a\", \"name\": 3}"),
            ("rename", "{\"id\": \"a\", \"name\": \"--help\"}"),
            ("rename", "{\"id\": \"a\", \"name\": \"-A\"}"),
            ("rename", long.as_str()),
            ("rename", wide.as_str()),
            ("delete", "{\"id\": \"../a\"}"),
            ("delete", "{\"id\": \"a\", \"name\": \"A\"}"),
            ("delete", "{}"),
        ] {
            let failure = run(&env, op, request.as_bytes(), &quick()).unwrap_err();
            assert_eq!(failure.code, "INVALID_REQUEST", "{op} {request}");
        }
        assert_eq!(
            run(&env, "save", b"\xff", &quick()).unwrap_err().code,
            "INVALID_REQUEST"
        );
        assert_eq!(
            run(&env, "move", b"{}", &quick()).unwrap_err().code,
            "INVALID_ARGUMENT"
        );
        assert!(!scratch.path("count").exists());
        // The edges that are fine.
        assert!(
            arguments(
                "rename",
                format!(
                    "{{\"id\": \"{}\", \"name\": \"{}\"}}",
                    "a".repeat(40),
                    "x".repeat(64)
                )
                .as_bytes()
            )
            .is_ok()
        );
        assert!(
            arguments(
                "rename",
                format!("{{\"id\": \"a\", \"name\": \"{}\"}}", "😀".repeat(32)).as_bytes()
            )
            .is_ok()
        );
    }
}
