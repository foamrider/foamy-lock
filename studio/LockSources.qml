import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model

// What the canvas needs from outside the app, got the way the lock gets it:
//
// - **The Omarchy wallpaper** (source "omarchy"): the helper's `wallpaper`
//   probe resolves `~/.local/state/omarchy/current/background`, as Service
//   does; the view then loads that file itself, as the lock does. A video
//   wallpaper shows the theme colour (the lock's poster frame isn't made
//   here).
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

  // The lock's settings (Model.defaults() until shell.json says otherwise).
  property var settings: Model.defaults()
  property string settingsError: ""

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
      wallpaperPath = ""
      wallpaperError = "video"
      return
    }
    wallpaperError = ""
    if (data.path !== wallpaperPath || data.signature !== wallpaperSignature) {
      wallpaperPath = data.path
      wallpaperSignature = data.signature
      wallpaperVersion += 1
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
    }
    onFileChanged: reload()
    onLoadFailed: sources.settingsError = "unreadable"
  }
}
