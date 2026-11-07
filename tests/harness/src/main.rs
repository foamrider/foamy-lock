//! Offscreen test harness for foamy-lock. Development only: it is not shipped
//! in bin/ and the shell never runs it.
//!
//! ```text
//! foamy-lock-harness render [--host 4.5|4.0|both] [--language CODE]
//! foamy-lock-harness parity [--host 4.5|4.0|both] [--baseline REV]
//! ```
//!
//! `render` drives the real LockView through wide, narrow, failure, busy,
//! artwork-fallback and right-to-left states with synthetic data, checks
//! focus, the password binding, media transport, the unlock hint's fit and
//! mirroring, and captures each state (`FOAMY_RENDER_OUT` keeps a copy).
//! The language is an Omarchy language code (default `en`), whatever the
//! desktop uses.
//!
//! `parity` renders the current `LockView.qml` next to a baseline revision's
//! (1.2.0 by default) in one offscreen Quickshell with the same synthetic
//! data, and compares every named item's position, size, visibility,
//! opacity, text and font size within 1 px, state by state. Both views use
//! the same fonts in the same run, so the result doesn't depend on which
//! fonts the machine has. It needs the plugin's git history for the baseline.
//!
//! Hosts follow the Python tests (tests/hosts.py): 4.5 is `FOAMY_HOST_45`,
//! else `$OMARCHY_TEST_ROOT/shell`, else `/usr/share/omarchy/shell`; 4.0 runs
//! only when `FOAMY_HOST_40` names a 4.0 shell directory.

mod app;
mod host;
mod parity;
mod png;
mod render;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("render") => render::run(&args[1..]),
        Some("parity") => parity::run(&args[1..]),
        _ => Err(format!(
            "usage: foamy-lock-harness render [--host {hosts}] [--language CODE]\n       foamy-lock-harness parity [--host {hosts}] [--baseline REV]",
            hosts = host::CHOICES.join("|")
        )),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("foamy-lock-harness: {message}");
            ExitCode::FAILURE
        }
    }
}
