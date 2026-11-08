//! The `video` cases (also run by `render`): a video background's switching
//! on the real LockView (see video.qml), with a clip and a broken file this
//! harness generates with ffmpeg's lavfi source, never a user's file. The
//! clip is made the way the helper's stage B makes one (H.264 High, a
//! fragmented MP4, no audio). Offscreen rendering is software, so the cases
//! set the view's `gpuRendering` to reach the GPU path. Plugin QML warnings
//! fail them. Skipped without ffmpeg.

use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::{app, host, styles};

const SHELL: &str = include_str!("video.qml");

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--host" => choice = rest.next().cloned().ok_or(format!("{arg} needs a value"))?,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let mut failed = Vec::new();
    for (name, shell) in &host::selected(&choice)? {
        if let Err(message) = run_host(name, shell) {
            eprintln!("{message}");
            failed.push(name.clone());
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("video failed: {}", failed.join(", ")))
    }
}

pub fn run_host(name: &str, shell: &Path) -> Result<(), String> {
    if !Path::new("/usr/bin/ffmpeg").is_file() {
        println!("SKIP: video cases (no ffmpeg)");
        return Ok(());
    }
    let base = app::temp_dir("foamy-lock-video")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    fs::write(dir.join("shell.qml"), SHELL).map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let clip = base.join("clip.mp4");
    let made = Command::new("/usr/bin/ffmpeg")
        .args(["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i"])
        .args(["testsrc2=size=320x180:rate=30:duration=4", "-c:v", "libx264", "-profile:v", "high"])
        .args(["-pix_fmt", "yuv420p", "-an", "-f", "mp4", "-movflags"])
        .args(["+frag_keyframe+empty_moov+default_base_moof"])
        .arg(&clip)
        .stdin(Stdio::null())
        .status()
        .map_err(app::io("ffmpeg"))?;
    if !made.success() {
        return Err("ffmpeg could not make the test clip".into());
    }
    let corrupt = base.join("corrupt.mp4");
    let mut noise = b"\0\0\0\x20ftypisom\0\0\x02\0isomiso2avc1mp41".to_vec();
    noise.extend((0..65536u32).map(|i| (i.wrapping_mul(2654435761) >> 11) as u8));
    fs::write(&corrupt, noise).map_err(app::io("corrupt.mp4"))?;
    let (clip, corrupt) = (clip.display().to_string(), corrupt.display().to_string());
    let (success, output) = app::run_quickshell_with(
        &base,
        &dir,
        shell,
        "en",
        Duration::from_secs(60),
        &[("FOAMY_VIDEO_CLIP", &clip), ("FOAMY_VIDEO_CORRUPT", &corrupt)],
        &mut |_, _| Ok(()),
    )?;
    for line in output
        .lines()
        .filter(|line| line.contains("video ok") || line.contains("VIDEO_"))
    {
        println!("{line}");
    }
    let warnings = styles::qml_warnings(&output);
    if !success || !output.contains("VIDEO_PASS") || !warnings.is_empty() {
        return Err(format!(
            "video failed ({name} {}){}; log: {}",
            shell.display(),
            warnings
                .iter()
                .map(|line| format!("\n  {line}"))
                .collect::<String>(),
            base.display()
        ));
    }
    Ok(())
}
