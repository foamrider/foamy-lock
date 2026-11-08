//! Video wallpapers: `video-probe` and `video-convert` (see the contract in
//! `main.rs`). The user's file is only ever parsed inside the sandbox, and
//! the clip the lock plays comes from a process that never read it:
//!
//! - **Stage A** (the probe's ffprobe and poster, the conversion's decoder):
//!   ffmpeg in bubblewrap behind the kit's threaded decoder filter, the file
//!   handed over as fd 0 (`-fd 0 -i fd:`, opened and checked here), the
//!   demuxer forced from the file's first bytes (MP4/MOV or Matroska/WebM),
//!   decoders limited to H.264, HEVC, VP8, VP9 and AV1, raw frames out.
//! - **Stage B** (the conversion's encoder): ffmpeg in its own sandbox,
//!   reading only stage A's raw frames from a pipe and writing a fragmented
//!   MP4 (H.264 High, yuv420p, no audio or metadata) to another.
//!
//! Both run at idle priority (`nice 19`, the idle I/O class) with
//! `min(cores - 2, 16)` threads, under rlimits and deadlines; the helper
//! counts the frames between them, so a conversion reports its progress
//! and is accepted only after stage A exited 0 with a whole number of
//! frames (at least one, at most the 60 s cut) and stage B exited 0 with
//! an MP4 of at most 150 MiB. Clips are kept in the helper's cache, named by
//! the input's SHA-256 and the output size, at most three; posters (the
//! first frame at the output size, encoded by `image::encode_rgb`) beside
//! them, at most six.

use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, ErrorKind, Read};
use std::ops::ControlFlow;
use std::os::fd::OwnedFd;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use foamy_helper::child::{Bounded, Output};
use foamy_helper::json;
use foamy_helper::lock::FileLock;
use foamy_helper::process::Resource;
use foamy_helper::sandbox::{BpfFilter, Bwrap};
use rustix::fs::{FileType, Mode, OFlags};
use rustix::process::getuid;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::store::{self, Staging};
use crate::{Fail, image, state};

/// Inputs above 2 GiB are refused (the probe still says how large).
pub const MAX_INPUT: u64 = 2 << 30;
/// Sources up to 8K UHD, either way round.
pub const MAX_SOURCE_LONG: u32 = 7680;
pub const MAX_SOURCE_SHORT: u32 = 4320;
/// The screen's native size, as for a background picture.
pub const MIN_SIDE: u64 = 16;
pub const MAX_WIDTH: u64 = 7680;
pub const MAX_HEIGHT: u64 = 4320;
/// The output fits in 3840x2160.
pub const MAX_OUT_WIDTH: u32 = 3840;
pub const MAX_OUT_HEIGHT: u32 = 2160;
/// The first 60 s are used.
pub const MAX_SECONDS: u32 = 60;
/// At most 30 frames a second; slower sources keep their rate.
pub const MAX_FPS: u32 = 30;
/// The clip, as written by stage B.
pub const MAX_CLIP: usize = 150 << 20;
/// Bits per second: 0.1 bit per pixel at 30 fps, at most what keeps 60 s
/// (and a full VBV buffer) under `MAX_CLIP`.
const MAX_BITRATE: u64 = 19_000_000;
pub const MAX_CLIPS: usize = 3;
pub const MAX_POSTERS: usize = 6;
pub const MAX_THREADS: usize = 16;
pub const CONVERT_DEADLINE: Duration = Duration::from_secs(600);
/// The probe: hashing up to 2 GiB, then ffprobe and the poster.
pub const PROBE_DEADLINE: Duration = Duration::from_secs(60);
const FFPROBE_DEADLINE: Duration = Duration::from_secs(10);
const POSTER_DEADLINE: Duration = Duration::from_secs(15);
const FFPROBE_OUTPUT: usize = 64 * 1024;
/// stderr of a stage (`-v error`).
const STAGE_LOG: usize = 1 << 20;
pub const CODECS: [&str; 5] = ["h264", "hevc", "vp8", "vp9", "av1"];
/// The decoders ffmpeg picks for those codecs (AV1: dav1d first).
const DECODERS: &str = "h264,hevc,vp8,vp9,av1,libdav1d";
const MIB: u64 = 1024 * 1024;

const BWRAP: &str = "/usr/bin/bwrap";
const FFMPEG: &str = "/usr/bin/ffmpeg";
const FFPROBE: &str = "/usr/bin/ffprobe";

/// Set by the cancel thread on SIGTERM; the conversion stops both stages.
pub static CANCEL: AtomicBool = AtomicBool::new(false);

/// A request: the file and the largest screen's native size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub path: String,
    pub width: u32,
    pub height: u32,
}

impl Request {
    /// `width` and `height` integers in 16..=7680 and 16..=4320 (else
    /// `invalid-size`), then `path` absolute, at most 4096 characters,
    /// without NUL (else `invalid-video-path`).
    pub fn parse(request: &Map<String, Value>) -> Result<Request, Fail> {
        let side = |key: &str, max: u64| {
            request
                .get(key)
                .and_then(Value::as_u64)
                .filter(|side| (MIN_SIDE..=max).contains(side))
                .map(|side| side as u32)
                .ok_or(Fail("invalid-size"))
        };
        let width = side("width", MAX_WIDTH)?;
        let height = side("height", MAX_HEIGHT)?;
        let path = match request.get("path") {
            Some(Value::String(path))
                if path.starts_with('/')
                    && path.chars().count() <= 4096
                    && !path.contains('\0') =>
            {
                path.clone()
            }
            _ => return Err(Fail("invalid-video-path")),
        };
        Ok(Request {
            path,
            width,
            height,
        })
    }

    /// The clip's size: the screen scaled down to fit 3840x2160, both sides
    /// even (yuv420p) and at least 16.
    pub fn output(&self) -> (u32, u32) {
        output_size(self.width, self.height)
    }
}

pub fn output_size(width: u32, height: u32) -> (u32, u32) {
    let scale = (MAX_OUT_WIDTH as f64 / width as f64)
        .min(MAX_OUT_HEIGHT as f64 / height as f64)
        .min(1.0);
    let even = |side: u32| (((side as f64 * scale) / 2.0).floor() as u32 * 2).max(16);
    (even(width), even(height))
}

/// The container, from the file's first bytes: the demuxer stage A is
/// forced to, and the name shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Container {
    pub demuxer: &'static str,
    pub name: &'static str,
}

/// MP4/MOV (an `ftyp` box, or an old QuickTime file's first atom) or
/// Matroska/WebM (the EBML magic; WebM by its doctype).
pub fn sniff(head: &[u8]) -> Option<Container> {
    let atom = head.get(4..8)?;
    if atom == b"ftyp" {
        let brand = head.get(8..12)?;
        let name = if brand == b"qt  " { "mov" } else { "mp4" };
        return Some(Container {
            demuxer: "mov",
            name,
        });
    }
    if [b"moov", b"mdat", b"wide", b"free", b"skip", b"pnot"]
        .iter()
        .any(|kind| atom == *kind)
    {
        return Some(Container {
            demuxer: "mov",
            name: "mov",
        });
    }
    if head.starts_with(b"\x1a\x45\xdf\xa3") {
        let webm = head
            .iter()
            .take(64)
            .collect::<Vec<_>>()
            .windows(6)
            .any(|w| *w[0] == 0x42 && *w[1] == 0x82 && w[3..6] == [&b'w', &b'e', &b'b']);
        return Some(Container {
            demuxer: "matroska",
            name: if webm { "webm" } else { "mkv" },
        });
    }
    None
}

