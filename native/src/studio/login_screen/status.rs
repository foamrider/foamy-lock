//! `studio login-screen status`. Placeholder until the status part lands.

use std::path::Path;

use foamy_helper::Failure;
use serde_json::Value;

use crate::studio::Env;

pub fn run(_env: &Env, _plugin_dir: &Path) -> Result<Value, Failure> {
    Err(Failure::coded(
        "INTERNAL",
        "login-screen status is not built yet",
    ))
}
