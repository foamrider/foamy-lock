//! `foamy-lock-helper`: bounded lock-screen artwork and the account avatar
//! thumbnail, the lock-screen background, and the wallpaper probe. Replaces
//! `artwork.py`; carries over every bound on purpose. Original images never
//! enter the shell: all go through the same sandboxed decoder and come
//! back as a freshly encoded PNG (256x256, or the screen's size for a
//! background).
//!
//! # Contract
//!
//! - **argv**: `foamy-lock-helper artwork` (below), `foamy-lock-helper
//!   wallpaper <link>` (see `wallpaper`), `foamy-lock-helper video-probe`
//!   or `foamy-lock-helper video-convert` (video wallpapers, below).
//!   Anything else replies `invalid-request`. `foamy-lock-helper studio …`
//!   is Lock Studio's, with its own contract and replies (see `studio`); it
//!   never runs the image sandbox.
//! - **video-probe** and **video-convert** (see `video`): stdin one line
//!   `{"path": "/absolute/video", "width": W, "height": H}`, W x H the
//!   largest screen's native size (16 to 7680 by 16 to 4320, else
//!   `invalid-size`; then the path as for a background, else
//!   `invalid-video-path`). The output size is W x H scaled down to fit
//!   3840x2160, both sides even. The file (symlinks followed, any owner) is
//!   opened once and only that descriptor is used: hashed (SHA-256) here
//!   and handed to the sandbox as fd 0. Nothing outside the sandbox reads
//!   more of it than its first bytes (MP4/MOV `ftyp` or an old QuickTime
//!   atom, Matroska/WebM's EBML magic; else `unsupported-format`). A file
//!   over 2 GiB is reported from its size alone.
//!   - **video-probe** replies one line: `{"ok": true, "bytes",
//!     "container" ("mp4", "mov", "mkv", "webm"), "codec", "width",
//!     "height", "fps", "duration" (seconds or null), "violations" (any of
//!     `input-too-large`, `unsupported-codec`, `input-too-wide`), "output":
//!     {"width", "height", "fps", "seconds", "frames", "cut"}, "threads",
//!     "estimate" (seconds), "poster" (the first frame at the output size,
//!     `<cache>/video/<sha256 of the PNG>.png`, or null), "clip" and
//!     "clipBytes" (the clip already made for this content and output
//!     size, or null)}`. The facts and output are null when the size stops
//!     it before ffprobe; with any violation there is no poster or clip.
//!     60 s in all.
//!   - **video-convert** writes `{"progress": {"frames": n, "total": t}}`
//!     lines (frames stage A handed to stage B, at most every 200 ms), then
//!     `{"ok": true, "clip": "<cache>/video/<sha256 of the input>-<W>x<H>.mp4",
//!     "bytes", "frames", "output"}` (at once when that clip exists). One
//!     conversion at a time (`busy`); a violation fails with its own code.
//!     SIGTERM stops both stages and replies `cancelled`; 10 minutes in all
//!     (`job-timeout`). A failure leaves nothing behind: `decode-failed`
//!     (ffprobe or stage A did not exit 0), `invalid-frames` (no frame, a
//!     partial one, or more than 60 s of them), `encode-failed`,
//!     `output-too-large` (over 150 MiB), `source-changed` (the file
//!     changed while it was read).
//!   - Other codes: `video-missing`, `not-regular-file`,
//!     `decoder-unavailable` (no bwrap, ffmpeg or ffprobe),
//!     `sandbox-architecture-unsupported`, `decode-timeout`,
//!     `invalid-pixels`, `unsafe-cache`, `cache-busy`, `cancelled`,
//!     `job-timeout`, `parent-watch-failed`, `source-unavailable`,
//!     `helper-failed`. Exit status 0; stderr nothing.
//!   - **Cache**: `$XDG_CACHE_HOME/omarchy/foamy.lock/video/` (0700, this
//!     user's, else `unsafe-cache`): at most 3 clips (the oldest by mtime
//!     evicted, never the new one; a probe that finds one touches it) and 6
//!     posters, each 0600; `.convert` (held for a whole conversion) and
//!     `.lock` (held while publishing; waited for 2 s, else `cache-busy`).
//!     Jobs stage in `.job-XXXXXXXX` (reclaimed by the next conversion) or
//!     `.probe-XXXXXXXX` (after a minute).
//!   - **Sandbox**: ffprobe and ffmpeg in the image decoder's bubblewrap
//!     (without the input bind and ImageMagick's policy, with
//!     `GLIBC_TUNABLES=glibc.malloc.arena_max=1`) behind the kit's threaded
//!     decoder filter, one memfd per stage; `nice 19` and idle I/O, no core
//!     dumps, 64 fds, no files written, CPU seconds for the deadline;
//!     `min(cores - 2, 16)` threads. `video` has the command lines and the
//!     address-space formulas.
//! - **wallpaper**: `<link>` is an absolute path, normally
//!   `~/.local/state/omarchy/current/background`. It is resolved like
//!   `readlink -f` and must end at a regular file. No stdin, environment or
//!   files are used and nothing is written. stdout is exactly one JSON line,
//!   `{"ok": true, "path": "<absolute resolved path>", "signature":
//!   "<dev>:<inode>:<size>:<mtime>:<ctime>"}` (times as
//!   `<seconds>.<nanoseconds>`; the signature changes whenever the file's
//!   size, mtime or ctime do, or another file takes its place, and is stable
//!   while it doesn't) or `{"ok": false, "error": "<code>"}`: a dangling
//!   link, a missing file or component or a link loop `wallpaper-missing`,
//!   a directory or special file `not-regular-file`, a relative `<link>`
//!   `invalid-request`, a path that isn't UTF-8 `invalid-path`, any other
//!   error (such as a permission) `source-unavailable`. Exit status 0;
//!   stderr nothing. The caller bounds it with `timeout`.
//!
//! The rest of this contract is `artwork`'s (all three request kinds):
//!
//! - **stdin**: one JSON object on one line; the line, newline included, is
//!   at most 32768 bytes (more: `invalid-request`). Bytes after the first
//!   newline are ignored. Not JSON (or no input): `source-unavailable`; not
//!   an object: `invalid-request`.
//!   - artwork: `{"url": "<file:… or https:…>", "hosts": [...], "roots": [...]}`;
//!   - avatar: `{"kind": "avatar", "path": "/absolute/path"}`;
//!   - background: `{"kind": "background", "path": "/absolute/path",
//!     "width": W, "height": H, "blur": B}`.
//! - **stdout**: exactly one JSON line, `{"ok": true, "path": "<file>"}` or
//!   `{"ok": false, "error": "<code>"}`, also on cancel and timeout. A code
//!   never contains a URL, path or decoder message. Exit status 0 (101 only
//!   after a helper bug, with `{"ok":false,"error":"helper-failed"}`).
//!   **stderr**: nothing.
//! - **Codes**: `invalid-request`, `invalid-hosts`, `invalid-roots`,
//!   `invalid-url`, `invalid-file-url`, `invalid-https-url`,
//!   `unsupported-scheme`, `host-not-allowed`, `invalid-file-path`,
//!   `file-outside-roots`, `not-owned-regular-file`, `input-too-large`,
//!   `dns-failed`, `non-public-address`, `redirect-limit`, `http-error`,
//!   `encoded-response`, `fetch-timeout`, `https-unsupported` (CPU without
//!   the instructions the TLS library needs), `unsupported-format`,
//!   `animated-image`, `decoder-unavailable`,
//!   `sandbox-architecture-unsupported`, `decode-failed`, `decode-timeout`,
//!   `invalid-pixels`, `unsafe-cache`, `cache-busy`, `invalid-avatar-path`,
//!   `avatar-missing`, `invalid-background-path`, `background-missing`,
//!   `invalid-size`, `not-regular-file`, `cancelled`, `job-timeout`,
//!   `parent-watch-failed`, `timeout`, `source-unavailable`,
//!   `helper-failed`.
//! - **Options**: `hosts` at most 32 lowercase DNS names (at least two
//!   labels, the top one starting with a letter); `roots` at most 16
//!   absolute paths of at most 4096 characters, no NUL, not `/`, no `..`.
//! - **URLs**: printable ASCII, at most 8192 characters, no backslash, no
//!   credentials or fragment. `file:` without host, query or port; `https:`
//!   with a host in `hosts` and port 443 at most.
//! - **Local files** (`file:`): the percent-decoded path must lie under a
//!   root (normalised like `os.path.abspath`); opened by walking from the
//!   root with `O_NOFOLLOW` descriptors; a regular file owned by this user,
//!   at most 5 MiB (`MAX_INPUT`).
//! - **HTTPS**: 5 s for everything (DNS included); at most 3 hops (301, 302,
//!   303, 307, 308 with Location, joined like `urljoin`); each hop's host
//!   in `hosts`, all its addresses public (Python 3.14 `is_global`, no
//!   multicast, unspecified, IPv4-mapped, 6to4, Teredo or 64:ff9b::/96),
//!   the first one connected to on port 443 and TLS (rustls with Graviola,
//!   the system trust store, TLS 1.2/1.3) verified against the host name.
//!   The request is `GET` with exactly `Host`, `Accept:
//!   image/png,image/jpeg,image/webp`, `Accept-Encoding: identity`,
//!   `User-Agent: FoamyLock/1.0` and `Connection: close`; no proxy,
//!   cookies or credentials. Only 200 with identity encoding, at most
//!   `MAX_INPUT` bytes (Content-Length checked first).
//! - **Avatar**: the path may be a symlink or root-owned; a regular file of
//!   at most 16 MiB.
//! - **Background**: checked in this order: `width` and `height` integers
//!   from 16 to 7680 and 16 to 4320 (the screen in logical pixels; else
//!   `invalid-size`), `blur` a number from 0 to 1 (else `invalid-request`),
//!   `path` as for the avatar (absolute, at most 4096 characters, no NUL,
//!   else `invalid-background-path`; missing or dangling
//!   `background-missing`) but a regular file of at most 32 MiB. The
//!   output is exactly W x H, cover-scaled and centre-cropped (`-resize
//!   WxH^ -gravity center -extent WxH`, Qt's `PreserveAspectCrop`), alpha
//!   over `#171b26`. Blur 0 is none; otherwise a Gaussian of sigma
//!   `B x min(W, H) / 40` output pixels (27 px at 1 on a 1080-pixel-high
//!   screen), computed at a reduced scale `min(1/2, 2/sigma)` (sigma
//!   scaled alike) and scaled back with a triangle filter. A JPEG whose
//!   frame header shows both sides above max(W, H) is decoded with
//!   `jpeg:size=SxS`, S = max(W, H) (a DCT-scaled decode that still covers
//!   the screen in any orientation).
//! - **Decoder**: static PNG, JPEG and WebP only. `/usr/bin/magick` in
//!   `/usr/bin/bwrap` (see `image::command`: every namespace unshared,
//!   capabilities dropped, new session, read-only `/usr`, the private
//!   ImageMagick `policy.xml` (`image::POLICY`), the input as `/input`,
//!   `/` read-only, a seccomp filter in a memfd: on x86_64 `clone`, `fork`,
//!   `vfork`, `ptrace`, `mount`, `unshare`, `setns`, `bpf`, `clone3` fail
//!   with EPERM, any x32 syscall or foreign architecture kills the process;
//!   on aarch64 `mount`, `unshare`, `ptrace`, `clone`, `setns`, `bpf`,
//!   `clone3`). Limits: 256 MiB address space, 2 s CPU, files up to the
//!   pixel size, no core dumps, 64 fds, a 3 s deadline and exactly 196608
//!   bytes (256x256 RGB) of output. A background (P = W x H pixels) has
//!   768 MiB + 32 x P bytes of address space (1781 MiB at 7680x4320),
//!   2 s + 1 s per started 3840x2160 of P of CPU (3 to 6 s), that plus 1 s of
//!   deadline (4 to 7 s, inside the job's 9 s), files up to and exactly
//!   W x H x 3 bytes of output; its policy is `image::POLICY` with sources
//!   up to 16384 pixels a side and under 64 megapixels (`area`), memory
//!   128 MiB under the address space and `time` the CPU seconds
//!   (`Background::policy`). Environment `PATH=/usr/bin`; stdin
//!   /dev/null; an empty signal mask; no descriptor but the filter is
//!   inherited (all inherited descriptors are made close-on-exec at start).
//! - **Files**: `$XDG_CACHE_HOME` (unset or empty: `$HOME/.cache`)
//!   `/omarchy/foamy.lock/`: `artwork/` (0700, this user's, no group or
//!   other access, else `unsafe-cache`; lock `artwork/.lock`, `flock`
//!   without waiting, else `cache-busy`), thumbnails
//!   `artwork/<sha256 of the PNG>.png` (0600, at most 16 kept, newest by
//!   mtime), `avatar.png` (0600), `background/` (the same rules as
//!   `artwork/`: 0700, this user's, else `unsafe-cache`; lock
//!   `background/.lock`, else `cache-busy`) with backgrounds
//!   `background/<sha256 of the PNG>.png` (0600, at most 4 kept, newest by
//!   mtime). Jobs stage in `artwork/.job-XXXXXXXX`,
//!   `background/.job-XXXXXXXX` or `.avatar-XXXXXXXX` (0700, removed
//!   afterwards); abandoned `.job-*` directories are removed under their
//!   lock, `.avatar-*` ones after 60 s.
//! - **Lifetime**: `PR_SET_PDEATHSIG(SIGTERM)`; a parent that already left
//!   is `cancelled`. SIGTERM replies `cancelled`, SIGALRM or 9 s in total
//!   `job-timeout`; the job directory is removed and the decoder (which
//!   has `PR_SET_PDEATHSIG(SIGKILL)` and bubblewrap's `--die-with-parent`)
//!   dies with the helper.
//! - **Test-only overrides** (Quickshell clears the environment, so they
//!   never apply in the shell): `FOAMY_LOCK_TEST_RESOLVE` = JSON `{"host":
//!   ["address", …]}` replaces DNS (a host missing from it does not
//!   resolve); `FOAMY_LOCK_TEST_CONNECT` = JSON `{"address":
//!   "loopback-ip:port"}`: the connection to a checked address goes to that
//!   loopback endpoint (others are refused). The address checks still
//!   apply to the resolved addresses. The trust store follows
//!   `SSL_CERT_FILE`/`SSL_CERT_DIR` like OpenSSL.