/// What ffprobe said about the first video stream that isn't cover art.
#[derive(Debug, Clone, PartialEq)]
pub struct Facts {
    pub codec: String,
    pub width: u32,
    pub height: u32,
    /// Frames per second as a fraction.
    pub fps: (u32, u32),
    /// Seconds, when the file says.
    pub duration: Option<f64>,
}

fn rational(value: Option<&Value>) -> Option<(u32, u32)> {
    let (num, den) = value?.as_str()?.split_once('/')?;
    let (num, den): (u32, u32) = (num.parse().ok()?, den.parse().ok()?);
    (num > 0
        && den > 0
        && num <= 1_000_000
        && den <= 1_000_000
        && num as f64 / den as f64 <= 1000.0)
        .then_some((num, den))
}

fn seconds(value: Option<&Value>) -> Option<f64> {
    let seconds: f64 = value?.as_str()?.parse().ok()?;
    (seconds.is_finite() && seconds > 0.0 && seconds < 1e7).then_some(seconds)
}

/// ffprobe's JSON (`-show_entries format=duration:stream=…`), read
/// strictly: it came out of the sandbox. `Err(no-video)` without a video
/// stream, `decode-failed` for anything malformed.
pub fn facts(output: &[u8]) -> Result<Facts, Fail> {
    let data: Value = serde_json::from_slice(output).map_err(|_| Fail("decode-failed"))?;
    let streams = data
        .get("streams")
        .and_then(Value::as_array)
        .ok_or(Fail("decode-failed"))?;
    let Some(stream) = streams.first() else {
        return Err(Fail("no-video"));
    };
    let codec = stream
        .get("codec_name")
        .and_then(Value::as_str)
        .filter(|c| {
            !c.is_empty()
                && c.len() <= 32
                && c.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        })
        .ok_or(Fail("decode-failed"))?
        .to_string();
    let side = |key: &str| {
        stream
            .get(key)
            .and_then(Value::as_u64)
            .filter(|side| (1..=65535).contains(side))
            .map(|side| side as u32)
            .ok_or(Fail("decode-failed"))
    };
    let (width, height) = (side("width")?, side("height")?);
    let fps = rational(stream.get("avg_frame_rate"))
        .or_else(|| rational(stream.get("r_frame_rate")))
        .unwrap_or((MAX_FPS, 1));
    let duration = data
        .get("format")
        .and_then(|format| seconds(format.get("duration")))
        .or_else(|| seconds(stream.get("duration")));
    Ok(Facts {
        codec,
        width,
        height,
        fps,
        duration,
    })
}

/// What the conversion makes of a source.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Plan {
    pub width: u32,
    pub height: u32,
    /// Frames per second as a fraction: the source's, at most 30 (and at
    /// least 1).
    pub fps: (u32, u32),
    /// The most frames stage A may write: 60 s of them.
    pub cap: u64,
    /// The frames expected (the cap when the length is unknown).
    pub total: u64,
    /// Seconds used.
    pub seconds: f64,
    /// Longer than 60 s: only the first 60 s are used.
    pub cut: bool,
}

impl Plan {
    pub fn new(facts: &Facts, (width, height): (u32, u32)) -> Plan {
        let source = facts.fps.0 as f64 / facts.fps.1 as f64;
        let fps = if source > MAX_FPS as f64 {
            (MAX_FPS, 1)
        } else if source < 1.0 {
            (1, 1)
        } else {
            facts.fps
        };
        let rate = fps.0 as f64 / fps.1 as f64;
        let cap = ((MAX_SECONDS as f64 * rate).floor() as u64).max(1);
        let cut = facts.duration.is_some_and(|d| d > MAX_SECONDS as f64);
        let seconds = facts
            .duration
            .map_or(MAX_SECONDS as f64, |d| d.min(MAX_SECONDS as f64));
        let total = facts
            .duration
            .map_or(cap, |d| ((d * rate).round() as u64).clamp(1, cap));
        Plan {
            width,
            height,
            fps,
            cap,
            total,
            seconds,
            cut,
        }
    }

    pub fn pixels(&self) -> u64 {
        self.width as u64 * self.height as u64
    }

    /// One yuv420p frame between the stages.
    pub fn frame_bytes(&self) -> u64 {
        self.pixels() * 3 / 2
    }

    fn rate(&self) -> String {
        format!("{}/{}", self.fps.0, self.fps.1)
    }

    pub fn fps_value(&self) -> f64 {
        self.fps.0 as f64 / self.fps.1 as f64
    }

    /// Bits per second for stage B's rate control.
    pub fn bitrate(&self) -> u64 {
        (self.pixels() * 3).min(MAX_BITRATE)
    }

    fn reply(&self) -> Value {
        json!({
            "width": self.width,
            "height": self.height,
            "fps": (self.fps_value() * 1000.0).round() / 1000.0,
            "seconds": (self.seconds * 1000.0).round() / 1000.0,
            "frames": self.total,
            "cut": self.cut,
        })
    }
}

/// The limits the file breaks, in the order the card names them.
pub fn violations(bytes: u64, facts: Option<&Facts>) -> Vec<&'static str> {
    let mut out = Vec::new();
    if bytes > MAX_INPUT {
        out.push("input-too-large");
    }
    if let Some(facts) = facts {
        if !CODECS.contains(&facts.codec.as_str()) {
            out.push("unsupported-codec");
        }
        let (long, short) = (facts.width.max(facts.height), facts.width.min(facts.height));
        if long > MAX_SOURCE_LONG || short > MAX_SOURCE_SHORT {
            out.push("input-too-wide");
        }
    }
    out
}

/// `min(cores - 2, 16)`, at least 1.
pub fn threads() -> usize {
    let cores = std::thread::available_parallelism().map_or(1, |n| n.get());
    cores.saturating_sub(2).clamp(1, MAX_THREADS)
}

fn source_pixels(facts: &Facts) -> u64 {
    facts.width as u64 * facts.height as u64
}

/// Seconds a conversion should take here. The stages run side by side,
/// so the slower one sets the pace: x264 at about 45 megapixels a second
/// per thread, the decoder at about 210 (HEVC; H.264 and VP8 are lighter,
/// VP9 and AV1 heavier) over every source frame of the part used. Measured
/// on a 20-thread machine with 16 (docs/plans/lock-video-wallpapers.md).
pub fn estimate(facts: &Facts, plan: &Plan, threads: usize) -> u64 {
    let threads = threads.max(1) as f64;
    let encode = plan.pixels() as f64 * plan.total as f64 / (threads * 45e6);
    let weight = match facts.codec.as_str() {
        "h264" => 0.6,
        "vp8" => 0.8,
        "vp9" => 1.2,
        "av1" => 1.5,
        _ => 1.0,
    };
    let rate = facts.fps.0 as f64 / facts.fps.1 as f64;
    let decoded = source_pixels(facts) as f64 * rate * plan.seconds;
    let decode = weight * decoded / (threads * 210e6);
    (encode.max(decode) + 1.0).ceil() as u64
}

/// Decoder threads: all of them up to a 3840x2160 source, fewer above (each
/// frame thread holds its own frames), at least 2.
pub fn decode_threads(facts: &Facts, threads: usize) -> usize {
    let share = threads as u64 * (3840 * 2160) / source_pixels(facts).max(1);
    (share as usize).clamp(2.min(threads), threads)
}

