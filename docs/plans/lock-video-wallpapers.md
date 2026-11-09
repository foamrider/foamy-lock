# Plan: video wallpapers on the lock screen (D8)

Status: revision 1 (2026-11-08); steps 1 to 4 done, step 5 is the user's (see
Progress). Replaces D8 in
[lock-studio-round2.md](lock-studio-round2.md) after the feasibility spike.

## The spike, in short (2026-11-08)

Prototype in the session scratchpad, `video-spike/`. No repo was touched.

- **The sandbox can convert video, in two stages.**
  - Stage A decodes the user's file into raw frames.
  - Stage B encodes only those raw frames, so the lock plays a clip that no
    process reading user bytes produced.
  - Output: H.264 High, yuv420p, 30 fps, at most 60 s, with audio,
    subtitles, metadata and chapters removed.
- **Today's profile blocks ffmpeg:** threads need `clone`. Allowing
  `clone` only with `CLONE_THREAD` and no `CLONE_NEW*` flags, with `clone3`
  returning ENOSYS, works. fork, vfork, unshare, setns, mount, ptrace and
  bpf stay denied.
- **Cost:** a 3440×1440 60 s clip took 30 s wall with 4 threads (18 + 68 s
  CPU) and peaked at 307 and 783 MB. The output was 72 MB.
- **Playback in Quickshell works:**
  - It loops seamlessly and the first frame arrives about 45 ms after
    `play()`.
  - Errors are clean: a corrupt file gives `errorOccurred`.
  - Hardware decode (VAAPI) costs about 1 % of one core.
- **The risk:** decoding happens inside the shell. A decoder crash kills
  the lock client, and the session stays locked behind a dead screen.

## Decisions (user, 2026-11-08)

1. **Use multithreading** for the conversion.
2. **Clear limits**, shown to the user before anything runs.
3. **Picking a video shows a Convert button first.** Nothing converts on
   its own. The lock never converts.
4. **Play is opt-in** (`motion: "play"`); the default is the still frame.
   With Play off, the lock never decodes video.

## Limits

| | Limit |
|---|---|
| Input file | ≤ 2 GiB; MP4/MOV, MKV, WebM; video codecs H.264, HEVC, VP8, VP9, AV1; input ≤ 7680×4320 |
| Length used | the first 60 s (longer videos are cut, and the card says so) |
| Output | H.264, 30 fps (lower sources keep their rate), the largest connected screen's native size capped at 3840×2160, CRF 23 with a bitrate cap, ≤ 150 MiB, no audio or metadata |
| Jobs | one conversion at a time; cancel any time; at most 3 converted clips kept (oldest evicted) |
| Threads | `min(available cores − 2, 16)`, at idle priority (`nice 19`, idle I/O class) so the desktop stays responsive |
| Time | a 10-minute deadline per job; progress reported per frame |
| Memory | `RLIMIT_AS` per stage, measured (see Progress): stage A 768 MiB + 32 MiB per thread + 4 B per source pixel per decoder thread + 32 B per output pixel; stage B 768 MiB + 32 MiB per thread + 12 B per output pixel × (threads + 12); `glibc.malloc.arena_max=1` |

On this machine (20 threads), 3440×1440 for 60 s takes 12 to 15 s with 16
threads (measured in step 2; the 10 s guess was optimistic).

## Flow

1. **Choosing:** in Lock Studio's background page, "Choose picture or
   video…" uses the portal picker, now with video filters. An Omarchy
   wallpaper that is a video shows the same card.
2. **Probe.** The helper's new `video-probe` kind runs in the stage A
   sandbox. It returns duration, size, codec, a poster frame (sandboxed,
   as today) and whether the input is within limits. Nothing outside the
   sandbox parses the file.
3. **The card** shows:
   - the poster;
   - "4 min 12 s · 3840 × 2160 · HEVC · 412 MB";
   - what will happen: "Uses the first 60 s, scaled to 3440 × 1440,
     30 fps, no sound";
   - the estimated time;
   - a **Convert** button.

   Over a limit, the card says which one, and Convert is disabled.