use std::ffi::OsString;
use std::os::fd::{AsRawFd, OwnedFd};
use std::process::ExitCode;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use foamy_helper::json;
use serde_json::{Value, json};

mod fetch;
mod image;
mod store;
mod studio;
mod url;
mod video;
mod wallpaper;

#[cfg(test)]
pub mod forks;

pub const MAX_INPUT: usize = 5 * 1024 * 1024;
/// Account pictures are often camera photos, larger than track artwork.
pub const MAX_AVATAR_INPUT: usize = 16 * 1024 * 1024;
/// Lock-screen backgrounds: wallpapers and full-size photos.
pub const MAX_BACKGROUND_INPUT: usize = 32 * 1024 * 1024;
const MAX_REQUEST: usize = 32768;
const JOB_DEADLINE: Duration = Duration::from_secs(9);

/// A stable failure code (never a URL, path or decoder message).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fail(pub &'static str);

impl From<std::io::Error> for Fail {
    fn from(error: std::io::Error) -> Fail {
        // Python: TimeoutError is "timeout", any other OSError "source-unavailable".
        match error.kind() {
            std::io::ErrorKind::TimedOut => Fail("timeout"),
            _ => Fail("source-unavailable"),
        }
    }
}

impl From<rustix::io::Errno> for Fail {
    fn from(error: rustix::io::Errno) -> Fail {
        std::io::Error::from(error).into()
    }
}