/// Stage A's `RLIMIT_AS`: 768 MiB, 32 MiB per thread (a stack and its
/// share of the pipeline), 4 bytes per source pixel per decoder thread and
/// 32 per output pixel. Measured peaks with 16 threads (from a 3840x2160
/// HEVC source): 1502 MiB at 1920x1080, 1584 at 3440x1440, 1526 at
/// 3840x2160, each about 20 % under this.
pub fn decoder_space(plan: &Plan, facts: &Facts, threads: usize) -> u64 {
    let decoders = decode_threads(facts, threads) as u64;
    768 * MIB + 32 * MIB * threads as u64 + 4 * source_pixels(facts) * decoders + 32 * plan.pixels()
}

/// Stage B's: 768 MiB, 32 MiB per thread, and 12 bytes per output pixel
/// for each frame x264 holds (one per thread and about 12 more for the
/// lookahead and references). Measured peaks with 16 threads: 1492 MiB at
/// 1920x1080, 2314 at 3440x1440, 3194 at 3840x2160, 23 to 30 % under this.
pub fn encoder_space(plan: &Plan, threads: usize) -> u64 {
    768 * MIB + 32 * MIB * threads as u64 + 12 * plan.pixels() * (threads as u64 + 12)
}

// --- the sandbox ----------------------------------------------------------

/// image.rs's bubblewrap command line without ImageMagick: every namespace
/// unshared, all capabilities dropped, a new session, dying with the
/// helper, read-only /usr, fresh /proc and /dev, an empty /etc, an empty
/// environment but PATH, HOME and glibc's one malloc arena (so threads
/// don't reserve address space each), / read-only, and the stage's own
/// seccomp filter (one memfd per stage: bubblewrap reads it from the
/// shared offset).
fn sandbox(filter: &OwnedFd) -> Bwrap {
    Bwrap::new(BWRAP)
        .unshare_all()
        .die_with_parent()
        .new_session()
        .cap_drop("ALL")
        .ro_bind("/usr", "/usr")
        .symlink("usr/lib", "/lib")
        .symlink("usr/lib", "/lib64")
        .symlink("usr/bin", "/bin")
        .proc("/proc")
        .dev("/dev")
        .dir("/etc")
        .chdir("/")
        .clearenv()
        .setenv("PATH", "/usr/bin")
        .setenv("HOME", "/nonexistent")
        .setenv("GLIBC_TUNABLES", "glibc.malloc.arena_max=1")
        .remount_ro("/")
        .seccomp(filter)
}

fn filter() -> Result<OwnedFd, Fail> {
    let filter = BpfFilter::threaded_decoder().map_err(|error| match error.kind() {
        ErrorKind::Unsupported => Fail("sandbox-architecture-unsupported"),
        _ => Fail("source-unavailable"),
    })?;
    Ok(filter.memfd()?)
}

fn args(list: &[&str]) -> Vec<OsString> {
    list.iter().map(OsString::from).collect()
}

/// The options every stage-A run starts with: no interaction, errors only,
/// the file as fd 0 and nothing else, the demuxer forced and only the
/// video decoders allowed.
fn input(demuxer: &str, threads: usize) -> Vec<OsString> {
    let threads = threads.to_string();
    args(&[
        "-nostdin",
        "-hide_banner",
        "-v",
        "error",
        "-protocol_whitelist",
        "fd",
        "-format_whitelist",
        "mov,matroska",
        "-codec_whitelist",
        DECODERS,
        "-threads",
        &threads,
        "-fd",
        "0",
        "-f",
        demuxer,
        "-i",
        "fd:",
    ])
}

/// ffprobe on the first video stream that isn't cover art. It opens every
/// stream's decoder (a codec list would make it refuse a file with audio),
/// inside the same sandbox; nothing it says is trusted beyond the numbers
/// the conversion checks again.
pub fn probe_argv(demuxer: &str) -> Vec<OsString> {
    let mut argv = args(&[
        FFPROBE,
        "-hide_banner",
        "-v",
        "error",
        "-protocol_whitelist",
        "fd",
        "-format_whitelist",
        "mov,matroska",
        "-threads",
        "1",
        "-fd",
        "0",
        "-f",
        demuxer,
        "-select_streams",
        "V:0",
        "-of",
        "json=c=1",
        "-show_entries",
        "format=duration:stream=codec_name,width,height,avg_frame_rate,r_frame_rate,duration",
    ]);
    argv.extend(args(&["-i", "fd:"]));
    argv
}

/// Cover-scaled and centre-cropped to the output, as a picture background.
fn fit(plan: &Plan) -> String {
    let (w, h) = (plan.width, plan.height);
    format!(
        "scale={w}:{h}:force_original_aspect_ratio=increase:flags=bicubic,crop={w}:{h},setsar=1"
    )
}

/// The first frame at the output size, as RGB.
pub fn poster_argv(demuxer: &str, plan: &Plan) -> Vec<OsString> {
    let mut argv = args(&[FFMPEG]);
    argv.extend(input(demuxer, 2));
    argv.extend(args(&[
        "-map",
        "0:V:0",
        "-an",
        "-sn",
        "-dn",
        "-frames:v",
        "1",
        "-vf",
        &fit(plan),
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "pipe:1",
    ]));
    argv
}

/// Stage A: the first 60 s as raw yuv420p frames at the output size and
/// rate, no audio, subtitles, data, metadata or chapters.
pub fn decode_argv(demuxer: &str, plan: &Plan, threads: usize, decoders: usize) -> Vec<OsString> {
    let mut argv = args(&[FFMPEG, "-filter_threads", &threads.to_string()]);
    argv.extend(input(demuxer, decoders));
    let filters = format!("fps={},{},format=yuv420p", plan.rate(), fit(plan));
    argv.extend(args(&[
        "-map",
        "0:V:0",
        "-an",
        "-sn",
        "-dn",
        "-map_metadata",
        "-1",
        "-map_chapters",
        "-1",
        "-t",
        &MAX_SECONDS.to_string(),
        "-vf",
        &filters,
        "-frames:v",
        &plan.cap.to_string(),
        "-f",
        "rawvideo",
        "-pix_fmt",
        "yuv420p",
        "pipe:1",
    ]));
    argv
}

/// Stage B: raw frames in, H.264 High in a fragmented MP4 out (written to
/// a pipe), CRF 23 under the bitrate cap, a key frame every 2 s, no SEI,
/// metadata or encoder tags.
pub fn encode_argv(plan: &Plan, threads: usize) -> Vec<OsString> {
    let size = format!("{}x{}", plan.width, plan.height);
    let rate = plan.bitrate();
    let gop = ((plan.fps_value() * 2.0).round() as u64).max(1);
    args(&[
        FFMPEG,
        "-nostdin",
        "-hide_banner",
        "-v",
        "error",
        "-protocol_whitelist",
        "pipe",
        "-format_whitelist",
        "rawvideo",
        "-codec_whitelist",
        "rawvideo",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "yuv420p",
        "-video_size",
        &size,
        "-framerate",
        &plan.rate(),
        "-i",
        "pipe:0",
        "-frames:v",
        &plan.cap.to_string(),
        "-c:v",
        "libx264",
        "-threads",
        &threads.to_string(),
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-maxrate",
        &rate.to_string(),
        "-bufsize",
        &(rate * 2).to_string(),
        "-profile:v",
        "high",
        "-pix_fmt",
        "yuv420p",
        "-g",
        &gop.to_string(),
        "-bsf:v",
        "filter_units=remove_types=6",
        "-fflags",
        "+bitexact",
        "-flags:v",
        "+bitexact",
        "-map_metadata",
        "-1",
        "-metadata:s:v:0",
        "handler_name=",
        "-f",
        "mp4",
        "-movflags",
        "+frag_keyframe+empty_moov+default_base_moof",
        "pipe:1",
    ])
}