4. **Convert** runs the helper's `video-convert` kind: stage A pipes into
   stage B, both sandboxed, with progress as frames done out of the total.
   The card shows a progress bar and **Cancel**. Cancelling or an error
   leaves nothing behind.
5. **Done:** "Ready · 72 MB". The **Still / Play** switch becomes
   available (Play marked experimental). Applying saves `motion` with the
   look.
6. **The lock:**
   - **When it plays:** only when `motion` is `play` and a converted clip
     for this exact file (content hash) and screen size exists in the
     helper's cache. Otherwise it shows the poster.
   - **How:** poster first; play only with GPU rendering; give up for the
     rest of the lock after the first error or a 2 s stall.
   - **Pausing:** while blanked, with reduced motion on, when not visible,
     and on battery (`pauseOnBattery`, default true).

## Steps

1. **foamy-kit** (its own branch and release, 0.6.0): a `ThreadedDecoder`
   seccomp profile (the clone/clone3 rules above, everything else as
   today). `Bounded` gains stdin from an fd and a byte-counted pipe from
   one child to another, plus nice and ionice settings. Kit tests and a
   changelog. Sync it into foamy-lock only; other plugins sync when they
   need it.
2. **foamy-lock helper:**
   - **New kinds:** `video-probe` and `video-convert`, using the two-stage
     pipeline.
   - **Progress:** through JSON lines.
   - **Cache, limits and cancel:** cache naming, eviction and limits as in
     the table; cancel by signal.
   - **Checks:** stage A must exit 0 and produce a whole number of frames,
     at least one, otherwise the empty MP4 stage B writes is rejected.
   - **Tests:** a small generated test video (lavfi), plus corrupt, too
     long, too large and oversized inputs, and cancel. Never the user's
     files.
   - **Build:** rebuild and pin. Measure the time at 3440×1440 for 60 s.
3. **The lock:**
   - **Format:** `background.motion` and `pauseOnBattery` in Layout.js.
   - **Backdrop:** a `Video` that plays only cache clips, with the poster
     first, the give-up rule and the pausing above.
   - **Tests:** harness cases for the switching logic, using offscreen
     signals. Real GPU playback can't be tested offscreen.
4. **Lock Studio:** the video card, Convert with progress and Cancel, the
   Still/Play switch, the experimental note, and the estimate. Harness
   cases with a fake helper.
5. **Live check by the user:** Preview full screen with Play. Never a real
   lock without the user.

## Risks

- **A decoder crash on the lock screen.**
  - **Mitigations:** opt-in Play, our clips only, give up after one error,
    poster first.
  - **Recovery:** Ctrl+Alt+F3, then `loginctl unlock-session`.
- **A kit release affects every foamy plugin.** The new profile is
  additive; existing profiles don't change.
- **Converting is CPU-heavy**, even at idle priority. It never happens
  without the Convert button.

## Progress

**Step 1** (foamy-kit 0.6.0, `feat/threaded-decoder`): done by the kit;
synced here with `sync.sh` (foamy-helper 0.1.1, `cargo update -p
foamy-helper`), helper rebuilt and pinned (de9edbe).

