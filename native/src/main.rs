//! `foamy-lock-helper`: bounded lock-screen artwork and the account avatar
//! thumbnail. Replaces `artwork.py`; carries over every bound on purpose.
//! Original images never enter the shell: both go through the same
//! sandboxed decoder and come back as a freshly encoded 256x256 PNG.
//!
//! # Contract
//!
//! - **argv**: `foamy-lock-helper artwork`. Anything else replies
//!   `invalid-request`.
//! - **stdin**: one JSON object on one line; the line, newline included, is
//!   at most 32768 bytes (more: `invalid-request`). Bytes after the first
//!   newline are ignored. Not JSON (or no input): `source-unavailable`; not
//!   an object: `invalid-request`.
//!   - artwork: `{"url": "<file:… or https:…>", "hosts": [...], "roots": [...]}`;
//!   - avatar: `{"kind": "avatar", "path": "/absolute/path"}`.
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
//!   `avatar-missing`, `not-regular-file`, `cancelled`, `job-timeout`,
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
//!   bytes (256x256 RGB) of output. Environment `PATH=/usr/bin`; stdin
//!   /dev/null; an empty signal mask; no descriptor but the filter is
//!   inherited (all inherited descriptors are made close-on-exec at start).
//! - **Files**: `$XDG_CACHE_HOME` (unset or empty: `$HOME/.cache`)
//!   `/omarchy/foamy.lock/`: `artwork/` (0700, this user's, no group or
//!   other access, else `unsafe-cache`; lock `artwork/.lock`, `flock`
//!   without waiting, else `cache-busy`), thumbnails
//!   `artwork/<sha256 of the PNG>.png` (0600, at most 16 kept, newest by
//!   mtime), `avatar.png` (0600). Jobs stage in `artwork/.job-XXXXXXXX` or
//!   `.avatar-XXXXXXXX` (0700, removed afterwards); abandoned `.job-*`
//!   directories are removed under the lock, `.avatar-*` ones after 60 s.
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

use std::ffi::OsStr;
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
mod url;

pub const MAX_INPUT: usize = 5 * 1024 * 1024;
/// Account pictures are often camera photos, larger than track artwork.
pub const MAX_AVATAR_INPUT: usize = 16 * 1024 * 1024;
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

/// The cancel thread: SIGTERM is `cancelled`, SIGALRM or the job deadline
/// `job-timeout`.
fn watch(started: Instant, wake: OwnedFd) {
    mask(libc::SIG_UNBLOCK);
    loop {
        let left = (started + JOB_DEADLINE).saturating_duration_since(Instant::now());
        if left.is_zero() {
            cancel("job-timeout");
            return;
        }
        let mut poll = libc::pollfd {
            fd: wake.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let milliseconds = left.as_millis().clamp(1, i32::MAX as u128) as libc::c_int;
        // SAFETY: poll(2) on one valid pollfd.
        if unsafe { libc::poll(&mut poll, 1, milliseconds) } <= 0 {
            continue; // timeout or EINTR: the loop checks the deadline
        }
        let mut byte = [0u8; 1];
        // SAFETY: read(2) of one byte into a local buffer from our pipe.
        if unsafe { libc::read(wake.as_raw_fd(), byte.as_mut_ptr().cast(), 1) } == 1 {
            match byte[0] as libc::c_int {
                libc::SIGTERM => cancel("cancelled"),
                _ => cancel("job-timeout"),
            }
        }
    }
}

/// Marks every descriptor above stderr close-on-exec, so nothing the shell
/// leaked reaches bubblewrap or the decoder (Python's `close_fds=True`).
fn cloexec_inherited() {
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

fn job() -> Result<Value, Fail> {
    let request = read_request()?;
    let Value::Object(request) = request else {
        return Err(Fail("invalid-request"));
    };
    if request.get("kind").and_then(Value::as_str) == Some("avatar") {
        store::prepare_avatar(&request)
    } else {
        store::prepare(&request)
    }
}

fn artwork() -> Value {
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
    thread::spawn(move || watch(started, wake));
    let result = match parent {
        Some(pid) if rustix::process::getppid() == Some(pid) && pid.as_raw_nonzero().get() != 1 => {
            job()
        }
        _ => Err(Fail("cancelled")),
    };
    state().done = true;
    match result {
        Ok(value) => value,
        Err(Fail(code)) => failure(code),
    }
}

fn main() -> ExitCode {
    // A reply on every path, even a helper bug (then exit 101, no core dump).
    json::run(
        || -> Result<Value, foamy_helper::Failure> {
            match std::env::args_os()
                .nth(1)
                .as_deref()
                .and_then(OsStr::to_str)
            {
                Some("artwork") if std::env::args_os().count() == 2 => Ok(artwork()),
                _ => Ok(failure("invalid-request")),
            }
        },
        |_| failure("helper-failed"),
    )
}