/// One stage's bounds: idle priority, no core dumps, 64 fds, no files
/// written, the CPU seconds of `threads` busy for the whole deadline.
fn bounded(
    filter: &OwnedFd,
    argv: Vec<OsString>,
    deadline: Duration,
    address_space: u64,
    threads: usize,
) -> Bounded {
    sandbox(filter)
        .bounded(argv)
        .env_clear()
        .env("PATH", "/usr/bin")
        .nice(19)
        .io_idle()
        .timeout(deadline)
        .rlimit(Resource::As, address_space)
        .rlimit(
            Resource::Cpu,
            deadline.as_secs().max(1) * threads.max(1) as u64 + 5,
        )
        .rlimit(Resource::Fsize, 0)
        .rlimit(Resource::Core, 0)
        .rlimit(Resource::Nofile, 64)
}

fn available() -> Result<(), Fail> {
    let file = |path: &str| fs::metadata(path).is_ok_and(|meta| meta.is_file());
    if file(BWRAP) && file(FFMPEG) && file(FFPROBE) {
        Ok(())
    } else {
        Err(Fail("decoder-unavailable"))
    }
}

// --- the source -----------------------------------------------------------

/// The file the request names, open: a regular file (symlinks followed,
/// any owner, like a background picture), with what it was when hashed.
pub struct Source {
    file: File,
    pub bytes: u64,
    pub container: Option<Container>,
    stamp: (u64, u64, i64, i64, i64, i64),
}

fn stamp(meta: &fs::Metadata) -> (u64, u64, i64, i64, i64, i64) {
    (
        meta.dev(),
        meta.ino(),
        meta.mtime(),
        meta.mtime_nsec(),
        meta.ctime(),
        meta.ctime_nsec(),
    )
}

impl Source {
    /// Opens `path`: missing or dangling `video-missing`, a directory or
    /// special file `not-regular-file`. The container comes from the first
    /// 64 bytes.
    pub fn open(path: &str) -> Result<Source, Fail> {
        let fd = match rustix::fs::open(
            path,
            OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        ) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::NOENT) => return Err(Fail("video-missing")),
            Err(error) => return Err(io::Error::from(error).into()),
        };
        let stat = rustix::fs::fstat(&fd)?;
        if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
            return Err(Fail("not-regular-file"));
        }
        let mut file = File::from(fd);
        let meta = file.metadata()?;
        let mut head = [0u8; 64];
        let mut filled = 0;
        while filled < head.len() {
            match file.read(&mut head[filled..]) {
                Ok(0) => break,
                Ok(read) => filled += read,
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => return Err(error.into()),
            }
        }
        Ok(Source {
            bytes: meta.len(),
            container: sniff(&head[..filled]),
            stamp: stamp(&meta),
            file,
        })
    }

    /// SHA-256 of the whole file, read from the open descriptor; the file
    /// must not change meanwhile (`source-changed`).
    pub fn hash(&mut self) -> Result<String, Fail> {
        rustix::fs::seek(&self.file, rustix::fs::SeekFrom::Start(0))?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; 1 << 20];
        let mut read_total = 0u64;
        loop {
            let read = match self.file.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => read,
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(error) => return Err(error.into()),
            };
            read_total += read as u64;
            if read_total > self.bytes {
                return Err(Fail("source-changed"));
            }
            hasher.update(&buffer[..read]);
        }
        self.check_unchanged()?;
        if read_total != self.bytes {
            return Err(Fail("source-changed"));
        }
        Ok(format!("{:x}", hasher.finalize()))
    }

    fn check_unchanged(&self) -> Result<(), Fail> {
        let meta = self.file.metadata()?;
        if meta.len() != self.bytes || stamp(&meta) != self.stamp {
            return Err(Fail("source-changed"));
        }
        Ok(())
    }

    /// A descriptor for a stage's stdin, at the start of the file (it
    /// shares the offset with ours; stages run one after the other).
    fn stdin(&self) -> Result<OwnedFd, Fail> {
        rustix::fs::seek(&self.file, rustix::fs::SeekFrom::Start(0))?;
        Ok(OwnedFd::from(self.file.try_clone()?))
    }
}

/// ffprobe in the sandbox: the facts, or `decode-failed` / `decode-timeout`.
fn run_probe(source: &Source, container: Container) -> Result<Facts, Fail> {
    let filter = filter()?;
    let stage = bounded(
        &filter,
        probe_argv(container.demuxer),
        FFPROBE_DEADLINE,
        1024 * MIB,
        1,
    )
    .stdin_fd(source.stdin()?)
    .max_output(FFPROBE_OUTPUT);
    let output = crate::signals_unblocked(|| stage.run())?;
    outcome(&output)?;
    facts(&output.stdout)
}

fn outcome(output: &Output) -> Result<(), Fail> {
    if output.timed_out {
        return Err(Fail("decode-timeout"));
    }
    if !output.success() {
        return Err(Fail("decode-failed"));
    }
    Ok(())
}

/// The first frame as a PNG at the output size.
fn run_poster(
    source: &Source,
    container: Container,
    facts: &Facts,
    plan: &Plan,
) -> Result<Vec<u8>, Fail> {
    let filter = filter()?;
    let bytes = (plan.pixels() * 3) as usize;
    let stage = bounded(
        &filter,
        poster_argv(container.demuxer, plan),
        POSTER_DEADLINE,
        decoder_space(plan, facts, 2),
        2,
    )
    .stdin_fd(source.stdin()?)
    .max_output(bytes);
    let output = crate::signals_unblocked(|| stage.run())?;
    if output.overflowed {
        return Err(Fail("invalid-pixels"));
    }
    outcome(&output)?;
    if output.stdout.len() != bytes {
        return Err(Fail("invalid-pixels"));
    }
    image::encode_rgb(plan.width as usize, plan.height as usize, &output.stdout)
}

// --- the cache --------------------------------------------------------------

/// `<cache>/video`: the artwork cache's rules (0700, this user's).
fn cache_dir(root: &Path) -> Result<PathBuf, Fail> {
    let dir = root.join("video");
    store::checked_dir(&dir, true)?;
    Ok(dir)
}

pub fn clip_name(hash: &str, (width, height): (u32, u32)) -> String {
    format!("{hash}-{width}x{height}.mp4")
}

pub fn is_clip_name(name: &str) -> bool {
    let Some(stem) = name.strip_suffix(".mp4") else {
        return false;
    };
    let Some((hash, size)) = stem.split_once('-') else {
        return false;
    };
    let Some((w, h)) = size.split_once('x') else {
        return false;
    };
    let number = |s: &str| {
        !s.is_empty()
            && s.len() <= 4
            && s.bytes().all(|b| b.is_ascii_digit())
            && !s.starts_with('0')
    };
    hash.len() == 64
        && hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        && number(w)
        && number(h)
}

/// The short lock for writing into the cache (publishing, pruning): waits
/// up to 2 s, then `cache-busy`.
fn write_lock(dir: &Path) -> Result<FileLock, Fail> {
    FileLock::exclusive_within(&dir.join(".lock"), Duration::from_secs(2))?
        .ok_or(Fail("cache-busy"))
}

