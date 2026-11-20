//! `studio login-screen stage`. Placeholder until the stage part lands.

use std::path::Path;

use foamy_helper::Failure;
use serde_json::Value;

use crate::studio::Env;

/// The largest request `stage` reads from stdin.
pub const MAX_REQUEST: u64 = 64 * 1024;

pub fn run(_env: &Env, _plugin_dir: &Path, _request: &[u8]) -> Result<Value, Failure> {
    Err(Failure::coded(
        "INTERNAL",
        "login-screen stage is not built yet",
    ))
}