/// What the cancel thread needs: whether the reply is on its way, and the
/// job directory to remove.
pub struct State {
    done: bool,
    staging: Option<std::path::PathBuf>,
}

static STATE: Mutex<State> = Mutex::new(State {
    done: false,
    staging: None,
});

pub fn state() -> MutexGuard<'static, State> {
    STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn failure(code: &str) -> Value {
    json!({"ok": false, "error": code})
}

/// Replies `code` and exits, unless the job's own reply is under way.
fn cancel(code: &str) {
    let mut guard = state();
    if guard.done {
        return;
    }
    guard.done = true;
    if let Some(path) = guard.staging.take() {
        let _ = std::fs::remove_dir_all(path);
    }
    let _ = json::print_line(&failure(code));
    // The decoder has PR_SET_PDEATHSIG(SIGKILL); bubblewrap then kills its sandbox.
    std::process::exit(0);
}

/// The write end of the signal pipe (-1 before `install_signals`).
static WAKE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(signal: libc::c_int) {
    // SAFETY: only async-signal-safe calls: errno is saved and restored
    // around one write(2) of a byte to a non-blocking pipe.
    unsafe {
        let errno = *libc::__errno_location();
        let byte = signal as u8;
        libc::write(WAKE.load(Ordering::Relaxed), (&byte as *const u8).cast(), 1);
        *libc::__errno_location() = errno;
    }
}