/// A clip already made for this content and size: its path and bytes. A
/// found clip is touched, so the one in use is the last evicted.
fn cached_clip(dir: &Path, name: &str) -> Result<Option<(PathBuf, u64)>, Fail> {
    let path = dir.join(name);
    let meta = match fs::symlink_metadata(&path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !meta.file_type().is_file()
        || meta.uid() != getuid().as_raw()
        || meta.len() == 0
        || meta.len() > MAX_CLIP as u64
    {
        return Ok(None);
    }
    if let Ok(file) = File::open(&path) {
        let _ = file.set_modified(SystemTime::now());
    }
    Ok(Some((path, meta.len())))
}

/// Keeps the newest `keep` clips (by mtime), never `spare`.
fn prune_clips(dir: &Path, keep: usize, spare: &str) -> Result<(), Fail> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if is_clip_name(name) && name != spare {
            let meta = fs::symlink_metadata(entry.path())?;
            entries.push(((meta.mtime(), meta.mtime_nsec()), entry.path()));
        }
    }
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (_, path) in entries.iter().skip(keep.saturating_sub(1)) {
        fs::remove_file(path)?;
    }
    Ok(())
}

/// Removes staging directories left by killed jobs: `.job-*` (only under
/// the conversion lock, which every conversion holds), `.probe-*` once a
/// minute old.
fn reclaim(dir: &Path, jobs: bool) -> Result<(), Fail> {
    for entry in fs::read_dir(dir)?.flatten() {
        let name = entry.file_name();
        let Ok(meta) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if !meta.file_type().is_dir() {
            continue;
        }
        let old = SystemTime::now()
            .duration_since(meta.modified().unwrap_or(SystemTime::now()))
            .is_ok_and(|age| age > Duration::from_secs(60));
        if (jobs && store::matches_staging(&name, ".job-"))
            || (old && store::matches_staging(&name, ".probe-"))
        {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
    Ok(())
}

// --- the jobs ---------------------------------------------------------------

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// What both jobs know before stage A decodes anything.
struct Checked {
    source: Source,
    container: Container,
    facts: Facts,
    plan: Plan,
}

/// Opens and checks the source and runs ffprobe. Returns the reply's facts
/// either way; `Ok(Err(reply))` when a limit stops it before decoding.
fn check(request: &Request) -> Result<Result<Checked, Value>, Fail> {
    let source = Source::open(&request.path)?;
    let Some(container) = source.container else {
        return Err(Fail("unsupported-format"));
    };
    let mut reply = json!({
        "ok": true,
        "bytes": source.bytes,
        "container": container.name,
        "codec": null, "width": null, "height": null, "fps": null, "duration": null,
        "violations": [],
        "output": null,
        "threads": threads(),
        "estimate": null,
        "poster": null,
        "clip": null,
        "clipBytes": null,
    });
    let too_large = violations(source.bytes, None);
    if !too_large.is_empty() {
        reply["violations"] = json!(too_large);
        return Ok(Err(reply));
    }
    available()?;
    let facts = run_probe(&source, container)?;
    let plan = Plan::new(&facts, request.output());
    reply["codec"] = json!(facts.codec);
    reply["width"] = json!(facts.width);
    reply["height"] = json!(facts.height);
    reply["fps"] = json!((facts.fps.0 as f64 / facts.fps.1 as f64 * 1000.0).round() / 1000.0);
    reply["duration"] = json!(facts.duration.map(|d| (d * 1000.0).round() / 1000.0));
    reply["output"] = plan.reply();
    reply["estimate"] = json!(estimate(&facts, &plan, threads()));
    let broken = violations(source.bytes, Some(&facts));
    if !broken.is_empty() {
        reply["violations"] = json!(broken);
        return Ok(Err(reply));
    }
    Ok(Ok(Checked {
        source,
        container,
        facts,
        plan,
    }))
}

/// `video-probe`: the facts, the limits it breaks, what a conversion
/// would make, the poster and any clip already made.
pub fn probe(request: &Map<String, Value>) -> Result<Value, Fail> {
    probe_in(&store::lock_cache(), request)
}

pub fn probe_in(root: &Path, request: &Map<String, Value>) -> Result<Value, Fail> {
    let request = Request::parse(request)?;
    let mut checked = match check(&request)? {
        Ok(checked) => checked,
        Err(reply) => return Ok(reply),
    };
    let mut reply = facts_reply(&checked);
    let dir = cache_dir(root)?;
    reclaim(&dir, false)?;
    let hash = checked.source.hash()?;
    let poster = run_poster(
        &checked.source,
        checked.container,
        &checked.facts,
        &checked.plan,
    )?;
    let name = format!("{:x}.png", Sha256::digest(&poster));
    let target = dir.join(&name);
    let staging = Staging::create(&dir, ".probe-")?;
    {
        let _lock = write_lock(&dir)?;
        staging.publish("poster.png", &poster, &target)?;
        staging.finish()?;
        store::prune(&dir, MAX_POSTERS)?;
        if let Some((clip, bytes)) = cached_clip(&dir, &clip_name(&hash, request.output()))? {
            reply["clip"] = json!(path_text(&clip));
            reply["clipBytes"] = json!(bytes);
        }
    }
    reply["poster"] = json!(path_text(&target));
    Ok(reply)
}

fn facts_reply(checked: &Checked) -> Value {
    let facts = &checked.facts;
    json!({
        "ok": true,
        "bytes": checked.source.bytes,
        "container": checked.container.name,
        "codec": facts.codec,
        "width": facts.width,
        "height": facts.height,
        "fps": (facts.fps.0 as f64 / facts.fps.1 as f64 * 1000.0).round() / 1000.0,
        "duration": facts.duration.map(|d| (d * 1000.0).round() / 1000.0),
        "violations": [],
        "output": checked.plan.reply(),
        "threads": threads(),
        "estimate": estimate(facts, &checked.plan, threads()),
        "poster": null,
        "clip": null,
        "clipBytes": null,
    })
}

/// How many frames stage A has handed over, once in a while.
struct Progress {
    total: u64,
    frame: u64,
    shown: Option<u64>,
    at: Instant,
}

impl Progress {
    fn report(&mut self, piped: u64) {
        let frames = (piped / self.frame).min(self.total);
        let due = self.at.elapsed() >= Duration::from_millis(200) || frames == self.total;
        if self.shown != Some(frames) && (due || self.shown.is_none()) {
            self.shown = Some(frames);
            self.at = Instant::now();
            let guard = state();
            if !guard.done {
                let _ =
                    json::print_line(&json!({"progress": {"frames": frames, "total": self.total}}));
            }
        }
    }
}

/// `video-convert`: the two-stage pipeline into the cache.
pub fn convert(request: &Map<String, Value>, started: Instant) -> Result<Value, Fail> {
    convert_in(&store::lock_cache(), request, started)
}

pub fn convert_in(
    root: &Path,
    request: &Map<String, Value>,
    started: Instant,
) -> Result<Value, Fail> {
    let request = Request::parse(request)?;
    let mut checked = match check(&request)? {
        Ok(checked) => checked,
        Err(reply) => {
            let first = reply["violations"][0].as_str().unwrap_or("decode-failed");
            return Err(Fail(match first {
                "input-too-large" => "input-too-large",
                "unsupported-codec" => "unsupported-codec",
                "input-too-wide" => "input-too-wide",
                _ => "decode-failed",
            }));
        }
    };
    let dir = cache_dir(root)?;
    let _busy = FileLock::try_exclusive(&dir.join(".convert"))?.ok_or(Fail("busy"))?;
    reclaim(&dir, true)?;
    let hash = checked.source.hash()?;
    let output = request.output();
    let name = clip_name(&hash, output);
    let plan = checked.plan;
    {
        let _lock = write_lock(&dir)?;
        if let Some((clip, bytes)) = cached_clip(&dir, &name)? {
            return Ok(done(&clip, bytes, &plan, None));
        }
    }
    let staging = Staging::create(&dir, ".job-")?;
    let threads = threads();
    let left = CONVERT_DEADLINE.saturating_sub(started.elapsed());
    if left.is_zero() {
        return Err(Fail("job-timeout"));
    }
    let (filter_a, filter_b) = (filter()?, filter()?);
    let decode = bounded(
        &filter_a,
        decode_argv(
            checked.container.demuxer,
            &plan,
            threads,
            decode_threads(&checked.facts, threads),
        ),
        left,
        decoder_space(&plan, &checked.facts, threads),
        threads,
    )
    .stdin_fd(checked.source.stdin()?)
    .max_output(STAGE_LOG);
    let encode = bounded(
        &filter_b,
        encode_argv(&plan, threads),
        left,
        encoder_space(&plan, threads),
        threads,
    )
    .max_output(MAX_CLIP);
    let mut progress = Progress {
        total: plan.total,
        frame: plan.frame_bytes(),
        shown: None,
        at: Instant::now(),
    };
    let result = crate::signals_unblocked(|| {
        decode.pipe_into(encode).run_with_progress(|piped| {
            progress.report(piped);
            if CANCEL.load(Ordering::Relaxed) {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        })
    })?;
    if result.cancelled || CANCEL.load(Ordering::Relaxed) {
        return Err(Fail("cancelled"));
    }
    let frames = accept(&result, &plan)?;
    checked.source.check_unchanged()?;
    let target = dir.join(&name);
    {
        let _lock = write_lock(&dir)?;
        staging.publish("clip.mp4", &result.second.stdout, &target)?;
        staging.finish()?;
        prune_clips(&dir, MAX_CLIPS, &name)?;
    }
    Ok(done(
        &target,
        result.second.stdout.len() as u64,
        &plan,
        Some(frames),
    ))
}

/// The checks before a clip is kept: stage A exited 0 on its own with a
/// whole number of frames, at least one and at most the cut; stage B exited
/// 0 with an MP4 of at most `MAX_CLIP`. Returns the frames.
pub fn accept(result: &foamy_helper::child::PipelineOutput, plan: &Plan) -> Result<u64, Fail> {
    if result.first.timed_out || result.second.timed_out {
        return Err(Fail("job-timeout"));
    }
    if result.second.overflowed {
        return Err(Fail("output-too-large"));
    }
    if !result.first.success() {
        return Err(Fail("decode-failed"));
    }
    let frame = plan.frame_bytes();
    if result.piped == 0 || !result.piped.is_multiple_of(frame) || result.piped / frame > plan.cap {
        return Err(Fail("invalid-frames"));
    }
    if !result.second.success() || result.second.stdout.get(4..8) != Some(b"ftyp") {
        return Err(Fail("encode-failed"));
    }
    Ok(result.piped / frame)
}

fn done(clip: &Path, bytes: u64, plan: &Plan, frames: Option<u64>) -> Value {
    json!({
        "ok": true,
        "clip": path_text(clip),
        "bytes": bytes,
        "frames": frames.unwrap_or(plan.total),
        "output": plan.reply(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn requests_are_checked_size_first() {
        let ok = Request::parse(&request(
            json!({"path": "/v.mp4", "width": 3440, "height": 1440}),
        ))
        .unwrap();
        assert_eq!(
            ok,
            Request {
                path: "/v.mp4".into(),
                width: 3440,
                height: 1440
            }
        );
        for body in [
            json!({"path": "/v.mp4", "width": 15, "height": 1440}),
            json!({"path": "/v.mp4", "width": 7681, "height": 1440}),
            json!({"path": "/v.mp4", "width": 3440, "height": 4321}),
            json!({"path": "/v.mp4", "width": 3440.5, "height": 1440}),
            json!({"path": "/v.mp4", "width": "3440", "height": 1440}),
            json!({"path": "/v.mp4", "height": 1440}),
            json!({"path": 5, "width": 1, "height": 1440}),
        ] {
            assert_eq!(
                Request::parse(&request(body.clone())).unwrap_err().0,
                "invalid-size",
                "{body}"
            );
        }
        for path in [
            json!("v.mp4"),
            json!(""),
            json!("/a\0b"),
            json!(null),
            json!(format!("/{}", "a".repeat(4096))),
        ] {
            let body = request(json!({"path": path, "width": 64, "height": 36}));
            assert_eq!(Request::parse(&body).unwrap_err().0, "invalid-video-path");
        }
        assert_eq!(
            Request::parse(&request(json!({"width": 64, "height": 36})))
                .unwrap_err()
                .0,
            "invalid-video-path"
        );
    }

    #[test]
    fn output_fits_uhd_with_even_sides() {
        assert_eq!(output_size(3440, 1440), (3440, 1440));
        assert_eq!(output_size(1920, 1080), (1920, 1080));
        assert_eq!(output_size(3840, 2160), (3840, 2160));
        assert_eq!(output_size(5120, 2880), (3840, 2160));
        assert_eq!(output_size(7680, 4320), (3840, 2160));
        assert_eq!(output_size(7680, 2160), (3840, 1080));
        assert_eq!(output_size(2160, 3840), (1214, 2160));
        assert_eq!(output_size(1366, 768), (1366, 768));
        assert_eq!(output_size(1365, 767), (1364, 766));
        assert_eq!(output_size(16, 16), (16, 16));
        assert_eq!(output_size(7680, 16), (3840, 16));
        for (w, h) in [(7680, 4320), (5000, 4000), (3841, 2161), (17, 4320)] {
            let (ow, oh) = output_size(w, h);
            assert!(
                ow <= MAX_OUT_WIDTH && oh <= MAX_OUT_HEIGHT && ow % 2 == 0 && oh % 2 == 0,
                "{w}x{h}"
            );
        }
    }

    #[test]
    fn containers_come_from_the_first_bytes() {
        let mp4 = b"\0\0\0\x20ftypisom\0\0\x02\0";
        assert_eq!(
            sniff(mp4),
            Some(Container {
                demuxer: "mov",
                name: "mp4"
            })
        );
        assert_eq!(
            sniff(b"\0\0\0\x14ftypqt  \0\0\0\0"),
            Some(Container {
                demuxer: "mov",
                name: "mov"
            })
        );
        assert_eq!(
            sniff(b"\0\0\0\x08wide\0\0\0\0mdat"),
            Some(Container {
                demuxer: "mov",
                name: "mov"
            })
        );
        let mut mkv =
            b"\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\xf7\x81\x01\x42\x82\x88matroska".to_vec();
        assert_eq!(
            sniff(&mkv),
            Some(Container {
                demuxer: "matroska",
                name: "mkv"
            })
        );
        mkv.truncate(15);
        mkv.extend_from_slice(b"\x84webm");
        assert_eq!(
            sniff(&mkv),
            Some(Container {
                demuxer: "matroska",
                name: "webm"
            })
        );
        for other in [
            &b"GIF89a\0\0\0\0\0\0"[..],
            b"\x89PNG\r\n\x1a\n\0\0\0\0",
            b"RIFF\0\0\0\0AVI ",
            b"",
            b"\0\0\0",
        ] {
            assert_eq!(sniff(other), None);
        }
    }

    #[test]
    fn facts_are_read_strictly() {
        let probe = |text: &str| facts(text.as_bytes());
        let good = probe(r#"{"streams": [{"codec_name": "hevc", "width": 3840, "height": 2160,
            "avg_frame_rate": "60000/1001", "r_frame_rate": "60/1"}], "format": {"duration": "252.100"}}"#)
        .unwrap();
        assert_eq!(
            good,
            Facts {
                codec: "hevc".into(),
                width: 3840,
                height: 2160,
                fps: (60000, 1001),
                duration: Some(252.1)
            }
        );
        let fallback = probe(
            r#"{"streams": [{"codec_name": "vp9", "width": 640, "height": 360,
            "avg_frame_rate": "0/0", "r_frame_rate": "24/1", "duration": "3.5"}], "format": {}}"#,
        )
        .unwrap();
        assert_eq!((fallback.fps, fallback.duration), ((24, 1), Some(3.5)));
        let unknown = probe(r#"{"streams": [{"codec_name": "av1", "width": 64, "height": 36}], "format": {"duration": "N/A"}}"#).unwrap();
        assert_eq!((unknown.fps, unknown.duration), ((30, 1), None));
        assert_eq!(
            probe(r#"{"streams": [], "format": {}}"#).unwrap_err().0,
            "no-video"
        );
        for bad in [
            "",
            "[]",
            r#"{"format": {}}"#,
            r#"{"streams": [{"codec_name": "H264", "width": 64, "height": 36}]}"#,
            r#"{"streams": [{"codec_name": "h264", "width": 0, "height": 36}]}"#,
            r#"{"streams": [{"codec_name": "h264", "width": 64, "height": 70000}]}"#,
            r#"{"streams": [{"codec_name": "h264", "width": "64", "height": 36}]}"#,
            r#"{"streams": [{"width": 64, "height": 36}]}"#,
        ] {
            assert_eq!(probe(bad).unwrap_err().0, "decode-failed", "{bad}");
        }
    }

    fn facts_at(codec: &str, fps: (u32, u32), duration: Option<f64>) -> Facts {
        Facts {
            codec: codec.into(),
            width: 3840,
            height: 2160,
            fps,
            duration,
        }
    }

    #[test]
    fn plans_cut_at_sixty_seconds_and_thirty_frames() {
        let plan = Plan::new(&facts_at("hevc", (60, 1), Some(252.0)), (3440, 1440));
        assert_eq!(
            (plan.fps, plan.cap, plan.total, plan.cut),
            ((30, 1), 1800, 1800, true)
        );
        assert_eq!(plan.seconds, 60.0);
        assert_eq!(plan.frame_bytes(), 3440 * 1440 * 3 / 2);
        let film = Plan::new(&facts_at("h264", (24000, 1001), Some(10.0)), (1920, 1080));
        assert_eq!(
            (film.fps, film.cap, film.total, film.cut),
            ((24000, 1001), 1438, 240, false)
        );
        let unknown = Plan::new(&facts_at("vp9", (25, 1), None), (1920, 1080));
        assert_eq!(
            (unknown.total, unknown.cap, unknown.cut),
            (1500, 1500, false)
        );
        let slow = Plan::new(&facts_at("vp8", (1, 2), Some(4.0)), (64, 36));
        assert_eq!((slow.fps, slow.total), ((1, 1), 4));
        let tiny = Plan::new(&facts_at("h264", (30, 1), Some(0.01)), (64, 36));
        assert_eq!(tiny.total, 1);
        // The bitrate keeps 60 s under the cap with a full buffer to spare.
        let uhd = Plan::new(&facts_at("hevc", (30, 1), Some(60.0)), (3840, 2160));
        assert_eq!(uhd.bitrate(), MAX_BITRATE);
        assert!(MAX_BITRATE * 60 / 8 + MAX_BITRATE * 2 / 8 < MAX_CLIP as u64);
        assert_eq!(
            Plan::new(&facts_at("h264", (30, 1), None), (1920, 1080)).bitrate(),
            1920 * 1080 * 3
        );
    }

    #[test]
    fn violations_follow_the_limits() {
        let at = |codec: &str, width, height| Facts {
            codec: codec.into(),
            width,
            height,
            fps: (30, 1),
            duration: None,
        };
        assert!(violations(MAX_INPUT, Some(&at("h264", 7680, 4320))).is_empty());
        assert!(violations(1, Some(&at("av1", 4320, 7680))).is_empty());
        assert_eq!(violations(MAX_INPUT + 1, None), ["input-too-large"]);
        assert_eq!(
            violations(1, Some(&at("prores", 64, 36))),
            ["unsupported-codec"]
        );
        assert_eq!(
            violations(1, Some(&at("vp9", 7696, 64))),
            ["input-too-wide"]
        );
        assert_eq!(
            violations(1, Some(&at("vp9", 5000, 4400))),
            ["input-too-wide"]
        );
        assert_eq!(
            violations(MAX_INPUT + 1, Some(&at("mpeg4", 8000, 8000))),
            ["input-too-large", "unsupported-codec", "input-too-wide"]
        );
        for codec in CODECS {
            assert!(
                violations(1, Some(&at(codec, 64, 36))).is_empty(),
                "{codec}"
            );
        }
    }

    #[test]
    fn threads_leave_two_cores() {
        let n = threads();
        assert!((1..=MAX_THREADS).contains(&n));
        let cores = std::thread::available_parallelism().unwrap().get();
        assert_eq!(n, cores.saturating_sub(2).clamp(1, 16));
    }

    #[test]
    fn clip_names_are_hash_and_size() {
        let hash = "0f".repeat(32);
        let name = clip_name(&hash, (3440, 1440));
        assert_eq!(name, format!("{hash}-3440x1440.mp4"));
        assert!(is_clip_name(&name));
        for bad in [
            format!("{hash}.mp4"),
            format!("{hash}-3440x1440.png"),
            format!("{}-3440x1440.mp4", "0F".repeat(32)),
            format!("{}-3440x1440.mp4", "0f".repeat(31)),
            format!("{hash}-03440x1440.mp4"),
            format!("{hash}-x1440.mp4"),
            format!("{hash}-34400x1440.mp4"),
        ] {
            assert!(!is_clip_name(&bad), "{bad}");
        }
    }

    #[test]
    fn prune_keeps_the_newest_clips_and_the_new_one() {
        let dir =
            std::env::temp_dir().join(format!("foamy-lock-video-prune-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let names: Vec<String> = (0..5)
            .map(|i| clip_name(&format!("{i:x}").repeat(64), (64, 36)))
            .collect();
        for (age, name) in names.iter().enumerate() {
            let file = File::create(dir.join(name)).unwrap();
            file.set_modified(SystemTime::now() - Duration::from_secs(100 * age as u64))
                .unwrap();
        }
        fs::write(dir.join("poster.png"), b"").unwrap();
        // The oldest is the one just made (its mtime says so in this test).
        prune_clips(&dir, MAX_CLIPS, &names[4]).unwrap();
        let mut left: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        let mut expected = vec![
            names[0].clone(),
            names[1].clone(),
            names[4].clone(),
            "poster.png".into(),
        ];
        expected.sort();
        assert_eq!(left, expected);
        fs::remove_dir_all(&dir).unwrap();
    }

    fn plan_1080() -> Plan {
        Plan::new(&facts_at("hevc", (60, 1), Some(90.0)), (1920, 1080))
    }

    #[test]
    fn stage_a_reads_only_the_fd_and_writes_raw_frames() {
        let argv: Vec<String> = decode_argv("mov", &plan_1080(), 16, 16)
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        let expected = [
            "/usr/bin/ffmpeg",
            "-filter_threads",
            "16",
            "-nostdin",
            "-hide_banner",
            "-v",
            "error",
            "-protocol_whitelist",
            "fd",
            "-format_whitelist",
            "mov,matroska",
            "-codec_whitelist",
            "h264,hevc,vp8,vp9,av1,libdav1d",
            "-threads",
            "16",
            "-fd",
            "0",
            "-f",
            "mov",
            "-i",
            "fd:",
            "-map",
            "0:V:0",
            "-an",
            "-sn",
            "-dn",
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-t",
            "60",
            "-vf",
            "fps=30/1,scale=1920:1080:force_original_aspect_ratio=increase:flags=bicubic,crop=1920:1080,setsar=1,format=yuv420p",
            "-frames:v",
            "1800",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "yuv420p",
            "pipe:1",
        ];
        assert_eq!(argv, expected);
    }

    #[test]
    fn stage_b_reads_only_raw_frames() {
        let argv: Vec<String> = encode_argv(&plan_1080(), 16)
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        let at = |key: &str| argv[argv.iter().position(|a| a == key).unwrap() + 1].clone();
        assert_eq!(at("-protocol_whitelist"), "pipe");
        assert_eq!(at("-format_whitelist"), "rawvideo");
        assert_eq!(at("-codec_whitelist"), "rawvideo");
        assert_eq!(at("-i"), "pipe:0");
        assert_eq!(at("-video_size"), "1920x1080");
        assert_eq!(at("-framerate"), "30/1");
        assert_eq!(at("-c:v"), "libx264");
        assert_eq!(at("-maxrate"), (1920 * 1080 * 3).to_string());
        assert_eq!(at("-g"), "60");
        assert_eq!(
            at("-movflags"),
            "+frag_keyframe+empty_moov+default_base_moof"
        );
        assert_eq!(argv.last().unwrap(), "pipe:1");
        assert!(
            !argv.iter().any(|a| a.contains("fd") && a != "-bufsize"),
            "{argv:?}"
        );
    }

    #[test]
    fn the_probe_and_poster_stay_on_the_fd() {
        let probe: Vec<String> = probe_argv("matroska")
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        assert_eq!(&probe[..2], ["/usr/bin/ffprobe", "-hide_banner"]);
        assert!(probe.windows(2).any(|w| w == ["-f", "matroska"]));
        assert!(probe.windows(2).any(|w| w == ["-select_streams", "V:0"]));
        assert_eq!(&probe[probe.len() - 2..], ["-i", "fd:"]);
        let poster: Vec<String> = poster_argv("mov", &plan_1080())
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        assert!(poster.windows(2).any(|w| w == ["-frames:v", "1"]));
        assert!(poster.windows(2).any(|w| w == ["-pix_fmt", "rgb24"]));
        assert!(
            poster
                .windows(2)
                .any(|w| w == ["-codec_whitelist", DECODERS])
        );
    }

    #[test]
    fn limits_cover_the_measured_peaks() {
        const MIB: u64 = 1024 * 1024;
        let uhd = facts_at("hevc", (60, 1), Some(70.0));
        // (output, stage A peak, stage B peak) with 16 threads, in MiB.
        for (size, a, b) in [
            ((1920, 1080), 1502, 1492),
            ((3440, 1440), 1584, 2314),
            ((3840, 2160), 1526, 3194),
        ] {
            let plan = Plan::new(&uhd, size);
            let (space_a, space_b) = (
                decoder_space(&plan, &uhd, 16) / MIB,
                encoder_space(&plan, 16) / MIB,
            );
            assert!(
                space_a as f64 > a as f64 * 1.15,
                "{size:?}: A {space_a} for {a}"
            );
            assert!(
                space_b as f64 > b as f64 * 1.15,
                "{size:?}: B {space_b} for {b}"
            );
        }
        // Above 3840x2160 the decoder gets fewer threads, at least 2.
        assert_eq!(decode_threads(&uhd, 16), 16);
        let eight = Facts {
            width: 7680,
            height: 4320,
            ..uhd.clone()
        };
        assert_eq!(decode_threads(&eight, 16), 4);
        assert_eq!(decode_threads(&eight, 4), 2);
        assert_eq!(decode_threads(&eight, 1), 1);
        let plan = Plan::new(&eight, (3840, 2160));
        assert!(decoder_space(&plan, &eight, 16) < 4 << 30);
        // The estimate: about 15 s for 3440x1440 from 60 fps UHD HEVC on 16
        // threads, about 13 s from 1080p30 H.264.
        assert_eq!(estimate(&uhd, &Plan::new(&uhd, (3440, 1440)), 16), 14);
        let hd = Facts {
            codec: "h264".into(),
            width: 1920,
            height: 1080,
            fps: (30, 1),
            duration: Some(75.0),
        };
        assert_eq!(estimate(&hd, &Plan::new(&hd, (3440, 1440)), 16), 14);
        assert!(estimate(&hd, &Plan::new(&hd, (3440, 1440)), 1) > 150);
    }

    #[test]
    fn only_whole_frames_and_an_mp4_are_accepted() {
        use foamy_helper::child::PipelineOutput;
        use std::os::unix::process::ExitStatusExt;
        let plan = Plan::new(&facts_at("h264", (30, 1), Some(2.0)), (64, 36));
        let frame = plan.frame_bytes();
        let output = |code: i32, stdout: &[u8]| Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.to_vec(),
            stderr: Vec::new(),
            timed_out: false,
            overflowed: false,
        };
        let mp4 = b"\0\0\0\x1cftypiso5";
        let run = |a: Output, b: Output, piped: u64| PipelineOutput {
            first: a,
            second: b,
            piped,
            cancelled: false,
        };
        assert_eq!(
            accept(&run(output(0, b""), output(0, mp4), frame * 60), &plan),
            Ok(60)
        );
        assert_eq!(
            accept(&run(output(0, b""), output(0, mp4), frame), &plan),
            Ok(1)
        );
        // Stage A failed, or wrote nothing, a partial frame or past the cut:
        // whatever stage B made of it is refused.
        assert_eq!(
            accept(&run(output(1, b""), output(0, mp4), frame * 60), &plan)
                .unwrap_err()
                .0,
            "decode-failed"
        );
        assert_eq!(
            accept(&run(output(0, b""), output(0, mp4), 0), &plan)
                .unwrap_err()
                .0,
            "invalid-frames"
        );
        assert_eq!(
            accept(&run(output(0, b""), output(0, mp4), frame * 3 + 1), &plan)
                .unwrap_err()
                .0,
            "invalid-frames"
        );
        assert_eq!(
            accept(
                &run(output(0, b""), output(0, mp4), frame * (plan.cap + 1)),
                &plan
            )
            .unwrap_err()
            .0,
            "invalid-frames"
        );
        assert_eq!(
            accept(&run(output(0, b""), output(1, mp4), frame), &plan)
                .unwrap_err()
                .0,
            "encode-failed"
        );
        assert_eq!(
            accept(
                &run(output(0, b""), output(0, b"\0\0\0\x1cmdat"), frame),
                &plan
            )
            .unwrap_err()
            .0,
            "encode-failed"
        );
        let mut big = output(0, mp4);
        big.overflowed = true;
        assert_eq!(
            accept(&run(output(0, b""), big, frame), &plan)
                .unwrap_err()
                .0,
            "output-too-large"
        );
        let mut slow = output(0, b"");
        slow.timed_out = true;
        assert_eq!(
            accept(&run(slow, output(0, mp4), frame), &plan)
                .unwrap_err()
                .0,
            "job-timeout"
        );
    }
}
