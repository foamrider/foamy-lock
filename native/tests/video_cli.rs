//! `video-probe` and `video-convert` as the QML runs them: one request on
//! stdin, JSON lines on stdout, with a temporary cache. Every video here is
//! generated with ffmpeg's lavfi sources; none is ever a user's file. Each
//! test skips itself without ffmpeg or a usable bubblewrap.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

struct Dir(PathBuf);

impl Dir {
    fn new(tag: &str) -> Dir {
        let path =
            std::env::temp_dir().join(format!("foamy-lock-video-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(path.join("cache")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Dir(path)
    }

    fn file(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    fn video(&self) -> PathBuf {
        self.0.join("cache/omarchy/foamy.lock/video")
    }

    /// A video from lavfi: `inputs` and `outputs` are ffmpeg arguments.
    fn make(&self, name: &str, inputs: &[&str], outputs: &[&str]) -> PathBuf {
        let path = self.file(name);
        let status = Command::new("/usr/bin/ffmpeg")
            .args(["-nostdin", "-v", "error", "-y"])
            .args(inputs)
            .args(outputs)
            .arg(&path)
            .stdin(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "ffmpeg {name}");
        path
    }

    fn command(&self, kind: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_foamy-lock-helper"));
        command
            .arg(kind)
            .env_clear()
            .env("HOME", &self.0)
            .env("PATH", "/usr/bin")
            .env("XDG_CACHE_HOME", self.0.join("cache"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        command
    }

    /// Every stdout line, parsed; the last is the reply.
    fn run(&self, kind: &str, request: &Value) -> Vec<Value> {
        let mut child = self.command(kind).spawn().unwrap();
        writeln!(child.stdin.take().unwrap(), "{request}").unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    fn reply(&self, kind: &str, path: &Path, size: (u32, u32)) -> Value {
        let lines = self.run(kind, &request(path, size));
        lines.last().cloned().unwrap()
    }

    fn entries(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(self.video())
            .map(|entries| {
                entries
                    .map(|e| e.unwrap().file_name().into_string().unwrap())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn request(path: &Path, (width, height): (u32, u32)) -> Value {
    json!({"path": path.to_str().unwrap(), "width": width, "height": height})
}

/// ffmpeg, ffprobe and a bubblewrap with namespaces.
fn usable() -> bool {
    let ok = Path::new("/usr/bin/ffmpeg").is_file()
        && Path::new("/usr/bin/ffprobe").is_file()
        && Command::new("/usr/bin/bwrap")
            .args([
                "--unshare-all",
                "--ro-bind",
                "/usr",
                "/usr",
                "--symlink",
                "usr/lib",
                "/lib64",
            ])
            .args(["--symlink", "usr/lib", "/lib", "--", "/usr/bin/true"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success());
    if !ok {
        eprintln!("skipped: needs ffmpeg, ffprobe and bubblewrap with namespaces");
    }
    ok
}

fn lavfi(source: &str) -> Vec<&str> {
    vec!["-f", "lavfi", "-i", source]
}

const H264: [&str; 4] = ["-c:v", "libx264", "-pix_fmt", "yuv420p"];

fn probe_stream(path: &Path) -> Value {
    let output = Command::new("/usr/bin/ffprobe")
        .args([
            "-v",
            "error",
            "-of",
            "json",
            "-show_streams",
            "-show_format",
        ])
        .arg(path)
        .output()
        .unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn a_video_is_probed_converted_and_found() {
    if !usable() {
        return;
    }
    let dir = Dir::new("flow");
    // 60 fps with sound, a title and a subtitle track: none of it survives.
    let mut inputs = lavfi("testsrc2=size=160x90:rate=60:duration=2");
    inputs.extend(lavfi("sine=duration=2"));
    inputs.extend(["-f", "srt", "-i"]);
    let subtitles = dir.file("sub.srt");
    fs::write(&subtitles, "1\n00:00:00,000 --> 00:00:02,000\nhello\n").unwrap();
    let subtitles = subtitles.to_str().unwrap().to_string();
    inputs.push(&subtitles);
    let mut outputs = vec![
        "-map", "0", "-map", "1", "-map", "2", "-c:a", "aac", "-c:s", "mov_text",
    ];
    outputs.extend(H264);
    outputs.extend(["-metadata", "title=secret", "-shortest"]);
    let source = dir.make("clip.mp4", &inputs, &outputs);

    let probe = dir.reply("video-probe", &source, (64, 36));
    assert_eq!(probe["ok"], json!(true), "{probe}");
    assert_eq!(probe["container"], json!("mp4"));
    assert_eq!(probe["codec"], json!("h264"));
    assert_eq!(
        (probe["width"].clone(), probe["height"].clone()),
        (json!(160), json!(90))
    );
    assert_eq!(probe["fps"], json!(60.0));
    assert_eq!(
        probe["duration"].as_f64().map(|d| (d * 10.0).round()),
        Some(20.0)
    );
    assert_eq!(probe["violations"], json!([]));
    assert_eq!(
        probe["output"],
        json!({"width": 64, "height": 36, "fps": 30.0, "seconds": probe["duration"], "frames": 60, "cut": false})
    );
    assert!(
        probe["threads"]
            .as_u64()
            .is_some_and(|n| (1..=16).contains(&n))
    );
    assert!(probe["estimate"].as_u64().is_some_and(|s| s >= 1));
    assert_eq!(probe["clip"], json!(null));
    let poster = PathBuf::from(probe["poster"].as_str().unwrap());
    assert_eq!(poster.parent().unwrap(), dir.video());
    let png = fs::read(&poster).unwrap();
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    assert_eq!(&png[16..24], &[0, 0, 0, 64, 0, 0, 0, 36]);
    assert_eq!(
        fs::metadata(dir.video()).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&poster).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let lines = dir.run("video-convert", &request(&source, (64, 36)));
    let (reply, progress) = lines.split_last().unwrap();
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert!(!progress.is_empty());
    for line in progress {
        assert_eq!(line["progress"]["total"], json!(60));
        assert!(line["progress"]["frames"].as_u64().unwrap() <= 60);
    }
    assert_eq!(progress.last().unwrap()["progress"]["frames"], json!(60));
    assert_eq!(reply["frames"], json!(60));
    let clip = PathBuf::from(reply["clip"].as_str().unwrap());
    let name = clip.file_name().unwrap().to_str().unwrap().to_string();
    assert!(
        name.ends_with("-64x36.mp4") && name.len() == 64 + "-64x36.mp4".len(),
        "{name}"
    );
    assert_eq!(clip.parent().unwrap(), dir.video());
    assert_eq!(reply["bytes"], json!(fs::metadata(&clip).unwrap().len()));
    assert_eq!(
        fs::metadata(&clip).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // One H.264 High video stream at the output size; no sound,
    // subtitles or title.
    let info = probe_stream(&clip);
    let streams = info["streams"].as_array().unwrap();
    assert_eq!(streams.len(), 1, "{info}");
    assert_eq!(streams[0]["codec_name"], json!("h264"));
    assert_eq!(streams[0]["profile"], json!("High"));
    assert_eq!(streams[0]["pix_fmt"], json!("yuv420p"));
    assert_eq!(
        (streams[0]["width"].clone(), streams[0]["height"].clone()),
        (json!(64), json!(36))
    );
    assert_eq!(streams[0]["avg_frame_rate"], json!("30/1"));
    assert!(!info.to_string().contains("secret"));
    // Nothing else was left behind.
    let mut expected = vec![
        ".convert".to_string(),
        ".lock".to_string(),
        name.clone(),
        poster.file_name().unwrap().to_str().unwrap().to_string(),
    ];
    expected.sort();
    assert_eq!(dir.entries(), expected);

    // The probe finds it now, and converting again is done at once.
    let again = dir.reply("video-probe", &source, (64, 36));
    assert_eq!(again["clip"], json!(clip.to_str().unwrap()));
    assert_eq!(again["clipBytes"], reply["bytes"]);
    assert_eq!(again["poster"], probe["poster"]);
    let lines = dir.run("video-convert", &request(&source, (64, 36)));
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0]["clip"], json!(clip.to_str().unwrap()));
    // Another screen size is another clip.
    assert_eq!(
        dir.reply("video-probe", &source, (128, 72))["clip"],
        json!(null)
    );
    // The screen is scaled to fit 3840x2160.
    let big = dir.reply("video-probe", &source, (7680, 4320));
    assert_eq!(
        (
            big["output"]["width"].clone(),
            big["output"]["height"].clone()
        ),
        (json!(3840), json!(2160))
    );
}

#[test]
fn longer_videos_are_cut_and_slow_ones_keep_their_rate() {
    if !usable() {
        return;
    }
    let dir = Dir::new("long");
    let long = dir.make(
        "long.mkv",
        &lavfi("testsrc2=size=32x18:rate=5:duration=65"),
        &H264,
    );
    let probe = dir.reply("video-probe", &long, (32, 18));
    assert_eq!(probe["container"], json!("mkv"));
    assert_eq!(probe["output"]["cut"], json!(true));
    assert_eq!(probe["output"]["seconds"], json!(60.0));
    assert_eq!(probe["output"]["fps"], json!(5.0));
    assert_eq!(probe["output"]["frames"], json!(300));
    let reply = dir.reply("video-convert", &long, (32, 18));
    assert_eq!(reply["frames"], json!(300), "{reply}");
    let info = probe_stream(Path::new(reply["clip"].as_str().unwrap()));
    assert_eq!(info["streams"][0]["avg_frame_rate"], json!("5/1"));

    let webm = dir.make(
        "clip.webm",
        &lavfi("testsrc2=size=48x32:rate=24:duration=1"),
        &["-c:v", "libvpx-vp9", "-deadline", "realtime"],
    );
    let probe = dir.reply("video-probe", &webm, (64, 36));
    assert_eq!(
        (probe["container"].clone(), probe["codec"].clone()),
        (json!("webm"), json!("vp9"))
    );
    assert_eq!(probe["output"]["frames"], json!(24));
    assert_eq!(
        dir.reply("video-convert", &webm, (64, 36))["frames"],
        json!(24)
    );
}

#[test]
fn limits_are_reported_and_refused() {
    if !usable() {
        return;
    }
    let dir = Dir::new("limits");
    // Over 2 GiB (sparse): only its size is read.
    let large = dir.file("large.mp4");
    let mut file = fs::File::create(&large).unwrap();
    file.write_all(b"\0\0\0\x20ftypisom\0\0\x02\0").unwrap();
    file.set_len((2 << 30) + 1).unwrap();
    drop(file);
    let probe = dir.reply("video-probe", &large, (64, 36));
    assert_eq!(probe["ok"], json!(true));
    assert_eq!(probe["violations"], json!(["input-too-large"]));
    assert_eq!(
        (
            probe["bytes"].clone(),
            probe["codec"].clone(),
            probe["poster"].clone()
        ),
        (json!((2u64 << 30) + 1), json!(null), json!(null))
    );
    assert_eq!(
        dir.reply("video-convert", &large, (64, 36))["error"],
        json!("input-too-large")
    );

    // A codec the lock doesn't take: the facts, no poster.
    let mpeg4 = dir.make(
        "mpeg4.mp4",
        &lavfi("testsrc2=size=64x36:rate=10:duration=1"),
        &["-c:v", "mpeg4"],
    );
    let probe = dir.reply("video-probe", &mpeg4, (64, 36));
    assert_eq!(probe["codec"], json!("mpeg4"));
    assert_eq!(probe["violations"], json!(["unsupported-codec"]));
    assert_eq!(probe["poster"], json!(null));
    assert_eq!(
        dir.reply("video-convert", &mpeg4, (64, 36))["error"],
        json!("unsupported-codec")
    );

    // Wider than 7680.
    let wide = dir.make(
        "wide.mp4",
        &lavfi("color=size=7696x64:rate=1:duration=1"),
        &H264,
    );
    let probe = dir.reply("video-probe", &wide, (64, 36));
    assert_eq!(probe["violations"], json!(["input-too-wide"]));
    assert_eq!(probe["width"], json!(7696));
    assert_eq!(
        dir.reply("video-convert", &wide, (64, 36))["error"],
        json!("input-too-wide")
    );
    assert!(
        dir.entries()
            .iter()
            .all(|name| !name.ends_with(".mp4") && !name.ends_with(".png")),
        "{:?}",
        dir.entries()
    );
}

#[test]
fn broken_and_foreign_files_fail_cleanly() {
    if !usable() {
        return;
    }
    let dir = Dir::new("broken");
    let good = dir.make(
        "good.mp4",
        &lavfi("testsrc2=size=64x36:rate=30:duration=2"),
        &H264,
    );
    let bytes = fs::read(&good).unwrap();
    // Cut before the index (ffmpeg writes it last).
    let truncated = dir.file("truncated.mp4");
    fs::write(&truncated, &bytes[..bytes.len() / 2]).unwrap();
    // An MP4 header over noise.
    let garbled = dir.file("garbled.mp4");
    let mut noise = b"\0\0\0\x20ftypisom\0\0\x02\0isomiso2avc1mp41".to_vec();
    noise.extend((0..200_000u32).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8));
    fs::write(&garbled, &noise).unwrap();
    for path in [&truncated, &garbled] {
        let probe = dir.reply("video-probe", path, (64, 36));
        assert_eq!(
            probe,
            json!({"ok": false, "error": "decode-failed"}),
            "{path:?}"
        );
        let convert = dir.reply("video-convert", path, (64, 36));
        assert_eq!(
            convert,
            json!({"ok": false, "error": "decode-failed"}),
            "{path:?}"
        );
    }
    // Not a video container, missing, a directory, bad requests.
    let png = dir.file("picture.png");
    fs::write(&png, b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR").unwrap();
    for (path, code) in [
        (png, "unsupported-format"),
        (dir.file("gone.mp4"), "video-missing"),
        (dir.0.clone(), "not-regular-file"),
    ] {
        for kind in ["video-probe", "video-convert"] {
            assert_eq!(
                dir.reply(kind, &path, (64, 36)),
                json!({"ok": false, "error": code}),
                "{kind} {path:?}"
            );
        }
    }
    for (body, code) in [
        (
            json!({"path": "relative.mp4", "width": 64, "height": 36}),
            "invalid-video-path",
        ),
        (
            json!({"path": good.to_str().unwrap(), "width": 8, "height": 36}),
            "invalid-size",
        ),
        (json!([1]), "invalid-request"),
    ] {
        for kind in ["video-probe", "video-convert"] {
            assert_eq!(
                dir.run(kind, &body),
                [json!({"ok": false, "error": code})],
                "{kind} {body}"
            );
        }
    }
    // Nothing but the cache's own files.
    assert!(
        dir.entries().iter().all(|name| name.starts_with('.')
            && !name.starts_with(".job-")
            && !name.starts_with(".probe-")),
        "{:?}",
        dir.entries()
    );
}

#[test]
fn a_conversion_can_be_cancelled_and_one_runs_at_a_time() {
    if !usable() {
        return;
    }
    let dir = Dir::new("cancel");
    let source = dir.make(
        "long.mp4",
        &lavfi("testsrc2=size=640x360:rate=30:duration=60"),
        &H264,
    );
    let mut child = dir.command("video-convert").spawn().unwrap();
    writeln!(
        child.stdin.take().unwrap(),
        "{}",
        request(&source, (1920, 1080))
    )
    .unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    let first: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(first["progress"]["total"], json!(1800), "{first}");
    // While it runs, a second one is turned away.
    assert_eq!(
        dir.reply("video-convert", &source, (1920, 1080)),
        json!({"ok": false, "error": "busy"})
    );
    let asked = Instant::now();
    // SAFETY: kill(2) on our own child.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    let mut rest = String::new();
    std::io::Read::read_to_string(&mut stdout, &mut rest).unwrap();
    let status = child.wait().unwrap();
    assert!(asked.elapsed() < Duration::from_secs(5));
    assert_eq!(status.code(), Some(0));
    let last: Value = serde_json::from_str(rest.lines().last().unwrap()).unwrap();
    assert_eq!(last, json!({"ok": false, "error": "cancelled"}));
    // Nothing left: no clip, no job directory.
    assert_eq!(dir.entries(), [".convert", ".lock"]);
}

#[test]
fn at_most_three_clips_are_kept() {
    if !usable() {
        return;
    }
    let dir = Dir::new("evict");
    let mut clips = Vec::new();
    for (i, color) in ["red", "green", "blue", "white"].iter().enumerate() {
        let source = dir.make(
            &format!("{color}.mp4"),
            &lavfi(&format!("color=c={color}:size=32x18:rate=10:duration=0.5")),
            &H264,
        );
        let reply = dir.reply("video-convert", &source, (32, 18));
        assert_eq!(reply["ok"], json!(true), "{i}: {reply}");
        clips.push(reply["clip"].as_str().unwrap().to_string());
        // mtimes apart
        std::thread::sleep(Duration::from_millis(20));
    }
    let kept: Vec<String> = dir
        .entries()
        .into_iter()
        .filter(|name| name.ends_with(".mp4"))
        .collect();
    assert_eq!(kept.len(), 3, "{kept:?}");
    assert!(!Path::new(&clips[0]).exists());
    for clip in &clips[1..] {
        assert!(Path::new(clip).exists(), "{clip}");
    }
}
