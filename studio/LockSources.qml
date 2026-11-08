import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons as Commons
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model
import "Draft.js" as Draft
import "Layout.js" as Layout

// What the canvas needs from outside the app, got the way the lock gets it:
//
// - **The Omarchy wallpaper** (source "omarchy"): the helper's `wallpaper`
//   probe resolves `~/.local/state/omarchy/current/background`, as Service
//   does; the view then loads that file itself, as the lock does. A video
//   wallpaper shows its still frame, made the way the lock makes it: by
//   Omarchy's own `shell/plugins/lock/poster.sh` (one cached frame per
//   video, shared with the lock). Without one (Omarchy 4.0, no
//   ffmpegthumbnailer) the theme colour shows.
// - **The lock's settings** (time format, user info, media): read from the
//   foamy.lock entry in `~/.config/omarchy/shell.json`, read-only (a
//   FileView that is never written), parsed with the lock's own
//   Model.parseConfig. Without one, the lock's defaults.
// - **Your picture** (source "picture"): never decoded here. The helper's
//   sandboxed `artwork` job (kind "background") prepares it at the screen's
//   size and blur, as Service does, into the app's own cache
//   (`$XDG_CACHE_HOME/foamy-lock-studio/picture/…`, so the lock's prepared
//   background is never evicted). Until it is ready the theme colour shows.
// - **Choosing a picture**: `foamy-lock-helper studio pick-picture` (the
//   desktop's file chooser through the portal, with a "Pictures and videos"
//   filter first); picked(path) on a choice.
// - **A video** (a picture source's video, or a video Omarchy wallpaper):
//   never decoded here either. The helper's `video-probe` (facts, limits,
//   the poster the canvas shows, a clip already made) and, only from the
//   card's Convert, `video-convert` (progress lines, Cancel by SIGTERM),
//   both in the helper's sandboxes, at the largest screen's native size,
//   into the lock's own cache (`$XDG_CACHE_HOME/omarchy/foamy.lock/video/`),
//   where the lock looks for the clip.
// - **The saved look**: the same foamy.lock entry (`configEntry`), read the
//   way the lock reads it (Draft.savedEntry).
// - **Screens' native size**: Hyprland's own report of each monitor
//   (`HyprlandMonitor.lastIpcObject`: width, height, scale, transform),
//   read only, refreshed when the screens change or the window shows. Qt
//   only knows the integer wl_output scale, so `devicePixelRatio` would say
//   5504 × 2304 for a 3440 × 1440 screen at 125 %. Outside Hyprland there is
//   none, and the window shows the logical size.
// - **Mugshot** (`/usr/bin/mugshot`, which sets the account's picture and
//   real name that the lock screen shows): whether it is installed (checked
//   when the window shows), so the tip can say how to install it. The app
//   never starts it: tips launch nothing.
// - **Foamy Weather**: whether the lock can reach it, from the lock's own
//   catalog (`foamy.lock catalog` through omarchy-shell, read only;
//   version 3's `weather.target`), asked when the window shows. Unknown
//   (null) until the lock says, so an older lock or one that isn't
//   running never disables the weather.
// - **The app's own state** (`$XDG_STATE_HOME/foamy-lock/studio-state.json`,
//   written atomically here; never in the plugin folder): the last tip seen.
//
// And what goes out, all through the helper's `studio` subcommands
// (native/src/studio), one process per action, the replies turned into
// reports by Draft.js:
// - **The draft on disk**: loadDraft(), saveDraft(history), clearDraft(),
//   run one at a time in order (a newer save or clear replaces one still
//   waiting); draftDone(op, report or error code).
// - **Apply**: applyLook(entry) runs `studio apply` (saveLook through
//   omarchy-shell, one retry when it doesn't answer); applied(report, entry).
// - **Preview full screen**: previewLook(entry) runs the lock's
//   `foamy.lock previewLook` through omarchy-shell itself (the helper has no
//   subcommand for it); previewed(report).
// - **User presets**: runPreset(op, request) runs `studio preset save`,
//   `rename` or `delete` (the lock's savePreset, renamePreset and
//   deletePreset, one retry when it doesn't answer), one at a time;
//   presetDone(op, report, request). The list (`userPresets`) is read from
//   the same foamy.lock entry, and after an operation the lock confirmed it
//   is updated at once (Draft.presetsAfter) until shell.json says so too.
Item {
  id: sources

  // The look the canvas shows (committed), and the screen it is shown at.
  property var look: null
  property int screenWidth: 1920
  property int screenHeight: 1080
  // The window can be seen: probes and preparation run only then.
  property bool active: true

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: FoamyNative.localPath(Qt.resolvedUrl("."))
  readonly property string wallpaperLink: home + "/.local/state/omarchy/current/background"
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || home + "/.cache"
  readonly property string pictureCache: cacheHome + "/foamy-lock-studio/picture"
  readonly property string pictureDirectory: pictureCache + "/omarchy/foamy.lock/background/"

  // The Omarchy wallpaper ("" when there is none, or it is a video).
  property string wallpaperPath: ""
  property string wallpaperSignature: ""
  property int wallpaperVersion: 0
  property string wallpaperError: ""
  property bool wallpaperPending: false
  // A video wallpaper (the probe's path and signature): its still frame
  // becomes wallpaperPath.
  property string videoPath: ""
  property string videoSignature: ""
  readonly property bool wallpaperIsVideo: videoPath !== ""
  property bool posterBusy: false

  // The lock's settings (Model.defaults() until shell.json says otherwise).
  property var settings: Model.defaults()
  property string settingsError: ""
  // The foamy.lock entry (null without one), and whether shell.json has
  // been read (or found missing) at least once.
  property var configEntry: null
  property bool configKnown: false

  // The draft on disk, Apply and Preview.
  // Set when a process is asked to start, cleared when it exits (a
  // Process reports `running` only once it has started).
  property bool applying: false
  property bool previewing: false
  property bool draftRunning: false
  // Nothing waiting or running on the draft file.
  readonly property bool draftIdle: !draftRunning && draftQueue.length === 0
  property var draftQueue: []
  signal draftDone(string op, var result)
  signal applied(var report, var entry)
  signal previewed(var report)

  // User presets (Draft.userPresetsOf): { id, name, look, effective },
  // newest first; the items the lock skips are counted.
  property var userPresets: []
  property int userPresetsInvalid: 0
  property bool presetBusy: false
  signal presetDone(string op, var report, var request)

  // The prepared picture, the source path it was made from, and why not.
  property string picturePath: ""
  property string pictureSource: ""
  property string pictureError: ""
  property string pictureRequest: ""
  property bool picturePending: false
  property bool helperUnavailable: false
  readonly property bool preparing: pictureProc.running
  readonly property string wantedPicture: look && look.background.source === "picture" && !Layout.isVideoPath(look.background.path)
    ? String(look.background.path || "") : ""
  readonly property string pictureKey: wantedPicture ? JSON.stringify({ kind: "background", path: wantedPicture,
    width: Math.max(16, Math.min(7680, screenWidth)), height: Math.max(16, Math.min(4320, screenHeight)),
    blur: look.background.blur }) : ""

  // The background the canvas shows, and whether it is already blurred (a
  // video's poster is not: the canvas blurs it, as the lock does).
  readonly property string backgroundPath: !look ? ""
    : look.background.source === "omarchy" ? wallpaperPath
    : pictureIsVideo ? (videoProbe && videoProbeKey === clipKey ? videoProbe.poster : "")
    : wantedPicture && pictureSource === wantedPicture ? picturePath : ""
  readonly property bool backgroundPrepared: !!look && look.background.source === "picture" && !pictureIsVideo
  readonly property int backgroundVersion: wallpaperVersion

  // --- video backgrounds ------------------------------------------------------
  // The video the look shows (Draft.videoSource: a picture source's video,
  // or the Omarchy wallpaper when it is one), never decoded here: the
  // helper's video-probe (facts, limits, poster, a clip already made) and,
  // only from convertVideo(), video-convert, both in the helper's sandboxes
  // at the largest screen's native size, into the lock's own cache
  // (`$XDG_CACHE_HOME/omarchy/foamy.lock/video/`), where the lock looks for
  // the clip. One conversion at a time; cancelConvert() stops it (SIGTERM)
  // and nothing is kept. `videoHelper` is the tests' stand-in for the
  // helper ("" is the bundled one).
  property string videoHelper: ""
  readonly property bool pictureIsVideo: !!look && look.background.source === "picture" && Layout.isVideoPath(look.background.path)
  readonly property string clipSource: Draft.videoSource(look, videoPath)
  readonly property var videoSize: {
    var natives = []
    for (var name in nativeMonitors) natives.push(nativeMonitors[name])
    return Model.videoScreenSize(natives, Quickshell.screens || [])
  }
  readonly property string clipKey: clipSource ? JSON.stringify({ path: clipSource, width: videoSize[0], height: videoSize[1] }) : ""
  readonly property string videoDirectory: cacheHome + "/omarchy/foamy.lock/video/"
  // Model.videoProbeResult for videoProbeKey (null while it runs).
  property var videoProbe: null
  property string videoProbeKey: ""
  property bool videoProbePending: false
  // The conversion: running, for which key, its frames, how it ended.
  property bool converting: false
  property string convertKey: ""
  property var convertProgress: null
  property string convertError: ""
  property string convertedClip: ""
  property real convertedBytes: 0
  // The clip for the video on the canvas ("" without), and its size.
  readonly property string clip: videoProbe && videoProbeKey === clipKey && videoProbe.clip ? videoProbe.clip
    : convertKey === clipKey && convertedClip ? convertedClip : ""
  readonly property real clipBytes: clip === "" ? 0
    : clip === convertedClip ? convertedBytes : Number(videoProbe.reply.clipBytes) || 0
  signal converted(var report)

  // Native pixels and scale per Hyprland monitor name (Draft.monitorEntries).
  readonly property bool hyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") !== ""
  readonly property var nativeMonitors: {
    var out = {}
    var monitors = hyprland ? Hyprland.monitors.values : []
    for (var i = 0; i < monitors.length; i++) {
      var ipc = monitors[i].lastIpcObject
      if (!monitors[i].name || !ipc) continue
      out[monitors[i].name] = { width: Number(ipc.width) || 0, height: Number(ipc.height) || 0,
        scale: Number(ipc.scale) || 1, transform: Number(ipc.transform) || 0 }
    }
    return out
  }

  // Mugshot: where it is, and whether it is there (the test points it
  // elsewhere).
  property string mugshotPath: "/usr/bin/mugshot"
  property bool mugshotAvailable: false
  // Set when the check is asked for, cleared when it answers.
  property bool mugshotChecking: false

  // Foamy Weather as the lock sees it: true or false once its catalog
  // has said, null before (see the header).
  property var weatherTarget: null
  property bool catalogChecking: false

  // The app's state: the last tip seen ("" until read, or without one).
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string statePath: stateHome + "/foamy-lock/studio-state.json"
  property string tip: ""
  property bool stateKnown: false

  // Choosing a picture.
  property bool picking: false
  property string pickError: ""
  signal picked(string path)

  onActiveChanged: if (active) {
    refreshWallpaper()
    refreshPicture()
    refreshVideo()
    refreshMonitors()
    checkMugshot()
    checkCatalog()
  }
  onPictureKeyChanged: pictureDebounce.restart()
  onClipKeyChanged: videoDebounce.restart()
  Component.onCompleted: {
    refreshWallpaper()
    checkMugshot()
    checkCatalog()
  }

  Connections {
    target: Quickshell
    function onScreensChanged() { sources.refreshMonitors() }
  }

  // Hyprland's monitors again (a read-only query: scale or mode changes).
  function refreshMonitors() {
    if (hyprland) Hyprland.refreshMonitors()
  }

  function checkMugshot() {
    if (mugshotChecking) return
    mugshotChecking = true
    mugshotProbe.running = true
  }

  function checkCatalog() {
    if (catalogChecking) return
    catalogChecking = true
    catalogProc.running = true
  }

  // The lock's catalog (also a test hook): only a version 3 catalog with
  // a yes or no changes what is known; anything else keeps it.
  function applyCatalog(exitCode, text) {
    catalogChecking = false
    if (exitCode !== 0) return
    var data = Draft.replyOf(text)
    if (data && data.version >= 3 && data.weather && typeof data.weather.target === "boolean") weatherTarget = data.weather.target
  }

  // The last tip seen, kept for the next start.
  function setTip(id) {
    if (!/^[a-z-]{1,32}$/.test(String(id)) || id === tip) return
    tip = id
    stateFile.setText(JSON.stringify({ version: 1, tip: id }) + "\n")
  }

  // The state file's text (also a test hook): a version 1 object.
  function applyState(text) {
    var data = null
    try { data = JSON.parse(String(text || "")) } catch (error) { data = null }
    if (data && data.version === 1 && typeof data.tip === "string" && /^[a-z-]{1,32}$/.test(data.tip)) tip = data.tip
    stateKnown = true
  }

  Connections {
    target: Commons.Color
    function onCurrentThemePathChanged() { sources.refreshWallpaper() }
  }

  function refreshWallpaper() {
    if (helperUnavailable) return
    if (wallpaperProc.running) {
      wallpaperPending = true
      return
    }
    wallpaperPending = false
    wallpaperProc.running = true
  }

  // The probe's answer (also a test hook).
  function applyWallpaper(exitCode, text) {
    var data = null
    if (FoamyNative.unavailable(exitCode)) helperUnavailable = true
    else if (exitCode === 0) {
      try { data = JSON.parse(String(text || "")) } catch (error) { data = null }
    }
    if (!data || data.ok !== true || typeof data.path !== "string" || data.path[0] !== "/"
        || typeof data.signature !== "string" || data.signature === "") {
      wallpaperPath = ""
      wallpaperError = helperUnavailable ? "helper-unavailable" : data && typeof data.error === "string" ? data.error : "wallpaper-unavailable"
      return
    }
    if (Model.isVideoPath(data.path)) {
      // Its still frame, made as the lock makes it (until then, the theme
      // colour). "video" while there is none.
      wallpaperError = "video"
      if (data.path !== videoPath || data.signature !== videoSignature) {
        videoPath = data.path
        videoSignature = data.signature
        wallpaperPath = ""
        refreshPoster()
      }
      return
    }
    videoPath = ""
    videoSignature = ""
    wallpaperError = ""
    if (data.path !== wallpaperPath || data.signature !== wallpaperSignature) {
      wallpaperPath = data.path
      wallpaperSignature = data.signature
      wallpaperVersion += 1
    }
  }

  function refreshPoster() {
    if (!videoPath || posterBusy) return
    posterBusy = true
    posterProc.sourcePath = videoPath
    posterProc.sourceSignature = videoSignature
    posterProc.running = true
  }

  // poster.sh's answer for the video at `path` with `signature` (also a test
  // hook): a still image's path, else the theme colour stays.
  function applyPoster(exitCode, text, path, signature) {
    // The wallpaper changed meanwhile: never show the previous one's frame.
    if (path !== videoPath || signature !== videoSignature) {
      refreshPoster()
      return
    }
    var poster = String(text || "").trim()
    if (exitCode === 0 && poster[0] === "/" && poster.indexOf("\n") === -1 && !Model.isVideoPath(poster)) {
      wallpaperError = ""
      wallpaperPath = poster
      wallpaperSignature = signature
      wallpaperVersion += 1
    } else {
      wallpaperPath = ""
      wallpaperError = "video"
    }
  }

  function refreshPicture() {
    var key = pictureKey
    if (!key) {
      pictureRequest = ""
      pictureError = ""
      return
    }
    if (key === pictureRequest || !active) return
    if (pictureProc.running) {
      picturePending = true
      return
    }
    pictureRequest = key
    if (helperUnavailable) {
      applyPicture(127, "")
      return
    }
    pictureProc.request = key
    pictureProc.stdinEnabled = true
    pictureProc.running = true
  }

  // The helper's answer for `request` (also a test hook).
  function applyPicture(exitCode, text, request) {
    var asked = request === undefined ? pictureRequest : request
    var path = ""
    try { path = JSON.parse(asked).path } catch (error) { path = "" }
    var result = null
    if (FoamyNative.unavailable(exitCode)) helperUnavailable = true
    else {
      try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
    }
    if (result && result.ok === true && typeof result.path === "string" && result.path.indexOf(pictureDirectory) === 0
        && /^[0-9a-f]{64}\.png$/.test(result.path.slice(pictureDirectory.length))) {
      pictureError = ""
      picturePath = result.path
      pictureSource = path
    } else {
      pictureError = helperUnavailable ? "helper-unavailable"
        : result && typeof result.error === "string" && /^[a-z-]{1,48}$/.test(result.error) ? result.error : "picture-helper-failed"
      if (pictureSource === path) {
        picturePath = ""
        pictureSource = ""
      }
    }
  }

  function pick() {
    if (pickProc.running) return
    pickError = ""
    picking = true
    pickProc.running = true
  }

  // The picker's answer (also a test hook): picked(path), "" when the
  // dialog was closed, or pickError set to a code.
  function applyPick(exitCode, text) {
    picking = false
    var data = null
    try { data = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (error) { data = null }
    if (FoamyNative.unavailable(exitCode)) {
      pickError = "helper-unavailable"
    } else if (exitCode === 0 && data && data.ok === true && data.cancelled === true) {
      pickError = ""
    } else if (exitCode === 0 && data && data.ok === true && typeof data.path === "string") {
      pickError = ""
      picked(data.path)
    } else {
      pickError = data && typeof data.code === "string" && /^[A-Z_]{1,40}$/.test(data.code) ? data.code : "FAILED"
    }
  }

  // --- video ------------------------------------------------------------------

  function videoCommand(kind) {
    return videoHelper ? [videoHelper, kind] : FoamyNative.command(pluginDir, "foamy-lock-helper", [kind])
  }

  // Probes the video on the canvas (once per file and size, while the
  // window can be seen).
  function refreshVideo() {
    var key = clipKey
    if (!key) {
      videoProbe = null
      videoProbeKey = ""
      return
    }
    if (key === videoProbeKey || !active) return
    if (videoProbeProc.running) {
      videoProbePending = true
      return
    }
    videoProbeKey = key
    videoProbe = null
    if (helperUnavailable && !videoHelper) {
      applyVideoProbe(127, "", key)
      return
    }
    videoProbeProc.request = key
    videoProbeProc.stdinEnabled = true
    videoProbeProc.running = true
  }

  // video-probe's answer for `request` (also a test hook).
  function applyVideoProbe(exitCode, text, request) {
    if (request !== videoProbeKey) return
    if (FoamyNative.unavailable(exitCode)) {
      if (!videoHelper) helperUnavailable = true
      videoProbe = Model.videoProbeResult('{"ok":false,"error":"helper-unavailable"}', videoDirectory)
    } else {
      videoProbe = Model.videoProbeResult(exitCode === 0 ? text : "", videoDirectory)
    }
  }

  // Converts the video on the canvas: the Convert button, never on its own.
  function convertVideo() {
    if (converting || !clipKey) return false
    convertKey = clipKey
    convertProgress = null
    convertError = ""
    convertedClip = ""
    convertedBytes = 0
    videoConvertProc.lastLine = ""
    videoConvertProc.request = clipKey
    videoConvertProc.stdinEnabled = true
    converting = true
    videoConvertProc.running = true
    return true
  }

  // Cancel: the helper stops both stages and keeps nothing.
  function cancelConvert() {
    if (videoConvertProc.running) videoConvertProc.signal(15)
  }

  // One line of video-convert's output (also a test hook).
  function applyConvertLine(line) {
    var progress = Draft.videoProgress(line)
    if (progress) convertProgress = progress
  }

  // video-convert's end (also a test hook): its last line.
  function applyConvert(exitCode, text, request) {
    converting = false
    var report = Draft.convertReport(exitCode, text, videoDirectory)
    if (request !== convertKey) return
    convertError = report.ok ? "" : report.error
    if (report.ok) {
      convertedClip = report.clip
      convertedBytes = report.bytes
      // The probe finds it from now on.
      if (videoProbeKey === request) videoProbeKey = ""
      refreshVideo()
    }
    converted(report)
  }

  // --- the draft on disk ------------------------------------------------------

  function loadDraft() { queueDraft({ op: "draft-load", request: "" }) }
  function saveDraft(h) { queueDraft({ op: "draft-save", request: JSON.stringify(Draft.diskDraft(h)) }) }
  function clearDraft() { queueDraft({ op: "draft-clear", request: "" }) }

  function queueDraft(job) {
    var queue = draftQueue.slice()
    var last = queue.length > 0 ? queue[queue.length - 1] : null
    // A newer save or clear makes one still waiting pointless.
    if (last && last.op !== "draft-load" && job.op !== "draft-load") queue.pop()
    queue.push(job)
    draftQueue = queue
    runDraft()
  }

  function runDraft() {
    if (draftRunning || draftQueue.length === 0) return
    var job = draftQueue[0]
    draftQueue = draftQueue.slice(1)
    draftProc.op = job.op
    draftProc.request = job.request
    draftProc.stdinEnabled = job.request !== ""
    draftRunning = true
    draftProc.running = true
  }

  // The helper's answer to `op` (also a test hook): a Draft.loadReport for
  // draft-load, else Draft.draftError's code ("" when done).
  function applyDraft(op, exitCode, text) {
    draftDone(op, op === "draft-load" ? Draft.loadReport(exitCode, text) : Draft.draftError(exitCode, text))
  }

  // --- Apply and Preview ------------------------------------------------------

  function applyLook(entry) {
    if (applying) return false
    applyProc.entry = Draft.ordered(entry)
    applyProc.request = JSON.stringify(applyProc.entry)
    applyProc.stdinEnabled = true
    applying = true
    applyProc.running = true
    return true
  }

  // The helper's answer (also a test hook).
  function applyApply(exitCode, text, entry) {
    applied(Draft.applyReport(exitCode, text), entry)
  }

  function previewLook(entry) {
    if (previewing) return false
    previewProc.look = JSON.stringify(Draft.ordered(entry))
    previewing = true
    previewProc.running = true
    return true
  }

  // omarchy-shell's answer (also a test hook).
  function applyPreview(exitCode, stdout, stderr) {
    previewed(Draft.previewReport(exitCode, stdout, stderr))
  }

  // --- user presets ------------------------------------------------------------

  // `op` is "save" ({ id, name, look }), "rename" ({ id, name }) or
  // "delete" ({ id }).
  function runPreset(op, request) {
    if (presetBusy || ["save", "rename", "delete"].indexOf(op) === -1) return false
    presetProc.op = op
    presetProc.payload = request
    presetProc.request = JSON.stringify(request)
    presetProc.stdinEnabled = true
    presetBusy = true
    presetProc.running = true
    return true
  }

  // The helper's answer (also a test hook): a Draft.applyReport.
  function applyPresetReply(op, exitCode, text, request) {
    var report = Draft.applyReport(exitCode, text)
    if (report.saved) userPresets = Draft.presetsAfter(userPresets, op, request)
    presetDone(op, report, request)
  }

  Process {
    id: draftProc
    property string op: ""
    property string request: ""
    command: ["timeout", "--kill-after=1s", "10s"].concat(FoamyNative.command(sources.pluginDir, "foamy-lock-helper", ["studio", op]))
    onStarted: {
      if (request === "") return
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: draftOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.draftRunning = false
      sources.applyDraft(draftProc.op, exitCode, draftOutput.text)
      sources.runDraft()
    }
  }

  // `studio apply` waits up to 6 s for each of at most two calls, a second
  // apart.
  Process {
    id: applyProc
    property var entry: null
    property string request: ""
    command: ["timeout", "--kill-after=1s", "20s"].concat(FoamyNative.command(sources.pluginDir, "foamy-lock-helper", ["studio", "apply"]))
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: applyOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.applying = false
      sources.applyApply(exitCode, applyOutput.text, applyProc.entry)
    }
  }

  // `studio preset` waits as `studio apply` does.
  Process {
    id: presetProc
    property string op: "save"
    property var payload: null
    property string request: ""
    command: ["timeout", "--kill-after=1s", "20s"].concat(FoamyNative.command(sources.pluginDir, "foamy-lock-helper", ["studio", "preset", op]))
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: presetOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.presetBusy = false
      sources.applyPresetReply(presetProc.op, exitCode, presetOutput.text, presetProc.payload)
    }
  }

  // omarchy-shell from PATH, else Omarchy's own (where the helper looks
  // too), with OMARCHY_PATH set when it isn't. A missing one exits 127.
  Process {
    id: previewProc
    property string look: ""
    command: ["timeout", "--kill-after=1s", "6s", "bash", "-c",
      'export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"; shell=$(command -v omarchy-shell) || shell="$OMARCHY_PATH/bin/omarchy-shell"; exec -- "$shell" foamy.lock previewLook "$1"',
      "foamy-lock-studio-preview", look]
    stdout: StdioCollector { id: previewOutput; waitForEnd: true }
    stderr: StdioCollector { id: previewErrors; waitForEnd: true }
    onExited: function(exitCode) {
      sources.previewing = false
      sources.applyPreview(exitCode, previewOutput.text, previewErrors.text)
    }
  }

  // The same omarchy-shell as Preview; the catalog is read only.
  Process {
    id: catalogProc
    command: ["timeout", "--kill-after=1s", "6s", "bash", "-c",
      'export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"; shell=$(command -v omarchy-shell) || shell="$OMARCHY_PATH/bin/omarchy-shell"; exec -- "$shell" foamy.lock catalog',
      "foamy-lock-studio-catalog"]
    stdout: StdioCollector { id: catalogOutput; waitForEnd: true }
    onExited: function(exitCode) { sources.applyCatalog(exitCode, catalogOutput.text) }
  }

  Timer {
    id: pictureDebounce
    interval: 250
    onTriggered: sources.refreshPicture()
  }

  Timer {
    id: videoDebounce
    interval: 250
    onTriggered: sources.refreshVideo()
  }

  Process {
    id: videoProbeProc
    property string request: ""
    // The helper's own limit is 60 s.
    command: ["timeout", "--kill-after=1s", "65s"].concat(sources.videoCommand("video-probe"))
    clearEnvironment: true
    environment: ({ HOME: sources.home, XDG_CACHE_HOME: sources.cacheHome, PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: videoProbeOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.applyVideoProbe(exitCode, videoProbeOutput.text, videoProbeProc.request)
      if (sources.videoProbePending) {
        sources.videoProbePending = false
        sources.refreshVideo()
      }
    }
  }

  // The helper stops a conversion after 10 minutes; this is the backstop.
  // SIGTERM (Cancel) reaches it through timeout and the exec.
  Process {
    id: videoConvertProc
    property string request: ""
    property string lastLine: ""
    command: ["timeout", "--kill-after=5s", "630s"].concat(sources.videoCommand("video-convert"))
    clearEnvironment: true
    environment: ({ HOME: sources.home, XDG_CACHE_HOME: sources.cacheHome, PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: SplitParser {
      onRead: function(data) {
        videoConvertProc.lastLine = data
        sources.applyConvertLine(data)
      }
    }
    onExited: function(exitCode) { sources.applyConvert(exitCode, videoConvertProc.lastLine, videoConvertProc.request) }
  }

  Process {
    id: wallpaperProc
    command: ["timeout", "--kill-after=1s", "2s"].concat(FoamyNative.command(sources.pluginDir, "foamy-lock-helper",
      ["wallpaper", sources.wallpaperLink]))
    clearEnvironment: true
    environment: ({ PATH: "/usr/bin", LANG: "C.UTF-8" })
    stdout: StdioCollector { id: wallpaperOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.applyWallpaper(exitCode, wallpaperOutput.text)
      if (sources.wallpaperPending) sources.refreshWallpaper()
    }
  }

  // Omarchy's own still-frame maker, as Service runs it for the lock (4.5;
  // 4.0 has none, exit 69). Its cache is the lock's: one frame per video.
  Process {
    id: posterProc
    property string sourcePath: ""
    property string sourceSignature: ""
    command: ["timeout", "--kill-after=1s", "16s", "bash", "-c",
      '[[ -f $1 ]] || exit 69; exec bash "$1" "$2"', "foamy-lock-poster",
      (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell/plugins/lock/poster.sh", sourcePath]
    stdout: StdioCollector { id: posterOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.posterBusy = false
      sources.applyPoster(exitCode, posterOutput.text, posterProc.sourcePath, posterProc.sourceSignature)
    }
  }

  Process {
    id: pictureProc
    property string request: ""
    // The helper's own job limit is 9 s.
    command: ["timeout", "--kill-after=1s", "12s"].concat(FoamyNative.command(sources.pluginDir, "foamy-lock-helper", ["artwork"]))
    clearEnvironment: true
    environment: ({ HOME: sources.home, XDG_CACHE_HOME: sources.pictureCache, PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(pictureProc.request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: pictureOutput; waitForEnd: true }
    onExited: function(exitCode) {
      sources.applyPicture(exitCode, pictureOutput.text, pictureProc.request)
      if (sources.picturePending) {
        sources.picturePending = false
        sources.refreshPicture()
      }
    }
  }

  Process {
    id: pickProc
    command: FoamyNative.command(sources.pluginDir, "foamy-lock-helper",
      ["studio", "pick-picture", FoamyI18n.t("studio.pick.title"), FoamyI18n.t("studio.pick.filter"),
        FoamyI18n.t("studio.pick.media")])
    stdout: StdioCollector { id: pickOutput; waitForEnd: true }
    onExited: function(exitCode) { sources.applyPick(exitCode, pickOutput.text) }
  }

  Process {
    id: mugshotProbe
    command: ["test", "-x", sources.mugshotPath]
    onExited: function(exitCode) {
      sources.mugshotAvailable = exitCode === 0
      sources.mugshotChecking = false
    }
  }

  FileView {
    id: stateFile
    path: sources.statePath
    printErrors: false
    atomicWrites: true
    onLoaded: sources.applyState(text())
    onLoadFailed: sources.stateKnown = true
  }

  // Read only: nothing here ever writes shell.json.
  FileView {
    id: config
    path: sources.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var result = Model.parseConfig(text())
      sources.settingsError = result.error
      if (result.valid) sources.settings = result.settings
      sources.configEntry = result.entry || null
      var presets = Draft.userPresetsOf(result.entry)
      sources.userPresets = presets.presets
      sources.userPresetsInvalid = presets.invalid
      sources.configKnown = true
    }
    onFileChanged: reload()
    onLoadFailed: {
      sources.settingsError = "unreadable"
      sources.configEntry = null
      sources.userPresets = []
      sources.userPresetsInvalid = 0
      sources.configKnown = true
    }
  }
}
