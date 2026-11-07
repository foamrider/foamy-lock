//! Offscreen test harness for foamy-lock. Development only: it is not shipped
//! in bin/ and the shell never runs it.
//!
//! ```text
//! foamy-lock-harness render [--host 4.5|4.0|both] [--language CODE]
//! foamy-lock-harness parity [--host 4.5|4.0|both] [--baseline REV]
//! foamy-lock-harness layout [--host 4.5|4.0|both] [--preset NAME]
//! foamy-lock-harness styles [--host 4.5|4.0|both]
//! foamy-lock-harness runtime [--host 4.5|4.0|both]
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
//! `layout` renders each selectable preset (or `--preset NAME`) through
//! four screen sizes, 12- and 24-hour time, typing, and primary and
//! secondary screens, checking that the password field stays on screen,
//! uncovered, live and focused, that a secondary screen hides the account
//! and idle field chrome, and that no built-in preset falls back; the foamy
//! run then forces the geometry fallback chain on a 320×240 screen. Without
//! `--preset` it also runs `styles`.
//!
//! `styles` puts every style of every element in each column of its row
//! (1920×1080 and 800×1000, 12- and 24-hour time, typing and idle, primary
//! and secondary) and checks that the field stays on screen, uncovered, live,
//! focused and one size, that every element and its parts stay in place, the
//! avatar square, and that nothing falls back; then it switches one view
//! through every style, left-to-right and mirrored (each part must mirror),
//! and back to the default, whose geometry must return exactly. Plugin QML
//! warnings fail it. With `FOAMY_RENDER_OUT` it keeps two captures per case.
//!
//! `runtime` runs the real Service.qml with a simulated session lock, PAM and
//! view, stand-in desktop commands, a fake Omarchy tree and shell.json, and
//! drives it over `quickshell ipc` (hermetic HOME, runtime dir and session
//! bus): settings reloads and errors, the stock-lock conflict, the avatar and
//! wallpaper helpers, password and fingerprint flows, blanking, stranded-lock
//! recovery and, on 4.5, the IpcRegistry route. It never locks the desktop.
//!
//! Hosts: 4.5 is `FOAMY_HOST_45`,
//! else `$OMARCHY_TEST_ROOT/shell`, else `/usr/share/omarchy/shell`; 4.0 runs
//! only when `FOAMY_HOST_40` names a 4.0 shell directory.

mod app;
mod host;
mod layout;
mod parity;
mod png;
mod render;
mod runtime;
mod styles;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("render") => render::run(&args[1..]),
        Some("parity") => parity::run(&args[1..]),
        Some("layout") => layout::run(&args[1..]),
        Some("runtime") => runtime::run(&args[1..]),
        Some("styles") => styles::run(&args[1..]),
        _ => Err(format!(
            "usage: foamy-lock-harness render [--host {hosts}] [--language CODE]\n       foamy-lock-harness parity [--host {hosts}] [--baseline REV]\n       foamy-lock-harness layout [--host {hosts}] [--preset NAME]\n       foamy-lock-harness styles [--host {hosts}]\n       foamy-lock-harness runtime [--host {hosts}]",
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
