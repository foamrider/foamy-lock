# Plan: video wallpapers on the lock screen (D8)

Status: revision 1 (2026-11-08). Replaces D8 in
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
| Memory | `RLIMIT_AS` per stage 768 MiB + 128 B per output pixel; `glibc.malloc.arena_max=1` |

On this machine (20 threads), 3440×1440 for 60 s should take roughly 10 s
instead of 30. Step 2 measures it.

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