**Step 2, the helper** (2026-11-08, `feat/layout-engine`; generated videos
only, never the user's):
- **`video-probe`** (stdin `{"path", "width", "height"}`, the largest
  screen's native size): opens the file once (symlinks followed, a regular
  file), reads its first 64 bytes for the container (MP4/MOV `ftyp` or an
  old QuickTime atom, Matroska/WebM's EBML magic; else
  `unsupported-format`), and over 2 GiB stops there. Otherwise ffprobe in
  the stage A sandbox (the file as fd 0, `-fd 0 -i fd:`, the demuxer
  forced, `-select_streams V:0`), the facts read strictly, the limits
  checked, the SHA-256 hashed from the same descriptor, the poster (ffmpeg,
  the first frame cover-scaled to the output, `image::encode_rgb`) and a
  lookup of the clip for this hash and output size. One JSON line: `bytes,
  container, codec, width, height, fps, duration, violations, output
  {width, height, fps, seconds, frames, cut}, threads, estimate, poster,
  clip, clipBytes`. 60 s in all.
- **`video-convert`**: the same checks (a violation fails with its own
  code), then `.convert` (one at a time, else `busy`), the clip at once if
  it exists, else stage A (decode, `fps`, scale and crop, yuv420p raw) piped
  by the kit's Pipeline into stage B (libx264 High, CRF 23 under
  `min(3 bits × pixels, 19 Mbit/s)`, 2 s GOP, no SEI, fragmented MP4 to
  stdout, `-protocol/format/codec_whitelist` rawvideo only), each with its
  own filter memfd, `nice 19`, idle I/O, `min(cores − 2, 16)` threads.
  `{"progress": {"frames", "total"}}` lines at most every 200 ms; SIGTERM
  sets a flag the progress callback answers with Break (both stages killed
  and reaped), `cancelled` within 3 s (else the helper stops hard); 10
  minutes for the stages, 10 s more for the helper. Accepted only when
  stage A exited 0 with a whole number of frames (at least one, at most
  the cut) and stage B exited 0 with an `ftyp` MP4 of at most 150 MiB
  (`decode-failed`, `invalid-frames`, `encode-failed`, `output-too-large`,
  `source-changed`, `job-timeout`). The cache is
  `$XDG_CACHE_HOME/omarchy/foamy.lock/video/` (0700): clips
  `<sha256>-<W>x<H>.mp4` (3, oldest by mtime evicted, never the new one; a
  probe hit touches it), posters `<sha256 of the PNG>.png` (6), staging
  `.job-*`/`.probe-*`, locks `.convert` and `.lock`. The contract is in
  `native/src/main.rs`.
- **Tests:** unit (request, output size, container sniffing, ffprobe
  facts, the plan and cut, violations, threads, names, eviction, the
  command lines, the memory formulas against the peaks below, the
  acceptance checks for partial and missing frames, a failed stage, an
  overflow, a timeout) and `native/tests/video_cli.rs` on lavfi videos: a
  60 fps clip with sound, subtitles and a title (none survive; the clip is
  one H.264 High 30 fps stream), probe → convert → probe finds it, a 65 s
  clip cut to 60 s at its own 5 fps, VP9 WebM, over 2 GiB (sparse), MPEG-4
  (codec), 7696 px wide, truncated and garbled MP4s, a PNG, missing, a
  directory, bad requests, Cancel mid-conversion (nothing left, `busy` for a
  second one meanwhile), four clips → three kept.
- **Measurements** (20 threads, 16 used; the shipped binary; wall time
  includes hashing; VmPeak / VmHWM per stage):

  | Source → output, 60 s | Wall | Stage A | Stage B | Clip |
  |---|---|---|---|---|
  | 1080p30 H.264 → 3440×1440 | 12.4 s | 1223 / 346 MiB, 72 threads | 2342 / 1353 MiB, 43 threads | 73 MB |
  | 2160p60 HEVC → 3440×1440 | 14.4 s | 1583 / 710 MiB | 2292 / 1302 MiB | 66 MB |
  | 2160p60 HEVC → 3840×2160 | 19.6 s | 1526 / 772 MiB | 3194 / 2055 MiB | 111 MB |
  | 2160p60 HEVC → 1920×1080 | 9.8 s | 1502 / 627 MiB | 1492 / 655 MiB | 18 MB |

  The probe of the 139 MB HEVC file takes 0.29 s. Fewer decoder threads
  (4 or 8) saved memory but cost 1 to 3 s, so stage A uses all of them up
  to a 3840×2160 source (fewer above, at least 2). The plan's "768 MiB +
  128 B per output pixel" is 1.4 GiB at 3440×1440, under stage B's 2.3 GiB
  peak (the kit author's out-of-memory); the formulas in Limits leave 20 to
  30 % over each measured peak. The estimate is the slower stage at 45
  megapixels a second per thread for x264 and 210 for the decoder (HEVC;
  H.264 0.6×, VP8 0.8×, VP9 1.2×, AV1 1.5×): 14 s for both 3440×1440 rows.

**Step 3, the lock:**
- **Layout.js:** `background.motion` (`still` default, `play`) and
  `pauseOnBattery` (default true), validated, left out of a look at their
  defaults (`canonicalBackground`, in merge and canonical); a picture path
  may name `.mp4`, `.m4v`, `.mov`, `.mkv` or `.webm` (`isVideoPath`). The
  catalog adds `backgroundMotions` and `backgroundDefaults` (still version
  3, additive).
- **Service:** for the look on screen (the preview's, else the saved one)
  `video-probe` runs while unlocked when it shows a video: a picture
  source's video (its poster is the still, unblurred, so the view blurs it
  live with the GPU like the Omarchy wallpaper), or the Omarchy wallpaper
  when it is a video and the look plays (its still stays Omarchy's
  poster). The size is `Model.videoScreenSize`: Hyprland's monitors (read
  only, `refreshMonitors` on look, preview and screen changes), else the
  logical size. `Model.videoProbeResult` takes a poster and clip only from
  the cache directory, the clip for exactly the reported size. Status adds
  `video {poster, clip, error, failure, request}`.
