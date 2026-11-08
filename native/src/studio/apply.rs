//! `studio apply`: save a look through the running lock.
//!
//! **stdin** (at most 256 KiB): the look, a JSON object with only `preset`,
//! `layout`, `background` and `glass` (see `draft`); at most 64 KiB once
//! compacted (one command-line argument). Anything else is
//! `INVALID_REQUEST` (exit 1) and nothing is called.
//!
//! **The call**: `omarchy-shell foamy.lock saveLook <look>`, the look
//! compacted with its key order and numbers exactly as sent. `omarchy-shell`
//! is looked up in `PATH`, then `$OMARCHY_PATH/bin` and
//! `/usr/share/omarchy/bin`; `OMARCHY_PATH` is set for it when unset. Each
//! call is bounded (6 s; `omarchy-shell` itself gives up after 2 s).
//!
//! **One retry**: an unclear answer ("omarchy-shell is not responding", or
//! no answer within the bound: the call may have run) is retried once after
//! 1 s. `saveLook` is idempotent and answers `unchanged` when the look is
//! already there, which confirms the first call landed.
//!
//! **stdout** (exit 0 whatever the lock said): `{"ok": <saved>, "result":
//! <result>, "message": "<English>", "confirmed": <bool>, "attempts": 1 |
//! 2}`, plus `"reason"` for `invalid` and `"detail"` (the raw text) for
//! `unexpected` and `failed`. `ok` is true for `ok` and `unchanged`.
//! `confirmed` is true when the outcome is certain: the look is saved, or it
//! certainly wasn't (a refusal from the lock, or a failure that comes
//! before anything runs). After a retry only `ok`, `unchanged` and the
//! lock's deterministic refusals (`invalid-json`, `invalid`, `unsupported`,
//! `no-entry`) confirm.
//!
//! Results, from the lock: `ok`, `unchanged`, `invalid-json`, `invalid`
//! (`reason` is the lock's text after `invalid:`), `locked`, `unsupported`,
//! `no-entry`, `unexpected` (any other answer); from `omarchy-shell`:
//! `not-responding`, `not-ready`, `not-running`, `target-not-found` (Foamy
//! Lock isn't loaded), `function-not-found` (a lock without `saveLook`),
//! `no-omarchy-shell`, `failed` (any other failure).

use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use foamy_helper::Failure;
use foamy_helper::child::{Bounded, Output};
use serde_json::{Value, json};

use super::{Env, check_look, compact_json};

pub const MAX_REQUEST: u64 = 256 * 1024;
/// The look as one argument (Linux allows 128 KiB per argument).
pub const MAX_ARGUMENT: usize = 64 * 1024;

#[derive(Debug, Clone)]
pub struct Options {
    pub timeout: Duration,
    pub retry_wait: Duration,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            timeout: Duration::from_secs(6),
            retry_wait: Duration::from_secs(1),
        }
    }
}

/// One answer, classified.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer {
    Ok,
    Unchanged,
    InvalidJson,
    Invalid(String),
    Locked,
    Unsupported,
    NoEntry,
    Unexpected(String),
    NotResponding,
    NotReady,
    NotRunning,
    TargetNotFound,
    FunctionNotFound,
    Missing,
    Failed(String),
}

impl Answer {
    pub fn result(&self) -> &'static str {
        match self {
            Answer::Ok => "ok",
            Answer::Unchanged => "unchanged",
            Answer::InvalidJson => "invalid-json",
            Answer::Invalid(_) => "invalid",
            Answer::Locked => "locked",
            Answer::Unsupported => "unsupported",
            Answer::NoEntry => "no-entry",
            Answer::Unexpected(_) => "unexpected",
            Answer::NotResponding => "not-responding",
            Answer::NotReady => "not-ready",
            Answer::NotRunning => "not-running",
            Answer::TargetNotFound => "target-not-found",
            Answer::FunctionNotFound => "function-not-found",
            Answer::Missing => "no-omarchy-shell",
            Answer::Failed(_) => "failed",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Answer::Ok => "Saved.".into(),
            Answer::Unchanged => "Saved; it was already the lock's look.".into(),
            Answer::InvalidJson => "The lock couldn't read the look.".into(),
            Answer::Invalid(reason) => format!("The lock refused the look: {reason}"),
            Answer::Locked => "The screen is locked, so the look wasn't saved.".into(),
            Answer::Unsupported => "This Omarchy can't save plugin settings.".into(),
            Answer::NoEntry => "Foamy Lock has no entry in shell.json.".into(),
            Answer::Unexpected(text) => format!("The lock gave an unexpected answer: {text}"),
            Answer::NotResponding => {
                "The shell didn't answer in time; the look may not have been saved.".into()
            }
            Answer::NotReady => "The shell is still starting; try again in a moment.".into(),
            Answer::NotRunning => "The shell isn't running.".into(),
            Answer::TargetNotFound => "Foamy Lock isn't loaded in the shell.".into(),
            Answer::FunctionNotFound => {
                "The running Foamy Lock can't save looks; update it or restart the shell.".into()
            }
            Answer::Missing => "omarchy-shell isn't installed.".into(),
            Answer::Failed(text) => format!("omarchy-shell failed: {text}"),
        }
    }

    pub fn saved(&self) -> bool {
        matches!(self, Answer::Ok | Answer::Unchanged)
    }

    /// The same request would get the same refusal: the first call can't
    /// have saved anything either.
    fn deterministic(&self) -> bool {
        matches!(
            self,
            Answer::InvalidJson | Answer::Invalid(_) | Answer::Unsupported | Answer::NoEntry
        )
    }

    /// Certain on a first attempt.
    fn certain(&self) -> bool {
        !matches!(
            self,
            Answer::NotResponding | Answer::Unexpected(_) | Answer::Failed(_)
        )
    }
}