fn signal_set() -> libc::sigset_t {
    // SAFETY: sigemptyset/sigaddset initialise and fill a local sigset_t.
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGALRM);
        set
    }
}

fn mask(how: libc::c_int) -> bool {
    let set = signal_set();
    // SAFETY: pthread_sigmask with a valid set and no old-set pointer.
    unsafe { libc::pthread_sigmask(how, &set, std::ptr::null_mut()) == 0 }
}

/// SIGTERM and SIGALRM write their number to a pipe that the cancel thread
/// reads. They stay blocked in every other thread (so no blocking call of
/// the job sees EINTR), except around the decoder's start: a child inherits
/// the signal mask of the thread that forks it, and the decoder must start
/// with an empty one (as Python's child did). Returns the pipe's read end.
fn install_signals() -> Option<OwnedFd> {
    let (read, write) = rustix::pipe::pipe_with(
        rustix::pipe::PipeFlags::CLOEXEC | rustix::pipe::PipeFlags::NONBLOCK,
    )
    .ok()?;
    WAKE.store(write.as_raw_fd(), Ordering::Relaxed);
    std::mem::forget(write); // lives as long as the process
    for signal in [libc::SIGTERM, libc::SIGALRM] {
        // SAFETY: a zeroed sigaction with our handler, a full mask while it
        // runs and SA_RESTART; the old action is not needed.
        let installed = unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_signal as *const () as libc::sighandler_t;
            libc::sigfillset(&mut action.sa_mask);
            action.sa_flags = libc::SA_RESTART;
            libc::sigaction(signal, &action, std::ptr::null_mut()) == 0
        };
        if !installed {
            return None;
        }
    }
    mask(libc::SIG_BLOCK).then_some(read)
}