- **LockView:** `videoPath`, `gpuRendering` (a property so tests can set
  it), `onBattery`; the clip loads (a Loader with
  `elements/VideoBackdrop.qml`, the only QtMultimedia import) only with
  motion play, a clip, GPU rendering and a background shown; it plays
  unless blanked, hidden, motion reduced or on battery with
  pauseOnBattery; the poster stays until the first frame. The first error
  or 2 s without a frame while it should play (loading counts as
  progress) gives up for the view's life (a hidden preview resets).
  Parity unchanged.
- **Tests:** node (the keys, the canonical form, the screen size, the probe
  reply); runtime (the real probe gives the poster, a clip converted with
  the size the lock asked for is found, a broken file keeps the theme
  colour); a `video` harness suite, also run by `render`, on the real view
  with generated clips, offscreen: what loads, poster then frames
  (software playback works offscreen), what pauses it, an error and a
  stall give up once, a hidden preview tries again.

**Step 4, Lock Studio:**
- `studio pick-picture` takes a fourth argument, a "Pictures and videos"
  filter (first and current) with the video MIME types; the button says
  "Choose picture or video…".
- The background page's video card (a picture source's video, or a video
  Omarchy wallpaper): poster, facts, what happens, estimate and Convert;
  progress bar, frames and Cancel; "Ready · N MB"; a limit or a failure
  disables Convert and says why; Motion (Still / Play (experimental),
  enabled once there is a clip, or to go back from Play) and Pause on
  battery. The probe and the conversion use the lock's cache, so the lock
  finds the clip. Draft.js: `videoSource`, `codecLabel`, `duration`,
  `megabytes`, `videoCard`, `videoProgress`, `convertReport`. Strings en and
  no.
- **Tests:** node (`studio-video.test.cjs`), studio harness en/no/ar with a
  fake helper (`fake-shell/foamy-lock-helper`: probe modes ok, codec,
  large, broken; convert ok, slow with SIGTERM, fail): the card, progress
  and Cancel, ready, Play and Pause on battery, limits and errors, a video
  Omarchy wallpaper. Captures `studio-video`, `studio-video-converting`,
  `studio-video-ready`.

**Deviations:**
- The memory limits are per stage and measured (above), not the plan's
  formula.
- ffprobe runs without a codec list (it refuses a whole file whose audio
  codec isn't listed); it is still sandboxed, and the decoding stages keep
  the list.
- The lock finds a clip through `video-probe` (no separate lookup kind),
  which hashes the whole file each time it runs (while unlocked only).
- `Backdrop.qml` stays the drawn sources; the clip is
  `elements/VideoBackdrop.qml`.
- The lock imports `Quickshell.Hyprland` (read only) for the native size.

**Step 5, for the user** (never a real lock without the user):
1. In Lock Studio (it hot-reloads; no new app files), Background → "Choose
   picture or video…", pick a video; check the card and press Convert
   (desktop stays responsive at idle priority; Cancel once to see nothing is
   kept), then Ready, Play (experimental).
2. Preview full screen goes to the running shell's Service.qml: it needs a
   shell running this branch (a shell restart, the user's call). It should
   show the poster, then play within a moment, loop without a seam, and
   hold still with reduced motion or on battery (Pause on battery).
3. Only then a real lock, with the recovery (Ctrl+Alt+F3, `loginctl
   unlock-session`) at hand.