fn first_line(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    let text = text.trim();
    text.chars().take(500).collect()
}

/// Classifies one `omarchy-shell` run.
pub fn classify(output: &Output) -> Answer {
    if output.timed_out {
        return Answer::NotResponding;
    }
    let stdout = first_line(&output.stdout);
    let stderr = first_line(&output.stderr);
    let text = if output.status.success() {
        &stdout
    } else {
        &stderr
    };
    let shell_failure = match text.as_str() {
        "omarchy-shell is not responding" => Some(Answer::NotResponding),
        "omarchy-shell is not ready" => Some(Answer::NotReady),
        "omarchy-shell is not running" => Some(Answer::NotRunning),
        "Target not found." => Some(Answer::TargetNotFound),
        "Function not found." => Some(Answer::FunctionNotFound),
        _ => None,
    };
    if let Some(answer) = shell_failure {
        return answer;
    }
    if !output.status.success() || output.overflowed {
        let detail = if stderr.is_empty() {
            format!("{}", output.status)
        } else {
            stderr
        };
        return Answer::Failed(detail);
    }
    match stdout.as_str() {
        "ok" => Answer::Ok,
        "unchanged" => Answer::Unchanged,
        "invalid-json" => Answer::InvalidJson,
        "locked" => Answer::Locked,
        "unsupported" => Answer::Unsupported,
        "no-entry" => Answer::NoEntry,
        text => match text.strip_prefix("invalid:") {
            Some(reason) => Answer::Invalid(reason.trim().to_string()),
            None => Answer::Unexpected(text.to_string()),
        },
    }
}

fn omarchy_shell(env: &Env) -> Option<PathBuf> {
    let fallbacks = [
        env.omarchy_dir().join("bin/omarchy-shell"),
        env.system_omarchy.join("bin/omarchy-shell"),
    ];
    env.find("omarchy-shell", &fallbacks)
}

fn call(env: &Env, program: &Path, look: &str, options: &Options) -> Answer {
    let mut command = Bounded::new(program)
        .args(["foamy.lock", "saveLook", look])
        .env("PATH", &env.path)
        .timeout(options.timeout)
        .max_output(64 * 1024);
    if env.omarchy.is_none() {
        command = command.env("OMARCHY_PATH", &env.system_omarchy);
    }
    match command.run() {
        Ok(output) => classify(&output),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Answer::Missing,
        Err(error) => Answer::Failed(error.to_string()),
    }
}

/// The look argument from the request on stdin.
pub fn look_argument(request: &[u8]) -> Result<String, Failure> {
    let invalid = |reason: String| Failure::coded("INVALID_REQUEST", reason);
    let text = std::str::from_utf8(request).map_err(|_| invalid("the look isn't UTF-8".into()))?;
    let look: Value = serde_json::from_str(text)
        .map_err(|error| invalid(format!("the look isn't JSON: {error}")))?;
    check_look(&look).map_err(invalid)?;
    let compact = compact_json(text.trim());
    if compact.len() > MAX_ARGUMENT {
        return Err(invalid(format!(
            "the look is larger than {MAX_ARGUMENT} bytes"
        )));
    }
    Ok(compact)
}

