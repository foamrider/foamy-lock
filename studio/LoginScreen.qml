import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model
import "Layout.js" as Layout
import "Login.js" as Login

// The login screen's copy of the lock look (docs/plans/lock-login-screen.md,
// "Steps 4 and 5 contract"): every process of it, one at a time, and the
// state they report. Login.js checks each reply.
//
// - **Check** (refresh(): when the window shows, after each operation,
//   and when the applied look or its inputs change, the lock's rendered
//   avatar and its source photo included): `foamy-lock-helper
//   studio login-screen status`. When Foamy's theme is in use, the
//   applied look is prepared and staged too (below), and the stage's hash
//   compared with the installed one: "matches" or "out of date".
// - **Copy** (copy(), after the dialog): first the lock's own `status`
//   (`omarchy-shell foamy.lock status`, bounded as the catalog call is)
//   for the avatar it shows now and the photo it comes from
//   (Login.lockAvatarReport). Then the
//   pictures, made by the helper's sandboxed `artwork` kinds into Studio's
//   own folder (`$XDG_CACHE_HOME/foamy-lock-studio/login`, so neither the
//   lock's cache nor the canvas's picture is evicted or locked): for a
//   look that shows a picture a `background` (the Omarchy wallpaper, the
//   picture, or a video's still frame from the helper's `video-probe`) at
//   the largest screen's size, capped at 3840 × 2160, with the look's
//   blur; and the `avatar` re-made from the lock's `avatarRenderPath`
//   (empty: no avatar, even when an old avatar.png is still in the lock's
//   cache; no usable answer: the copy stops, it never guesses). Then
//   `studio login-screen stage` with the applied look (the
//   colours from Commons, the language), then the publisher
//   `sddm/foamy-lock-login-screen publish <dir>`, which asks for the
//   password through pkexec, then `status` again: the result counts only
//   when status agrees (Login.confirmed).
// - **Restore** (restore(), after its dialog): the publisher's `restore`,
//   then `status` again. Offered whenever Foamy's theme folder or drop-in
//   is there (status `managed`), also when SDDM doesn't use them.
//
// One operation runs at a time (`op`); a check asked for meanwhile runs
// after it. Each step has a deadline; the publisher's is 30 minutes, as
// long as the password prompt may stay open. Quitting stops the running
// step: Quickshell ends the Process, and `timeout` passes SIGTERM on to
// the command's process group. `helper` and `publisher` are the tests'
// stand-ins ("" is the bundled helper and the plugin's publisher).
Item {
  id: login

  // The applied look entry (the lock's saved look), the lock's settings,
  // the Omarchy wallpaper (its path, a key that changes with it, and
  // whether it is a video: its still is then `wallpaperPath`), and the
  // largest screen's native size.
  property var entry: ({
      preset: Layout.DEFAULT_PRESET
    })
  property var settings: Model.defaults()
  property string wallpaperPath: ""
  property string wallpaperKey: ""
  property bool wallpaperIsVideo: false
  property var screenSize: [1920, 1080]
  // The window can be seen: checks run only then.
  property bool active: true
  property string helper: ""
  property string publisher: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: FoamyNative.localPath(Qt.resolvedUrl("."))
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || home + "/.cache"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string loginCache: cacheHome + "/foamy-lock-studio/login"
  // Where the lock renders the avatar, and the photo it renders it from
  // (`avatarPath` in the lock's last status, "" before one): both watched,
  // so a changed, replaced or removed photo makes the comparison old
  // (`avatarRevision` is in `key`). The lock clears its render path for a
  // removed photo without touching avatar.png, so the render alone misses
  // that.
  readonly property string lockAvatar: cacheHome + "/omarchy/foamy.lock/avatar.png"
  property string lockAvatarSource: ""
  property int avatarRevision: 0
  readonly property string videoDirectory: cacheHome + "/omarchy/foamy.lock/video/"

  // The last `status` (Login.statusReport, ok) and the last failure's code
  // ("" after a good answer).
  property var status: null
  property string statusError: ""
  // A fresh stage's hash and the inputs it was made from (`key`); the
  // compare's failure code when it couldn't stage.
  property string compareHash: ""
  property string compareKey: ""
  property string compareError: ""
  // "" (idle), "check", "copy" or "restore"; the step running.
  property string op: ""
  property string step: ""
  // A copy or restore confirmed while a check ran: it runs next.
  property string queued: ""
  readonly property bool busy: op !== "" || queued !== ""
  // A check asked for while busy.
  property bool pending: false
  // The last copy or restore: { action, outcome: "done" | "cancelled" |
  // "denied" | "failed" | "unconfirmed", code, before, state }, or null.
  // `before`: it failed before anything was sent to the publisher;
  // `state`: the section's state it left, which it describes (a later
  // change of state makes it old news).
  property var result: null

  // The lock's own view (the canvas's LockView, as `app` is passed
  // elsewhere): its theme and [lock] colours and which of them the theme
  // sets (`lockThemed`), as the lock reads them.
  property var lockView: null
  // The colours `stage` takes: the view's, the popup surface
  // (FoamyPalette's background and text, and Commons' popup border) and
  // FoamyPalette's status colours.
  readonly property var colors: !lockView ? ({}) : ({
      background: lockView.themeBackground,
      foreground: lockView.themeForeground,
      accent: lockView.accent,
      muted: lockView.themeMuted,
      urgent: lockView.themeUrgent,
      lockBackground: lockView.lockBackground,
      lockBorder: lockView.lockBorder,
      lockBorderError: lockView.lockBorderError,
      lockPlaceholder: lockView.lockPlaceholder,
      lockSelection: lockView.lockSelection,
      lockText: lockView.lockText,
      lockTextError: lockView.lockTextError,
      popupsBackground: FoamyPalette.background,
      popupsBorder: popupBorder,
      popupsText: FoamyPalette.text,
      warning: FoamyPalette.warning,
      success: FoamyPalette.success,
      error: FoamyPalette.error,
      info: FoamyPalette.info
    })
  // Commons.Color.popups is a plain QtObject to qmllint (Color.qml types
  // the group so), so its border is read through `var`.
  readonly property var popupGroup: Commons.Color.popups
  readonly property color popupBorder: popupGroup.border
  readonly property var lockThemed: lockView ? lockView.lockThemed : []
  readonly property var look: {
    var parsed = Layout.parseLook(entry)
    return parsed.valid ? parsed.look : null
  }
  readonly property bool showsPicture: Login.showsPicture(look)
  readonly property var size: Login.pictureSize(screenSize[0], screenSize[1])
  // Everything a stage is made from: a stage made from another key is
  // out of date.
  readonly property string key: JSON.stringify({
    entry: entry,
    timeFormat: settings.timeFormat,
    showUserInfo: settings.showUserInfo,
    wallpaper: showsPicture && look.background.source === "omarchy" ? wallpaperKey : "",
    avatar: avatarRevision,
    size: showsPicture ? size : null,
    colors: Object.keys(colors).map(function (name) {
      return String(colors[name])
    }),
    lockThemed: lockThemed,
    language: FoamyI18n.language,
    formatLocale: FoamyI18n.formatLocale,
    rightToLeft: FoamyI18n.rightToLeft
  })
  // The compared hash, only for the inputs as they are now.
  readonly property string currentHash: compareKey === key ? compareHash : ""
  // Login.sectionState: "hidden", "checking", "error", "not-installed",
  // "current", "outdated", "installed", "overridden" or "broken".
  readonly property string sectionState: Login.sectionState(status, statusError, currentHash)
  readonly property var leftOut: Login.leftOut(look, wallpaperIsVideo)
  // What the section's buttons offer (Copy is disabled while the login
  // screen matches; a copy confirmed during a check runs even then).
  readonly property bool copyPossible: !!look && ["hidden", "checking", "error"].indexOf(sectionState) === -1
  readonly property bool restorePossible: Login.restoreOffered(sectionState, status)
  readonly property bool canCopy: !busy && copyPossible && sectionState !== "current"
  readonly property bool canRestore: !busy && restorePossible

  onActiveChanged: if (active)
    refresh()
  onKeyChanged: if (status && status.state === "installed")
    keyDebounce.restart()
  Component.onCompleted: refresh()

  Timer {
    id: keyDebounce
    interval: 800
    onTriggered: login.refresh()
  }

  // --- operations ------------------------------------------------------------

  // The job in hand: the inputs it started from, its pictures and stage.
  property var job: null

  function refresh() {
    if (!active)
      return
    if (busy) {
      pending = true
      return
    }
    pending = false
    op = "check"
    job = null
    runStatus()
  }

  function copy() {
    return start("copy", canCopy)
  }

  function restore() {
    return start("restore", canRestore)
  }

  // `allowed`: what the buttons allow now. Confirmed during a check, the
  // action waits for it, then runs if the new state still offers it.
  function start(action, allowed) {
    if (op === "check" && queued === "") {
      queued = action
      return true
    }
    if (!allowed)
      return false
    op = action
    result = null
    job = null
    if (action === "copy")
      prepare()
    else
      runPublisher("restore", "")
    return true
  }

  // The operation ends: one place, whatever happened.
  function finish(outcome, code, before) {
    if (op === "copy" || op === "restore")
      result = {
        action: op,
        outcome: outcome,
        code: code || "",
        before: before === true,
        state: sectionState
      }
    op = ""
    step = ""
    job = null
    var next = queued
    queued = ""
    if (next !== "" && !start(next, next === "copy" ? copyPossible : restorePossible))
      result = {
        action: next,
        outcome: "failed",
        code: "not-possible",
        before: true,
        state: sectionState
      }
    else if (next === "" && pending)
      Qt.callLater(refresh)
  }

  // A copy (or a check of Foamy's theme in use): the lock's avatar, the
  // pictures, then stage.
  function prepare() {
    var background = !showsPicture ? "" : look.background.source === "omarchy" ? wallpaperPath : String(look.background.path || "")
    job = {
      key: key,
      entry: entry,
      look: look,
      source: background,
      lockAvatar: "",
      background: "",
      avatar: "",
      dir: "",
      hash: ""
    }
    runLockStatus()
  }

  // A step's end (also a test hook): `exitCode` -1 when it couldn't start.
  function stepDone(name, exitCode, text) {
    if (name !== step)
      return
    step = ""
    var shown, poster, picture, avatar, staged
    switch (name) {
    case "status":
      return statusDone(exitCode, text)
    case "lock":
      shown = Login.lockAvatarReport(exitCode, text)
      if (!shown.ok)
        return prepareFailed(shown.code)
      // The photo itself, decoded here as the lock decodes it: the lock
      // re-reads its photo only when it locks, so its rendered copy can be
      // older than the photo (removed or replaced since).
      job.lockAvatar = shown.source
      lockAvatarSource = shown.source
      if (job.source && Layout.isVideoPath(job.source))
        return runPoster(job.source)
      if (job.source)
        return runBackground(job.source)
      return runAvatar()
    case "poster":
      poster = Model.videoProbeResult(exitCode === 0 ? text : "", videoDirectory)
      if (!poster.ok || !poster.poster)
        return prepareFailed(Login.exitProblem(exitCode) || poster.error || "video-helper-failed")
      return runBackground(poster.poster)
    case "background":
      picture = Login.pictureReport("background", exitCode, text, loginCache)
      if (!picture.ok)
        return prepareFailed(picture.code)
      job.background = picture.path
      return runAvatar()
    case "avatar":
      avatar = Login.pictureReport("avatar", exitCode, text, loginCache)
      // No usable photo: the lock shows the initial, and so does the login
      // screen. Anything else stops the copy.
      if (!avatar.ok && !Login.avatarAbsent(avatar.code))
        return prepareFailed(avatar.code)
      job.avatar = avatar.path
      return runStage()
    case "stage":
      staged = Login.stageReport(exitCode, text, runtimeDir)
      if (!staged.ok)
        return prepareFailed(staged.code)
      job.dir = staged.dir
      job.hash = staged.hash
      compareHash = staged.hash
      compareKey = job.key
      compareError = ""
      if (op === "copy")
        return runPublisher("publish", staged.dir)
      return finish()
    case "publish":
    case "restore":
      job = Object.assign({}, job || {}, {
        published: Login.publishReport(exitCode, text)
      })
      // Whatever it said, the login screen is read again.
      return runStatus()
    }
  }

  function prepareFailed(code) {
    if (op === "check") {
      // Foamy's theme is in use, but this look couldn't be compared: an
      // earlier comparison no longer says anything about it.
      compareError = code
      compareHash = ""
      compareKey = ""
      return finish()
    }
    finish("failed", code, true)
  }

  function statusDone(exitCode, text) {
    var report = Login.statusReport(exitCode, text)
    if (report.ok) {
      status = report
      statusError = ""
    } else {
      statusError = report.code
    }
    if (op === "check") {
      if (report.ok && report.state === "installed")
        return prepare()
      return finish()
    }
    // After the publisher: its word, checked against status.
    var published = job.published
    if (published.result !== "ok")
      return finish(published.result, published.code, false)
    var outcome = Login.confirmed(op, report, job.hash)
    // A restore that leaves SDDM off Foamy's theme but its files there.
    var left = op === "restore" && report.ok && (report.state === "not-installed" || report.state === "unavailable")
    finish(outcome, outcome === "done" ? "" : left ? "files-left" : report.ok ? report.state : report.code, false)
  }

  // --- the steps -----------------------------------------------------------------

  function helperCommand(args) {
    return helper ? [helper].concat(args) : FoamyNative.command(pluginDir, "foamy-lock-helper", args)
  }

  // The `studio` subcommands keep the app's environment, as the other
  // `studio` calls do; the sandboxed kinds get the lock's own minimal one.
  function sandboxEnv(cache) {
    return {
      HOME: home,
      XDG_CACHE_HOME: cache,
      PATH: "/usr/bin",
      LANG: "C.UTF-8"
    }
  }

  function run(name, deadline, command, request, clear, env) {
    step = name
    proc.name = name
    proc.request = request
    proc.command = ["timeout", "--kill-after=" + (name === "publish" || name === "restore" ? "5s" : "1s"), deadline].concat(command)
    proc.clearEnvironment = clear
    proc.environment = env
    proc.stdinEnabled = request !== ""
    proc.running = true
  }

  function runStatus() {
    run("status", "10s", helperCommand(["studio", "login-screen", "status"]), "", false, ({}))
  }

  // The lock's status through omarchy-shell (from PATH, else Omarchy's
  // own), read only, with the catalog call's deadline (LockSources.qml).
  function runLockStatus() {
    run("lock", "6s", ["bash", "-c", 'export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"; shell=$(command -v omarchy-shell) || shell="$OMARCHY_PATH/bin/omarchy-shell"; exec -- "$shell" foamy.lock status', "foamy-lock-studio-lock-status"], "", false, ({}))
  }

  // A video's still frame, as the lock makes it (the helper's own limit is
  // 60 s), at the largest screen's size.
  function runPoster(path) {
    run("poster", "65s", helperCommand(["video-probe"]), JSON.stringify({
      path: path,
      width: screenSize[0],
      height: screenSize[1]
    }), true, sandboxEnv(cacheHome))
  }

  // The helper's own job limit is 9 s.
  function runBackground(path) {
    run("background", "12s", helperCommand(["artwork"]), JSON.stringify({
      kind: "background",
      path: path,
      width: size[0],
      height: size[1],
      blur: job.look.background.blur
    }), true, sandboxEnv(loginCache))
  }

  // The lock shows the initial: no avatar.
  function runAvatar() {
    if (!job.lockAvatar)
      return runStage()
    run("avatar", "10s", helperCommand(["artwork"]), JSON.stringify({
      kind: "avatar",
      path: job.lockAvatar
    }), true, sandboxEnv(loginCache))
  }

  // `stage` waits up to 5 s for its lock and reads the plugin's bundle.
  function runStage() {
    var made = Login.stageRequest({
      entry: job.entry,
      settings: settings,
      colors: colors,
      lockThemed: lockThemed,
      language: FoamyI18n.language,
      formatLocale: FoamyI18n.formatLocale,
      rightToLeft: FoamyI18n.rightToLeft,
      background: job.background,
      avatar: job.avatar
    })
    if (made.error)
      return prepareFailed("INVALID_REQUEST")
    run("stage", "20s", helperCommand(["studio", "login-screen", "stage"]), JSON.stringify(made.request), false, ({
        XDG_CACHE_HOME: loginCache
      }))
  }

  // The plugin's publisher, through the app root's `sddm` link. Its exits
  // 126 and 127 are pkexec's, and `timeout` exits 126 or 127 too when the
  // command can't run, so a publisher that isn't an executable file exits
  // 70 here (a failed start) before exec. After authentication the root
  // side bounds itself; the deadline ends a prompt left open.
  function runPublisher(action, dir) {
    var args = dir ? [action, dir] : [action]
    var script = publisher || pluginDir + "/sddm/foamy-lock-login-screen";
    run(action, "1830s", ["bash", "-c", '[[ -f $1 && -x $1 ]] || exit 70; exec -- "$@"', "foamy-lock-studio-publish", script].concat(args), "", false, ({}))
  }

  // Not read (preload off): only its changes count. The lock renames each
  // new render into place; Quickshell's watch follows the path.
  FileView {
    path: login.lockAvatar
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: login.avatarRevision += 1
  }
  // The source photo the same way: one watch, moved when the lock names
  // another photo; none ("") before the lock's first status.
  FileView {
    path: login.lockAvatarSource
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: login.avatarRevision += 1
  }

  Process {
    id: proc
    property string name: ""
    property string request: ""
    onStarted: {
      if (request === "")
        return
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector {
      id: output
      waitForEnd: true
    }
    // exited() comes before `running` goes false; a command that couldn't
    // start reports only the latter, and is settled as one there.
    property bool exitSeen: false
    onRunningChanged: {
      if (running || exitSeen) {
        exitSeen = false
        return
      }
      login.stepDone(proc.name, -1, "")
    }
    onExited: function (exitCode) {
      exitSeen = true
      login.stepDone(proc.name, exitCode, output.text)
    }
  }
}
