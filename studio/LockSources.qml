import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model
import "Draft.js" as Draft

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
//   desktop's file chooser through the portal); picked(path) on a choice.
// - **The saved look**: the same foamy.lock entry (`configEntry`), read the
//   way the lock reads it (Draft.savedEntry).
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

  // The prepared picture, the source path it was made from, and why not.
  property string picturePath: ""
  property string pictureSource: ""
  property string pictureError: ""
  property string pictureRequest: ""
  property bool picturePending: false
  property bool helperUnavailable: false
  readonly property bool preparing: pictureProc.running
  readonly property string wantedPicture: look && look.background.source === "picture" ? String(look.background.path || "") : ""
  readonly property string pictureKey: wantedPicture ? JSON.stringify({ kind: "background", path: wantedPicture,
    width: Math.max(16, Math.min(7680, screenWidth)), height: Math.max(16, Math.min(4320, screenHeight)),
    blur: look.background.blur }) : ""

  // The background the canvas shows, and whether it is already blurred.
  readonly property string backgroundPath: !look ? ""
    : look.background.source === "omarchy" ? wallpaperPath
    : wantedPicture && pictureSource === wantedPicture ? picturePath : ""
  readonly property bool backgroundPrepared: !!look && look.background.source === "picture"
  readonly property int backgroundVersion: wallpaperVersion

  // Choosing a picture.
  property bool picking: false
  property string pickError: ""
  signal picked(string path)

  onActiveChanged: if (active) {
    refreshWallpaper()
    refreshPicture()
  }
  onPictureKeyChanged: pictureDebounce.restart()
  Component.onCompleted: refreshWallpaper()

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

  Timer {
    id: pictureDebounce
    interval: 250
    onTriggered: sources.refreshPicture()
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
      ["studio", "pick-picture", FoamyI18n.t("studio.pick.title"), FoamyI18n.t("studio.pick.filter")])
    stdout: StdioCollector { id: pickOutput; waitForEnd: true }
    onExited: function(exitCode) { sources.applyPick(exitCode, pickOutput.text) }
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
      sources.configKnown = true
    }
    onFileChanged: reload()
    onLoadFailed: {
      sources.settingsError = "unreadable"
      sources.configEntry = null
      sources.configKnown = true
    }
  }
}
