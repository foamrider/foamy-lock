//! Offscreen test harness for foamy-lock. Development only: it is not shipped
//! in bin/ and the shell never runs it.
//!
//! ```text
//! foamy-lock-harness render [--host 4.5] [--language CODE]
//! foamy-lock-harness parity [--host 4.5] [--baseline REV]
//! foamy-lock-harness layout [--host 4.5] [--preset NAME]
//! foamy-lock-harness styles [--host 4.5]
//! foamy-lock-harness placement [--host 4.5]
//! foamy-lock-harness runtime [--host 4.5]
//! foamy-lock-harness thumbnails [--host 4.5] [--preset NAME]... [--out DIR]
//! foamy-lock-harness studio [--host 4.5] [--language CODE]
//! foamy-lock-harness video [--host 4.5]
//! ```
//!
//! `render` drives the real LockView through wide, narrow, failure, busy,
//! artwork-fallback and right-to-left states with synthetic data, checks
//! focus, the password binding, media transport, the unlock hint's fit and
//! mirroring, and captures each state (`FOAMY_RENDER_OUT` keeps a copy).
//! The language is an Omarchy language code (default `en`), whatever the
//! desktop uses. Then the `video` cases: a video background's switching on
//! the real view (what loads, poster first, what pauses it, giving up after
//! an error or a stall), with generated clips.
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
//! and idle field chrome, that no built-in preset falls back, and that its
//! shapes draw what the fixed decorations drew (within a pixel), under every
//! element, frosted ones first; the foamy
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
//! `placement` puts the free-placement keys (scale, opacity, offset, glass,
//! screens) on one view, case by case: the geometry codes they produce
//! (offsets off screen, onto another element or the field, the field above
//! the top third, a scale that overflows), offsets mirrored right-to-left,
//! a primary-only element on a secondary view, zone shapes that keep
//! fitting the un-offset zones and module shapes that follow their modules
//! (offset, scale, late media and weather, mirrored), an absorbing box
//! compared pixel for pixel with the module's own surface, and
//! `latchFallback: false` reporting without switching. `layout` without `--preset` runs it too.
//!
//! `runtime` runs the real Service.qml with a simulated session lock, PAM and
//! view, stand-in desktop commands, a fake Omarchy tree and shell.json, and
//! drives it over `quickshell ipc` (hermetic HOME, runtime dir and session
//! bus): settings reloads and errors, the stock-lock conflict, the avatar and
//! wallpaper helpers, password and fingerprint flows, blanking, stranded-lock
//! recovery and, on 4.5, the IpcRegistry route. It never locks the desktop.
//!
//! `thumbnails` renders every selectable preset (or each `--preset`) at
//! 1920×1080 with the synthetic data and a fixed dark theme, scaled to
//! 480×270, into `previews/presets/<name>.png` (or `--out`); drawn
//! backgrounds show their still frame. `FOAMY_RENDER_OUT` keeps full-size
//! captures too.
//!
//! `studio` runs Lock Studio (studio/) as the app, offscreen, from a root
//! built like `foamy-lock-helper studio open` builds it, in a temporary HOME:
//! the window, focus, drawing, scripted drags (snapping, Shift, Alt, the
//! password field's limits), resizes and keys compared as look JSON, the
//! problem checker, captures (paths printed), costs, and `studio raise` over
//! IPC.
//!
//! Host: Omarchy 4.5, the only supported one: `FOAMY_HOST_45`, else
//! `$OMARCHY_TEST_ROOT/shell`, else `/usr/share/omarchy/shell`.

mod app;
mod host;
mod layout;
mod parity;
mod placement;
mod png;
mod render;
mod runtime;
mod studio;
mod styles;
mod thumbnails;
mod video;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("render") => render::run(&args[1..]),
        Some("parity") => parity::run(&args[1..]),
        Some("layout") => layout::run(&args[1..]),
        Some("runtime") => runtime::run(&args[1..]),
        Some("styles") => styles::run(&args[1..]),
        Some("placement") => placement::run(&args[1..]),
        Some("thumbnails") => thumbnails::run(&args[1..]),
        Some("studio") => studio::run(&args[1..]),
        Some("video") => video::run(&args[1..]),
        _ => Err(format!(
            "usage: foamy-lock-harness render [--host {hosts}] [--language CODE]\n       foamy-lock-harness parity [--host {hosts}] [--baseline REV]\n       foamy-lock-harness layout [--host {hosts}] [--preset NAME]\n       foamy-lock-harness styles [--host {hosts}]\n       foamy-lock-harness placement [--host {hosts}]\n       foamy-lock-harness runtime [--host {hosts}]\n       foamy-lock-harness thumbnails [--host {hosts}] [--preset NAME]... [--out DIR]\n       foamy-lock-harness studio [--host {hosts}] [--language CODE]",
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