/// Runs `f` (the decoder's spawn and wait) with SIGTERM and SIGALRM
/// unblocked in this thread, so the child starts with an empty mask.
pub fn signals_unblocked<T>(f: impl FnOnce() -> T) -> T {
    mask(libc::SIG_UNBLOCK);
    let result = f();
    mask(libc::SIG_BLOCK);
    result
}

/// How the cancel thread ends a job.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stop {
    /// Replies at once and exits; the decoder dies with the helper.
    Hard,
    /// SIGTERM asks the job to stop its children and reply `cancelled`
    /// itself (`video::CANCEL`); after `SOFT_GRACE` it is stopped hard.
    Soft,
}

const SOFT_GRACE: Duration = Duration::from_secs(3);

/// The cancel thread: SIGTERM is `cancelled`, SIGALRM or the job deadline
/// `job-timeout`.
fn watch(started: Instant, deadline: Duration, stop: Stop, wake: OwnedFd) {
    mask(libc::SIG_UNBLOCK);
    let mut cancelling: Option<Instant> = None;
    loop {
        let mut until = started + deadline;
        if let Some(asked) = cancelling {
            if state().done {
                return;
            }
            until = until.min(asked + SOFT_GRACE);
            if Instant::now() >= asked + SOFT_GRACE {
                cancel("cancelled");
                return;
            }
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() && cancelling.is_none() {
            cancel("job-timeout");
            return;
        }
        let mut poll = libc::pollfd {
            fd: wake.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let milliseconds = left.as_millis().clamp(1, 100) as libc::c_int;
        // SAFETY: poll(2) on one valid pollfd.
        if unsafe { libc::poll(&mut poll, 1, milliseconds) } <= 0 {
            continue; // timeout or EINTR: the loop checks the deadline
        }
        let mut byte = [0u8; 1];
        // SAFETY: read(2) of one byte into a local buffer from our pipe.
        if unsafe { libc::read(wake.as_raw_fd(), byte.as_mut_ptr().cast(), 1) } == 1 {
            match (byte[0] as libc::c_int, stop) {
                (libc::SIGTERM, Stop::Soft) => {
                    video::CANCEL.store(true, Ordering::Relaxed);
                    cancelling.get_or_insert_with(Instant::now);
                }
                (libc::SIGTERM, Stop::Hard) => cancel("cancelled"),
                _ => cancel("job-timeout"),
            }
        }
    }
}

/// Marks every descriptor above stderr close-on-exec, so nothing the shell
/// leaked reaches bubblewrap or the decoder (Python's `close_fds=True`).
pub(crate) fn cloexec_inherited() {
    const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
    // SAFETY: close_range(2) with integer arguments only.
    let done = unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3 as libc::c_uint,
            libc::c_uint::MAX,
            CLOSE_RANGE_CLOEXEC,
        )
    } == 0;
    if done {
        return;
    }
    let Ok(entries) = std::fs::read_dir("/proc/self/fd") else {
        return;
    };
    let fds: Vec<i32> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .filter(|&fd| fd > 2)
        .collect();
    for fd in fds {
        // SAFETY: fcntl on a descriptor number; a closed one is EBADF.
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags >= 0 {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }
}

/// One request line: up to and including the first newline, at most
/// `MAX_REQUEST` bytes.
fn read_request() -> Result<Value, Fail> {
    use std::io::Read;
    let mut line = Vec::new();
    let mut stdin = std::io::stdin().lock();
    let mut byte = [0u8; 4096];
    loop {
        let read = match stdin.read(&mut byte[..(MAX_REQUEST + 1 - line.len()).min(4096)]) {
            Ok(read) => read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        };
        if read == 0 {
            break;
        }
        let chunk = &byte[..read];
        if let Some(end) = chunk.iter().position(|&b| b == b'\n') {
            line.extend_from_slice(&chunk[..=end]);
            break;
        }
        line.extend_from_slice(chunk);
        if line.len() > MAX_REQUEST {
            break;
        }
    }
    if line.len() > MAX_REQUEST {
        return Err(Fail("invalid-request"));
    }
    serde_json::from_slice(&line).map_err(|_| Fail("source-unavailable"))
}

/// The request object on stdin.
fn request_object() -> Result<serde_json::Map<String, Value>, Fail> {
    match read_request()? {
        Value::Object(request) => Ok(request),
        _ => Err(Fail("invalid-request")),
    }
}

fn job() -> Result<Value, Fail> {
    let request = request_object()?;
    match request.get("kind").and_then(Value::as_str) {
        Some("avatar") => store::prepare_avatar(&request),
        Some("background") => store::prepare_background(&request),
        _ => store::prepare(&request),
    }
}

/// Runs `job` under the cancel thread (`deadline`, `stop`), dying with
/// the parent; its reply, or the failure as one.
fn supervised(
    deadline: Duration,
    stop: Stop,
    job: impl FnOnce(Instant) -> Result<Value, Fail>,
) -> Value {
    let started = Instant::now();
    cloexec_inherited();
    let Some(wake) = install_signals() else {
        return failure("helper-failed");
    };
    // Quickshell may be killed or reloaded during a job: the helper hears
    // about its parent's death and cancels.
    let parent = rustix::process::getppid();
    if rustix::process::set_parent_process_death_signal(Some(rustix::process::Signal::TERM))
        .is_err()
    {
        return failure("parent-watch-failed");
    }
    thread::spawn(move || watch(started, deadline, stop, wake));
    let result = match parent {
        Some(pid) if rustix::process::getppid() == Some(pid) && pid.as_raw_nonzero().get() != 1 => {
            job(started)
        }
        _ => Err(Fail("cancelled")),
    };
    state().done = true;
    match result {
        Ok(value) => value,
        Err(Fail(code)) => failure(code),
    }
}

fn artwork() -> Value {
    supervised(JOB_DEADLINE, Stop::Hard, |_| job())
}

/// `video-probe`: hashing, ffprobe and the poster within a minute.
fn video_probe() -> Value {
    supervised(video::PROBE_DEADLINE, Stop::Hard, |_| {
        video::probe(&request_object()?)
    })
}

/// `video-convert`: the stages have the 10 minutes (less what came
/// before); the cancel thread stops the helper 10 s after that.
fn video_convert() -> Value {
    supervised(
        video::CONVERT_DEADLINE + Duration::from_secs(10),
        Stop::Soft,
        |started| video::convert(&request_object()?, started),
    )
}
fn main() -> ExitCode {
    // Lock Studio: its own replies (`json::error_reply`) and no sandbox.
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    if args.first().is_some_and(|arg| arg == "studio") {
        return json::run(|| studio::main(&args[1..]), json::error_reply);
    }
    // A reply on every path, even a helper bug (then exit 101, no core dump).
    json::run(
        || -> Result<Value, foamy_helper::Failure> {
            match (args.first().and_then(|a| a.to_str()), args.len()) {
                (Some("artwork"), 1) => Ok(artwork()),
                (Some("wallpaper"), 2) => Ok(wallpaper::probe(&args[1])),
                (Some("video-probe"), 1) => Ok(video_probe()),
                (Some("video-convert"), 1) => Ok(video_convert()),
                _ => Ok(failure("invalid-request")),
            }
        },
        |_| failure("helper-failed"),
    )
}