/// `studio apply`.
pub fn apply(env: &Env, request: &[u8], options: &Options) -> Result<Value, Failure> {
    let look = look_argument(request)?;
    let Some(program) = omarchy_shell(env) else {
        return Ok(reply(&Answer::Missing, true, 0));
    };
    let first = call(env, &program, &look, options);
    if first != Answer::NotResponding {
        let certain = first.certain();
        return Ok(reply(&first, certain, 1));
    }
    thread::sleep(options.retry_wait);
    let second = call(env, &program, &look, options);
    let confirmed = second.saved() || second.deterministic();
    Ok(reply(&second, confirmed, 2))
}

fn reply(answer: &Answer, confirmed: bool, attempts: u32) -> Value {
    let mut reply = json!({
        "ok": answer.saved(),
        "result": answer.result(),
        "message": answer.message(),
        "confirmed": confirmed,
        "attempts": attempts,
    });
    match answer {
        Answer::Invalid(reason) => reply["reason"] = json!(reason),
        Answer::Unexpected(text) | Answer::Failed(text) => reply["detail"] = json!(text),
        _ => {}
    }
    reply
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::studio::tests::Scratch;
    use std::fs;

    const LOOK: &str = "{ \"preset\": \"zen\",\n  \"layout\": {\"clock\": {\"zone\": \"top\", \"scale\": 1.50}},\n  \"glass\": {} }\n";
    const COMPACT: &str = "{\"preset\":\"zen\",\"layout\":{\"clock\":{\"zone\":\"top\",\"scale\":1.50}},\"glass\":{}}";

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

    fn run(steps: &[&str]) -> (Value, Scratch) {
        let scratch = Scratch::new("apply");
        fake(&scratch, steps);
        let reply = apply(&scratch.env(), LOOK.as_bytes(), &quick()).unwrap();
        (reply, scratch)
    }

    const NOT_RESPONDING: &str = "echo 'omarchy-shell is not responding' >&2; exit 1";

    #[test]
    fn every_lock_reply_is_classified() {
        for (step, result, ok) in [
            ("echo ok", "ok", true),
            ("echo unchanged", "unchanged", true),
            ("echo invalid-json", "invalid-json", false),
            ("echo locked", "locked", false),
            ("echo unsupported", "unsupported", false),
            ("echo no-entry", "no-entry", false),
        ] {
            let (reply, scratch) = run(&[step]);
            assert_eq!(
                reply,
                json!({"ok": ok, "result": result, "message": reply["message"], "confirmed": true, "attempts": 1}),
                "{step}"
            );
            assert!(!reply["message"].as_str().unwrap().is_empty());
            assert_eq!(
                fs::read_to_string(scratch.path("args-1")).unwrap(),
                format!("foamy.lock\nsaveLook\n{COMPACT}\n"),
                "the look goes as one compact argument, in its own key order"
            );
        }
        let (reply, _) = run(&["echo 'invalid: preset must be one of foamy, zen'"]);
        assert_eq!(
            (reply["result"].as_str(), reply["ok"].as_bool()),
            (Some("invalid"), Some(false))
        );
        assert_eq!(reply["reason"], "preset must be one of foamy, zen");
        assert_eq!(reply["confirmed"], true);
        assert_eq!(
            reply["message"],
            "The lock refused the look: preset must be one of foamy, zen"
        );
        let (reply, _) = run(&["echo 'something new'"]);
        assert_eq!(
            (reply["result"].as_str(), reply["detail"].as_str()),
            (Some("unexpected"), Some("something new"))
        );
        assert_eq!(reply["confirmed"], false);
    }

    #[test]
    fn every_omarchy_shell_failure_is_classified() {
        for (step, result, confirmed) in [
            (
                "echo 'omarchy-shell is not ready' >&2; exit 1",
                "not-ready",
                true,
            ),
            (
                "echo 'omarchy-shell is not running' >&2; exit 1",
                "not-running",
                true,
            ),
            (
                "echo 'Target not found.' >&2; exit 1",
                "target-not-found",
                true,
            ),
            (
                "echo 'Function not found.' >&2; exit 1",
                "function-not-found",
                true,
            ),
            (
                "echo 'OMARCHY_PATH is not set' >&2; exit 1",
                "failed",
                false,
            ),
            ("exit 3", "failed", false),
        ] {
            let (reply, scratch) = run(&[step]);
            assert_eq!(reply["result"], result, "{step}");
            assert_eq!(reply["ok"], false);
            assert_eq!(reply["confirmed"], confirmed, "{step}");
            assert_eq!(reply["attempts"], 1);
            assert!(!scratch.path("args-2").exists(), "{step}: no retry");
        }
        let (reply, _) = run(&["echo 'OMARCHY_PATH is not set' >&2; exit 1"]);
        assert_eq!(reply["detail"], "OMARCHY_PATH is not set");
    }

    #[test]
    fn an_unclear_answer_is_retried_once() {
        let (reply, scratch) = run(&[NOT_RESPONDING, "echo unchanged"]);
        assert_eq!(
            reply,
            json!({"ok": true, "result": "unchanged", "message": Answer::Unchanged.message(),
                "confirmed": true, "attempts": 2})
        );
        assert_eq!(
            fs::read_to_string(scratch.path("args-2")).unwrap(),
            fs::read_to_string(scratch.path("args-1")).unwrap(),
            "the same call again"
        );
        let (reply, _) = run(&[NOT_RESPONDING, "echo ok"]);
        assert_eq!(
            (reply["result"].as_str(), reply["confirmed"].as_bool()),
            (Some("ok"), Some(true))
        );
        let (reply, scratch) = run(&[NOT_RESPONDING]);
        assert_eq!(reply["result"], "not-responding");
        assert_eq!(
            (reply["ok"].as_bool(), reply["confirmed"].as_bool()),
            (Some(false), Some(false))
        );
        assert_eq!(reply["attempts"], 2);
        assert!(!scratch.path("args-3").exists(), "only one retry");
        // Locked now says nothing about the first call; invalid would have
        // refused it too.
        let (reply, _) = run(&[NOT_RESPONDING, "echo locked"]);
        assert_eq!(
            (reply["result"].as_str(), reply["confirmed"].as_bool()),
            (Some("locked"), Some(false))
        );
        let (reply, _) = run(&[NOT_RESPONDING, "echo 'invalid: bad'"]);
        assert_eq!(
            (reply["result"].as_str(), reply["confirmed"].as_bool()),
            (Some("invalid"), Some(true))
        );
        let (reply, _) = run(&[
            NOT_RESPONDING,
            "echo 'omarchy-shell is not ready' >&2; exit 1",
        ]);
        assert_eq!(
            (reply["result"].as_str(), reply["confirmed"].as_bool()),
            (Some("not-ready"), Some(false))
        );
    }

    #[test]
    fn a_hanging_omarchy_shell_is_bounded_and_retried() {
        let scratch = Scratch::new("hang");
        fake(&scratch, &["sleep 5", "echo unchanged"]);
        let options = Options {
            timeout: Duration::from_millis(300),
            retry_wait: Duration::from_millis(10),
        };
        let started = std::time::Instant::now();
        let reply = apply(&scratch.env(), LOOK.as_bytes(), &options).unwrap();
        assert!(started.elapsed() < Duration::from_secs(3));
        assert_eq!(
            (reply["result"].as_str(), reply["attempts"].as_u64()),
            (Some("unchanged"), Some(2))
        );
        assert_eq!(reply["confirmed"], true);
    }

    #[test]
    fn omarchy_shell_is_found_beside_omarchy_when_not_in_path() {
        let scratch = Scratch::new("fallback");
        let env = scratch.env();
        assert_eq!(
            apply(&env, LOOK.as_bytes(), &quick()).unwrap(),
            json!({"ok": false, "result": "no-omarchy-shell", "message": "omarchy-shell isn't installed.",
                "confirmed": true, "attempts": 0})
        );
        let dir = scratch.0.display();
        scratch.script(
            "omarchy/bin/omarchy-shell",
            &format!("printf '%s' \"$OMARCHY_PATH\" > '{dir}/omarchy-path'; echo ok"),
        );
        assert_eq!(
            apply(&env, LOOK.as_bytes(), &quick()).unwrap()["result"],
            "ok"
        );
        assert_eq!(
            fs::read_to_string(scratch.path("omarchy-path")).unwrap(),
            scratch.path("omarchy").to_str().unwrap(),
            "OMARCHY_PATH is set for it when unset"
        );
    }

    #[test]
    fn bad_requests_call_nothing() {
        let scratch = Scratch::new("badapply");
        fake(&scratch, &["echo ok"]);
        let env = scratch.env();
        let big = format!(
            "{{\"layout\": {{\"x\": \"{}\"}}}}",
            "x".repeat(MAX_ARGUMENT)
        );
        for request in [
            "",
            "[]",
            "{nope",
            "{\"id\": \"foamy.lock\"}",
            "{\"preset\": 1}",
            big.as_str(),
        ] {
            let failure = apply(&env, request.as_bytes(), &quick()).unwrap_err();
            assert_eq!(failure.code, "INVALID_REQUEST", "{request}");
        }
        assert_eq!(
            apply(&env, b"\xff", &quick()).unwrap_err().code,
            "INVALID_REQUEST"
        );
        assert!(!scratch.path("count").exists());
        assert_eq!(look_argument(b"{}\n").unwrap(), "{}");
    }
}
