import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Services.Mpris
import Quickshell.Wayland
// Read only: the monitors' native size for a video background.
import Quickshell.Hyprland
// Qualify the theme singleton to avoid QtQuick.Color taking precedence.
import qs.Commons as Commons
import "kit"
import "kit/FoamyIpcResolver.js" as IpcResolver
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model
// Fingerprint recovery adapted from Omarchy PR #7158 and v4.5.0-rc1 (03ff1ef).
import "FingerprintModel.js" as FingerprintModel
import "Layout.js" as Layout

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  // Omarchy owns this path; follow its wallpaper location even with XDG overrides.
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property int fingerprintUnreachedStreak: 0
  property bool fingerprintAttemptReachedDevice: false
  property bool fingerprintAttemptFastError: false
  property double fingerprintAttemptPromptedAtMs: 0
  // Blanking pauses new attempts, preserving a pending backoff until wake.
  property bool fingerprintPaused: false
  property bool fingerprintSleptWhilePaused: false
  // Set by runBlank, cleared by runWake: drawn backgrounds hold still while
  // the display is off (input or a new lock wakes it through runWake).
  property bool displayBlanked: false
  property double fingerprintRetryDueMs: 0
  property int fingerprintRetryBackoffMs: 0
  property int knownScreenCount: 0
  property double fingerprintLastNudgeMs: 0
  property double fingerprintLastSettleMs: 0
  property double fingerprintResumedAtMs: 0
  property int fingerprintProbeStreak: 0
  property bool previewVisible: false
  // For previewHoldMs after the preview overlay closes, its window stays
  // mapped, empty and input-transparent but holding the keyboard: keys
  // typed into the overlay (a password, perhaps, as on a real lock) don't
  // spill into the window below. A real lock ends it at once.
  property bool previewHolding: false
  readonly property int previewHoldMs: 500
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string backgroundSignature: ""
  property string videoPosterPath: ""
  property string wallpaperError: ""
  property bool backgroundProbePending: false
  // No helper binary for this CPU (exit 126/127): the plain themed background
  // stays, wallpaperError is helper-unavailable and the probe is not run again.
  property bool wallpaperHelperUnavailable: false
  readonly property bool videoBackground: Model.isVideoPath(backgroundPath)
  readonly property string lockWallpaperPath: videoBackground ? videoPosterPath : backgroundPath
  readonly property string lockWallpaperUrl: Model.fileUrl(lockWallpaperPath, backgroundVersion)
  property string userDisplayName: ""
  property string userAvatarPath: ""
  property string userAvatarRenderPath: ""
  property int userAvatarVersion: 0
  property bool avatarThumbnailPending: false
  // No helper binary for this CPU (exit 126/127): the initial is shown and
  // the helper is not started again.
  property bool avatarHelperUnavailable: false
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false
  // One PAM conversation can report a failure through both onError and
  // onCompleted; the open attempt is counted once.
  property bool passwordAttemptOpen: false
  property string avatarError: ""
  // null until shell.json has been read once.
  property var stockLockEnabled: null
  property string conflictLogged: ""
  // The look (Layout.js): validated apart from `settings`, so a mistake in
  // one never resets the other. The last valid look stays (foamy on start).
  property var look: Layout.defaults()
  // The foamy.lock entry as last read, so saveLook can keep its other keys.
  property var lastEntry: null
  property string lookError: ""
  // The preview overlay's own look (previewPreset); null shows `look`.
  property var previewLook: null
  // User presets (Layout.parseUserPresets): a third group, read item by
  // item from the same entry, never touching `settings` or `look`.
  property var userPresets: []
  property int userPresetsInvalid: 0
  property string userPresetsError: ""
  // The saved look's link to one of them ("" without one, or for an id
  // that isn't in the list).
  property string userPresetLink: ""
  // Whether Omarchy would write shell.json as last read: "ok", "no-entry"
  // (no single foamy.lock entry), or "unreadable" (not a version 1 object,
  // or not read at all), where Omarchy skips the write (persistShellConfig).
  property string entryState: "unreadable"
  // The weather element's data: Foamy Weather's `current()` over
  // FoamyPeerIpc (see pollWeather), checked by Model.parseWeather. Fetched
  // only while a lock or preview shows a look with the weather in it: when
  // it opens, then every weatherPollMs while the display is awake. Shown
  // while under three hours old; hidden on no answer, an error or an
  // invalid reply. weatherState is the last answer's state, or "absent"
  // (no foamy.weather target: nothing is called) or "idle".
  property var weatherReport: null
  property string weatherState: "idle"
  property double weatherClockMs: Date.now()
  property double weatherPolledAtMs: 0
  property int weatherPolls: 0
  property int weatherPendingLeft: 0
  property bool weatherBusy: false
  readonly property int weatherPollMs: 900000
  // A cold service answers "pending" for a few seconds: ask again, at most
  // this many times, this far apart.
  readonly property int weatherRetryMs: 10000
  readonly property int weatherRetries: 3
  readonly property var weather: Model.weatherFresh(weatherReport, weatherClockMs) ? weatherReport : null
  readonly property bool weatherWanted: (lockRequested && !displayBlanked && lookShowsWeather(look))
    || (previewVisible && lookShowsWeather(previewLook || look))
  // Lock surfaces that have keyboard focus: the field shows there, or on
  // every surface while none does (Layout.isPrimary).
  property int activeSurfaces: 0
  // The last geometry fallback a lock view reported ("" when none).
  property string layoutError: ""
  property string fallbackPreset: ""
  // The look's own picture, prepared by the helper's sandbox while unlocked
  // (decoded, cropped to the largest screen, blurred). Qt never decodes the
  // original; without a prepared file the theme colour shows.
  readonly property bool pictureWanted: look.background.source === "picture" && look.background.path !== ""
    && !Layout.isVideoPath(look.background.path)
  // One prepared picture at a time, for the look on screen: the preview's,
  // else the saved one. A view uses it only when it was made for its look.
  readonly property var pictureLook: previewLook || look
  readonly property string lookPictureKey: pictureKey(look)
  readonly property string previewPictureKey: pictureKey(pictureLook)
  property string pictureRenderPath: ""
  property string pictureError: ""
  property string pictureRequestKey: ""
  property bool picturePending: false
  property bool pictureHelperUnavailable: false
  // A video background (Layout.isVideoPath; see videoKey): the helper's
  // video-probe, run in its sandbox while unlocked for the look on screen,
  // gives the poster (the still of a picture source with a video path) and
  // the clip Lock Studio converted for this file and the largest screen's
  // native size, if there is one. The lock never converts and never
  // decodes the original; a view plays only that clip (motion "play").
  readonly property string videoCacheDirectory: avatarCacheDirectory + "/video/"
  // video-probe for a video Omarchy wallpaper's still (posterProc).
  readonly property var posterProbeCommand: FoamyNative.command(FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["video-probe"])
  readonly property bool hyprlandSession: !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
  // Hyprland's monitors (read only): Qt only knows the integer scale.
  readonly property var videoNatives: {
    var out = []
    var monitors = hyprlandSession ? Hyprland.monitors.values : []
    for (var i = 0; i < monitors.length; i++) {
      var ipc = monitors[i].lastIpcObject
      if (ipc) out.push({ width: Number(ipc.width) || 0, height: Number(ipc.height) || 0, transform: Number(ipc.transform) || 0 })
    }
    return out
  }
  readonly property string lookVideoKey: videoKey(look)
  readonly property string previewVideoKey: videoKey(pictureLook)
  property string videoRequestKey: ""
  property string videoPosterRender: ""
  property string videoClipPath: ""
  property string videoError: ""
  property bool videoPending: false
  property bool videoHelperUnavailable: false
  property string videoFailure: ""

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating
  readonly property bool fingerprintUnavailable: FingerprintModel.isUnavailable(fingerprintProbeStreak) || (fingerprintConfigured && (!fingerprintAttemptReachedDevice || fingerprintAttemptFastError) && FingerprintModel.isUnavailable(fingerprintUnreachedStreak))
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  property var settings: Model.defaults()
  property string configError: ""
  readonly property var activePlayer: settings.showMedia
    ? Model.selectPlayer(Mpris.players.values, settings.showBrowserMedia) : null
  readonly property string avatarCacheDirectory: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache")
    + "/omarchy/foamy.lock"
  readonly property string userAvatarCachePath: avatarCacheDirectory + "/avatar.png"

  Artwork {
    id: artwork
    player: root.activePlayer
    // Only the styles with a cover show artwork (Layout.ARTWORK_STYLES): a
    // hidden or one-line player prepares none.
    allowed: root.settings.showMedia && root.settings.showArtwork
      && !root.look.elements.media.hidden && Layout.ARTWORK_STYLES.indexOf(root.look.elements.media.style) !== -1
    locked: root.locked
    hosts: root.settings.artworkHosts
    fileRoots: root.settings.artworkFileRoots
  }

  function applyConfiguration(text) {
    var result = Model.parseConfig(text)
    configError = result.error
    // A broken preferences file must never disable authentication or reset a lock.
    if (result.valid) {
      settings = result.settings
      stockLockEnabled = result.stockLockEnabled
    } else console.warn("foamy.lock: " + configError + "; keeping previous settings")
    noteEntryState(text, result.entry)
    // The look keys are read whenever the file has one foamy.lock entry.
    if (result.entry) {
      applyUserPresets(result.entry)
      lastEntry = result.entry
      var parsed = Layout.parseLook(result.entry)
      lookError = parsed.error
      if (parsed.valid) {
        if (JSON.stringify(parsed.look) !== JSON.stringify(look)) look = parsed.look
      } else console.warn("foamy.lock: " + lookError + "; keeping the previous look")
    }
    // Services may have been added or removed with this edit.
    Qt.callLater(checkLockRoute)
  }

  // --- user presets and writes (Lock Studio round 2, step R2-2) --------------

  // Omarchy writes shell.json only over a version 1 object it could read
  // (persistShellConfig skips the write otherwise, and still reports a
  // change): a save must then say write-failed, never ok. An empty file is
  // written, but it has no entry to merge into.
  function noteEntryState(text, entry) {
    var source = String(text || "")
    var config = null
    try { config = JSON.parse(source) } catch (error) { config = null }
    var readable = config !== null && typeof config === "object" && !Array.isArray(config) && config.version === 1
    entryState = readable ? (entry ? "ok" : "no-entry") : source.trim() === "" ? "no-entry" : "unreadable"
  }

  function applyUserPresets(entry) {
    var parsed = Layout.parseUserPresets(entry)
    if (JSON.stringify(parsed.presets) !== JSON.stringify(userPresets)) userPresets = parsed.presets
    userPresetsInvalid = parsed.invalid
    if (parsed.error !== userPresetsError) {
      userPresetsError = parsed.error
      if (parsed.error) console.warn("foamy.lock: " + parsed.invalid + " user preset(s) skipped: " + parsed.error)
    }
    userPresetLink = Layout.userPresetLink(entry, parsed.presets)
  }

  // The entry an IPC write merges into, or the reply when there is none
  // to write.
  function writableEntry() {
    if (!shell || typeof shell.updateEntryInline !== "function") return "unsupported"
    if (!lastEntry || entryState === "no-entry") return "no-entry"
    if (entryState !== "ok") return "write-failed"
    return lastEntry
  }

  // Writes `next` (the entry without its id) through Omarchy's own
  // updateEntryInline and takes it as the entry last read at once, so a
  // second write before the file watch reports this one merges over it,
  // never over the entry before (two quick saves don't revert each other).
  function writeEntry(next) {
    if (!shell.updateEntryInline("foamy.lock", next)) return "unchanged"
    var written = { id: "foamy.lock" }
    for (var key in next) written[key] = next[key]
    lastEntry = written
    applyUserPresets(written)
    return "ok"
  }

  // The catalog's user presets: each with its look and its built-in
  // preset's thumbnail (user presets have none of their own).
  function catalogUserPresets(dir) {
    return userPresets.map(function(preset) {
      return { id: preset.id, name: preset.name, entry: preset.look, look: preset.effective,
        thumbnail: dir + "/previews/presets/" + preset.effective.preset + ".png" }
    })
  }

  // The socket answers from the first enabled handler for a target. When a
  // second lock service is loaded anyway, lockRoute (foamy-kit
  // FoamyIpcPreference) keeps `lock`, `isLocked` and `status` on this one,
  // the lock the user enabled, so the request and the pre-suspend status poll
  // always reach the same session lock; status then reports the conflict.
  // It only reorders the registry's list: no other handler is removed,
  // disabled or called. 4.0 has no registry: nothing happens there.
  function checkLockRoute() {
    lockRoute.recheck()
    var reasons = conflictReasons()
    var key = reasons.join(",")
    if (key && key !== conflictLogged) console.warn("foamy.lock: another lock service is loaded (" + key + "); keep omarchy.lock in disabledPlugins")
    conflictLogged = key
  }

  function conflictReasons() {
    var reasons = []
    if (stockLockEnabled === true) reasons.push("stock-lock-enabled")
    if (lockRoute.others > 0) reasons.push("lock-target-shared")
    return reasons
  }

  onSettingsChanged: {
    if (lockRequested) armBlankTimer()
  }

  function currentlyLocked() {
    return lockRequested || sessionLock.locked || sessionLock.secure
  }

  function pauseFingerprint() {
    if (fingerprintPaused) return
    fingerprintPaused = true
    fingerprintRetryTimer.stop()
  }

  function resumeFingerprint() {
    if (!fingerprintPaused) return
    fingerprintPaused = false
    if (fingerprintSleptWhilePaused) {
      fingerprintSleptWhilePaused = false
      noteFingerprintResumed()
      fingerprintRetryBackoffMs = FingerprintModel.MATCH_RETRY_MS
      fingerprintRetryTimer.interval = FingerprintModel.MATCH_RETRY_MS
    } else {
      fingerprintRetryTimer.interval = Math.max(FingerprintModel.MATCH_RETRY_MS, fingerprintRetryDueMs - Date.now())
    }
    if (lockRequested && fingerprintConfigured && !fingerprintAuthenticating) fingerprintRetryTimer.restart()
  }

  function noteSleepRequested() {
    if (!lockRequested || !fingerprintPaused) return
    // logind holds a suspend for its inhibitor delay, at most 15 seconds here.
    fingerprintResumeTimer.ticksLeft = 20
    fingerprintResumeTimer.lastTickMs = Date.now()
    fingerprintResumeTimer.restart()
  }

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a startup check must distinguish an orphan from another live locker.
  // Outputs can still be absent, so keep retrying an undetermined answer.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (currentlyLocked()) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || currentlyLocked() || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    // Coalesce theme/lock requests while the filesystem probe is in flight.
    if (wallpaperProbeProc.running) {
      backgroundProbePending = true
      return
    }
    backgroundProbePending = false
    if (wallpaperHelperUnavailable) return
    wallpaperProbeProc.running = true
  }

  function refreshPoster() {
    if (!videoBackground) {
      videoPosterPath = ""
      return
    }
    if (posterProc.running) return
    var size = Model.videoScreenSize(videoNatives, Quickshell.screens || [])
    posterProc.sourcePath = backgroundPath
    posterProc.request = JSON.stringify({ path: backgroundPath, width: size[0], height: size[1] })
    posterProc.stdinEnabled = true
    posterProc.sourceSignature = backgroundSignature
    posterProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  // An unreachable fprintd -- restarting under the resume hook, or still
  // activating -- answers the probe with an error, not with "no prints".
  // Concluding "not configured" from that stopped the retry loop and the
  // sleep watch for the rest of the lock (#9453); keep the current state and
  // ask again instead. Only a definitive answer changes anything.
  function applyFingerprintProbe(text) {
    var status = FingerprintModel.classifyProbe(text)
    if (status === "unknown") {
      if (fingerprintConfigured) return
      fingerprintProbeStreak += 1
      if (lockRequested) {
        fingerprintRecheckTimer.interval = FingerprintModel.retryDelayMs(fingerprintProbeStreak)
        fingerprintRecheckTimer.restart()
      }
      return
    }
    fingerprintProbeStreak = 0
    fingerprintRecheckTimer.stop()
    fingerprintConfigured = status === "yes"
    if (lockRequested && fingerprintConfigured) {
      // A pending retry already owns the next attempt.
      if (!fingerprintRetryTimer.running) startFingerprint()
    } else if (!fingerprintConfigured) {
      // abort() delivers no completion signal, so close the attempt here
      // too; settle returns before arming a retry while unconfigured.
      if (fingerprintPam.active) fingerprintPam.abort()
      settleFingerprintAttempt()
      fingerprintRetryTimer.stop()
    }
  }

  function refreshUserIdentity() {
    if (!userName || passwdIdentityProc.running || accountsIdentityProc.running) return
    passwdIdentityProc.running = true
  }

  function refreshAvatarThumbnail() {
    if (!userAvatarPath) {
      userAvatarRenderPath = ""
      userAvatarVersion += 1
      return
    }

    // Identity probes can finish while a previous thumbnail is rendering.
    // Coalesce them into one follow-up so the newest account icon wins.
    if (avatarThumbnailProc.running) {
      avatarThumbnailPending = true
      return
    }
    if (avatarHelperUnavailable) {
      applyAvatarResult('{"ok":false,"error":"helper-unavailable"}')
      return
    }

    // The same sandboxed decoder as media artwork (foamy-lock-helper), bounded by
    // its own alarm and an outer timeout, so a pathological picture can
    // neither run ImageMagick delegates nor hang the refresh.
    avatarThumbnailProc.request = JSON.stringify({ kind: "avatar", path: userAvatarPath })
    avatarThumbnailProc.stdinEnabled = true
    avatarThumbnailProc.running = true
  }

  function applyAvatarResult(text) {
    var result = null
    try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
    if (result && result.ok === true && result.path === userAvatarCachePath) {
      avatarError = ""
      userAvatarRenderPath = userAvatarCachePath
    } else {
      var code = result && typeof result.error === "string" && /^[a-z-]{1,48}$/.test(result.error)
        ? result.error : "avatar-helper-failed"
      avatarError = code
      // Without Bubblewrap or ImageMagick there is no thumbnail at all; the
      // user's own picture is then shown as before. A picture the sandbox
      // rejected or timed out on never reaches Qt's decoder: the initial shows.
      userAvatarRenderPath = code === "decoder-unavailable" ? userAvatarPath : ""
    }
    userAvatarVersion += 1
  }

  function applyPasswdIdentity(value) {
    var line = String(value || "").trim().split("\n")[0]
    var fields = line.split(":")
    if (fields.length < 7) return

    userDisplayName = String(fields[4] || "").split(",")[0].trim()
    var accountHome = String(fields[5] || "").trim() || home
    userAvatarPath = accountHome + "/.face"
    refreshAvatarThumbnail()
  }

  function applyAccountsIdentity(value) {
    var lines = String(value || "").trim().split("\n")
    if (lines.length < 4) return

    var values = []
    try {
      for (var i = 0; i < lines.length; i++) values.push(JSON.parse(lines[i]).data)
    } catch (error) {
      return
    }

    var realName = String(values[0] || "").trim()
    var iconFile = String(values[1] || "").trim()
    var accountHome = String(values[3] || "").trim() || home
    if (realName) userDisplayName = realName
    userAvatarPath = iconFile || userAvatarPath || accountHome + "/.face"
    refreshAvatarThumbnail()
  }

  onPreviewVisibleChanged: {
    if (previewVisible) {
      previewHolding = false
      previewHoldTimer.stop()
    } else {
      previewLook = null
      previewHolding = true
      previewHoldTimer.restart()
    }
  }
  onPreviewLookChanged: {
    Qt.callLater(refreshPicture)
    refreshVideoScreens()
  }
  // Fallback reports describe the views of the current lock and look.
  onLockRequestedChanged: {
    if (lockRequested) clearLayoutFallback()
    // A picture changed while locked is prepared once unlocked.
    else {
      refreshPicture()
      refreshVideo()
    }
  }
  onLookChanged: {
    clearLayoutFallback()
    // After the bindings that read the look have caught up.
    Qt.callLater(refreshPicture)
    refreshVideoScreens()
  }
  // The look, the Omarchy wallpaper or a screen changed what to probe.
  onPreviewVideoKeyChanged: Qt.callLater(refreshVideo)

  // The largest screen in logical pixels, inside the helper's bounds.
  function pictureSize() {
    var screens = Quickshell.screens || []
    var width = 0
    var height = 0
    for (var i = 0; i < screens.length; i++) {
      if (!screens[i]) continue
      width = Math.max(width, Math.round(screens[i].width || 0))
      height = Math.max(height, Math.round(screens[i].height || 0))
    }
    if (width < 16 || height < 16) return [1920, 1080]
    return [Math.min(width, 7680), Math.min(height, 4320)]
  }

  // The helper request for a look's picture, "" when it has none.
  function pictureKey(target) {
    var background = target ? target.background : null
    if (!background || background.source !== "picture" || !background.path || Layout.isVideoPath(background.path)) return ""
    var size = pictureSize()
    return JSON.stringify({ kind: "background", path: background.path, width: size[0], height: size[1],
      blur: background.blur })
  }

  // --- video backgrounds --------------------------------------------------------

  // The video a look shows: a picture source's video path (its poster is
  // the still either way), or the Omarchy wallpaper when it is a video and
  // the look plays (its still stays Omarchy's poster). "" otherwise.
  function videoSourcePath(target) {
    var background = target ? target.background : null
    if (!background) return ""
    if (background.source === "picture" && Layout.isVideoPath(background.path)) return background.path
    if (background.source === "omarchy" && videoBackground && Layout.playsVideo(background)) return backgroundPath
    return ""
  }

  function isVideoPicture(target) {
    return !!target && target.background.source === "picture" && Layout.isVideoPath(target.background.path)
  }

  // The helper's video-probe request for a look ("" without a video): the
  // file and the largest screen's native size, the clip's key.
  function videoKey(target) {
    var path = videoSourcePath(target)
    if (!path) return ""
    var size = Model.videoScreenSize(videoNatives, Quickshell.screens || [])
    return JSON.stringify({ path: path, width: size[0], height: size[1] })
  }

  // Asks Hyprland for its monitors again (a read-only query), so the native
  // size follows mode and scale changes.
  function refreshVideoScreens() {
    if (hyprlandSession) Hyprland.refreshMonitors()
  }

  function refreshVideo() {
    var key = previewVideoKey
    if (!key) {
      videoRequestKey = ""
      videoPosterRender = ""
      videoClipPath = ""
      videoError = ""
      return
    }
    if (key === videoRequestKey) return
    // Probed while unlocked only, as the picture is prepared.
    if (currentlyLocked()) return
    if (videoProc.running) {
      videoPending = true
      return
    }
    // Never the previous video's poster or clip under this key.
    videoRequestKey = key
    videoPosterRender = ""
    videoClipPath = ""
    if (videoHelperUnavailable) {
      applyVideoResult('{"ok":false,"error":"helper-unavailable"}', key)
      return
    }
    videoProc.request = key
    videoProc.stdinEnabled = true
    videoProc.running = true
  }

  // The probe's reply for `request` (Model.videoProbeResult's checks).
  function applyVideoResult(text, request) {
    if (request !== videoRequestKey) return
    var result = Model.videoProbeResult(text, videoCacheDirectory)
    var violations = result.ok && Array.isArray(result.reply.violations) ? result.reply.violations : []
    videoPosterRender = result.poster
    videoClipPath = result.clip
    videoError = !result.ok ? result.error
      : violations.length > 0 && /^[a-z-]{1,48}$/.test(String(violations[0])) ? String(violations[0])
      : !result.poster ? "video-poster-missing" : ""
    if (videoError) console.warn("foamy.lock: video background has no poster or clip (" + videoError + ")")
  }

  // A view gave up on the clip ("error" or "stall"): its poster stays.
  function noteVideoFailure(reason) {
    videoFailure = reason
    logEvent("video-gave-up: " + reason)
  }

  function refreshPicture() {
    var key = pictureKey(pictureLook)
    if (!key) {
      pictureRequestKey = ""
      pictureRenderPath = ""
      pictureError = ""
      return
    }
    if (key === pictureRequestKey) return
    // Prepared while unlocked only: a lock keeps what it was shown with.
    if (currentlyLocked()) return
    if (pictureProc.running) {
      picturePending = true
      return
    }
    pictureRequestKey = key
    if (pictureHelperUnavailable) {
      applyPictureResult('{"ok":false,"error":"helper-unavailable"}')
      return
    }
    pictureProc.request = key
    pictureProc.stdinEnabled = true
    pictureProc.running = true
  }

  function applyPictureResult(text) {
    var result = null
    try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
    var directory = avatarCacheDirectory + "/background/"
    if (result && result.ok === true && typeof result.path === "string"
        && result.path.indexOf(directory) === 0 && /^[0-9a-f]{64}\.png$/.test(result.path.slice(directory.length))) {
      pictureError = ""
      pictureRenderPath = result.path
    } else {
      pictureError = result && typeof result.error === "string" && /^[a-z-]{1,48}$/.test(result.error)
        ? result.error : "picture-helper-failed"
      pictureRenderPath = ""
      console.warn("foamy.lock: background picture unavailable (" + pictureError + "); showing the theme colour")
    }
  }

  function clearLayoutFallback() {
    layoutError = ""
    fallbackPreset = ""
  }

  function noteLayoutFallback(error, preset) {
    layoutError = error
    fallbackPreset = preset
    logEvent("layout-fallback: " + error + " -> " + preset)
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("foamy.lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    passwordAttemptOpen = false
    fingerprintAuthenticating = false
    fingerprintUnreachedStreak = 0
    fingerprintAttemptFastError = false
    fingerprintAttemptPromptedAtMs = 0
    fingerprintLastNudgeMs = 0
    fingerprintLastSettleMs = 0
    fingerprintResumedAtMs = 0
    fingerprintProbeStreak = 0
    fingerprintPaused = false
    fingerprintSleptWhilePaused = false
    fingerprintRecheckTimer.stop()
    fingerprintRetryTimer.stop()
    fingerprintReachTimer.stop()
    fingerprintResumeTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    // The preview overlay is not a lock; never leave it behind a real one.
    previewVisible = false
    endPreviewHold()
    lockRequested = true
    displayBlanked = false
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()
    openWeather()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshUserIdentity()
    })

    return true
  }

  // Whether a look shows the weather element.
  function lookShowsWeather(target) {
    var item = target && target.elements ? target.elements.weather : null
    return !!item && !item.hidden
  }

  // A lock or preview opened: fetch the weather now (when its look shows it).
  function openWeather() {
    weatherPolledAtMs = 0
    Qt.callLater(pollWeatherIfDue)
  }

  function pollWeatherIfDue() {
    if (weatherWanted && Date.now() - weatherPolledAtMs >= weatherPollMs) pollWeather()
  }

  function pollWeather() {
    if (!weatherWanted) return
    weatherPendingLeft = weatherRetries
    weatherPolledAtMs = Date.now()
    requestWeather()
  }

  // One call. An absent Foamy Weather costs nothing: without a foamy.weather
  // target in IpcRegistry nothing is called and no process starts.
  function requestWeather() {
    weatherRetryTimer.stop()
    if (IpcResolver.handlersFor(root, "foamy.weather").length === 0) {
      weatherState = "absent"
      weatherReport = null
      return
    }
    if (weatherBusy) return
    weatherBusy = true
    weatherPolls++
    weatherPeer.call("foamy.weather", "current", [], function(ok, output) {
      root.weatherBusy = false
      root.applyWeatherReply(ok, output)
    })
  }

  // A reply ("Function not found." from an older Foamy Weather is not ok):
  // pending asks again later and keeps what shows; anything else replaces it.
  function applyWeatherReply(ok, output) {
    weatherClockMs = Date.now()
    var parsed = ok ? Model.parseWeather(output, weatherClockMs) : { state: "unavailable", weather: null }
    weatherState = parsed.state
    if (parsed.state === "pending") {
      if (weatherPendingLeft > 0 && weatherWanted) {
        weatherPendingLeft--
        weatherRetryTimer.restart()
      }
      return
    }
    weatherReport = parsed.state === "ok" ? parsed.weather : null
  }

  function finishUnlock() {
    if (!root.currentlyLocked()) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    if (settings.blankAfterSec === null) idleBlankTimer.stop()
    else idleBlankTimer.restart()
  }

  function runWake() {
    displayBlanked = false
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
    resumeFingerprint()
    nudgeFingerprint()
  }

  // A keypress, touch, or cursor move is the user saying the reader is worth
  // trying now, so collapse a backed-off wait to a prompt retry rather than
  // ride out the cap. Rate-limited (see shouldNudge): a moving cursor raises a
  // wake per motion event, and without the floor each fresh backoff wait would
  // be re-collapsed straight back into the storm the backoff exists to prevent;
  // past the floor, the current tier paces repeat nudges.
  function nudgeFingerprint() {
    if (!lockRequested) return
    if (!fingerprintConfigured && fingerprintRecheckTimer.running) {
      var now = Date.now()
      if (FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, now - FingerprintModel.IDLE_CLEAR_MS, fingerprintRecheckTimer.interval)) {
        fingerprintLastNudgeMs = now
        fingerprintRecheckTimer.interval = FingerprintModel.MATCH_RETRY_MS
        fingerprintRecheckTimer.restart()
      }
      return
    }
    if (!fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return
    if (!fingerprintRetryTimer.running) return
    var now = Date.now()
    if (!FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, fingerprintLastSettleMs, fingerprintRetryBackoffMs)) return
    fingerprintLastNudgeMs = now
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }

  function armFingerprintRetry(delayMs) {
    fingerprintRetryTimer.interval = delayMs
    fingerprintRetryBackoffMs = delayMs
    fingerprintRetryDueMs = Date.now() + delayMs
    if (!fingerprintPaused) fingerprintRetryTimer.restart()
  }

  // Monotonic timers pause across suspend, so a wait armed before the sleep
  // picks up mid-count afterwards -- and the streak it was pacing was built
  // against the reader as it stood before the sleep. The resume hook is
  // restarting fprintd, so that streak is stale: drop it, and open the grace
  // window in which the restart landing under an attempt does not count as a
  // miss either (see RESUME_GRACE_MS). Idempotent within the window, since a
  // resume can be noticed by more than one timer.
  function noteFingerprintResumed() {
    var now = Date.now()
    if (FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)) return
    logEvent("fingerprint-resume: streak=" + fingerprintUnreachedStreak)
    fingerprintResumedAtMs = now
    fingerprintUnreachedStreak = 0
  }

  // A resume noticed while a backed-off wait is pending: retry the fresh
  // reader now, instead of after the remaining wait or the next keypress.
  // An attempt still in flight is worse than a pending wait: the hook has
  // restarted fprintd under it, so it sits on a dead conversation that
  // pam_fprintd takes ~25s to give up on (#8747) while the icon invites
  // touches that cannot work. Abort it and settle -- inside the grace
  // window, so the kill never counts toward the notice -- and the settle
  // arms the fast retry itself.
  function restartFingerprintAfterSleep() {
    noteFingerprintResumed()
    if (fingerprintAuthenticating || fingerprintPam.active) {
      if (fingerprintPam.active) fingerprintPam.abort()
      settleFingerprintAttempt()
      return
    }
    if (!fingerprintRetryTimer.running) return
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }

  function runBlank() {
    displayBlanked = true
    pauseFingerprint()
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true
    passwordAttemptOpen = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    // Settle each attempt once: onError and onCompleted may both report it.
    if (!passwordAttemptOpen) return
    passwordAttemptOpen = false
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured || fingerprintPaused) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    fingerprintAttemptReachedDevice = false
    fingerprintAttemptFastError = false
    fingerprintAttemptPromptedAtMs = 0
    if (!fingerprintPam.start()) {
      // Pace a failed start while checking whether its PAM configuration was
      // removed; a definitive "no" stops retries and hides the indicator.
      settleFingerprintAttempt()
      refreshFingerprintStatus()
      return
    }
    // Bound claims that never prompt; a normal verify waits for a finger
    // under pam_fprintd's own timeout after reaching the reader.
    fingerprintReachTimer.restart()
  }

  // A verify prompt is the only PAM message pam_fprintd relays, and only once
  // the claim has landed, so any non-error message means this attempt reached
  // the reader. Immediate device errors still back off. It may now
  // wait for a finger as long as pam_fprintd allows, so the reach bound stops.
  function noteFingerprintReachedDevice() {
    if (fingerprintAttemptReachedDevice) return
    fingerprintAttemptReachedDevice = true
    fingerprintAttemptPromptedAtMs = Date.now()
    fingerprintReachTimer.stop()
  }

  // An attempt that never reached the reader within the bound is stuck rather
  // than waiting for a finger — abort it so it settles as unreached, which
  // advances the streak (and so the notice) and retries against a daemon that
  // may now be fresh, instead of hanging silently behind a normal icon.
  function timeoutFingerprintReach() {
    logEvent("fingerprint-reach-timeout")
    if (fingerprintPam.active) fingerprintPam.abort()
    settleFingerprintAttempt()
  }

  // One PAM attempt can raise both onError and onCompleted, so fold each
  // attempt into the streak exactly once: fingerprintAuthenticating is the
  // attempt being open, and the first settle closes it. Reached attempts clear
  // the streak; unreached ones advance it and stretch the next retry.
  function settleFingerprintAttempt(deviceError) {
    if (!fingerprintAuthenticating) return
    fingerprintAuthenticating = false
    fingerprintReachTimer.stop()
    if (!lockRequested || !fingerprintConfigured) return

    // An error can arrive before the sleep watcher notices the wall-clock gap.
    var now = Date.now()
    fingerprintAttemptFastError = !!deviceError && fingerprintAttemptReachedDevice && now - fingerprintAttemptPromptedAtMs < FingerprintModel.FAST_ERROR_MS
    var usableAttempt = fingerprintAttemptReachedDevice && !fingerprintAttemptFastError
    if (!usableAttempt && fingerprintSleepWatch.running
        && FingerprintModel.spannedSleep(now - fingerprintSleepWatch.lastTickMs, fingerprintSleepWatch.interval)) {
      noteFingerprintResumed()
    }

    // Reached attempts are the steady state (one per swipe window), so only
    // the misses and the recovery from them leave a trace.
    var previousStreak = fingerprintUnreachedStreak
    var inGrace = FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)
    fingerprintUnreachedStreak = FingerprintModel.nextStreak(previousStreak, usableAttempt, inGrace)
    if (!usableAttempt) {
      var crossed = !FingerprintModel.isUnavailable(previousStreak) && FingerprintModel.isUnavailable(fingerprintUnreachedStreak)
      logEvent((crossed ? "fingerprint-unavailable" : "fingerprint-unreached") + ": streak=" + fingerprintUnreachedStreak)
    } else if (previousStreak > 0) {
      logEvent("fingerprint-recovered: streak=" + previousStreak)
    }
    fingerprintLastSettleMs = now
    armFingerprintRetry(FingerprintModel.retryDelayMs(fingerprintUnreachedStreak))
  }

  function handleFingerprintFinished(result) {
    if (result === PamResult.Success && lockRequested) {
      // A match after a run of misses is the recovery too; the unlock resets
      // the streak without settling, so log it here or it leaves no trace.
      if (fingerprintUnreachedStreak > 0) logEvent("fingerprint-recovered: streak=" + fingerprintUnreachedStreak)
      finishUnlock()
    } else {
      settleFingerprintAttempt(result === PamResult.Error)
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Commons.Color.background

      LockView {
        id: lockView
        // Keystrokes arrive at the focused surface; Window.active follows it.
        readonly property bool surfaceActive: Window.active
        onSurfaceActiveChanged: root.activeSurfaces = Math.max(0, root.activeSurfaces + (surfaceActive ? 1 : -1))
        Component.onDestruction: if (surfaceActive) root.activeSurfaces = Math.max(0, root.activeSurfaces - 1)
        look: root.look
        displayAwake: !root.displayBlanked
        weather: root.weather
        primary: Layout.isPrimary(surfaceActive, root.activeSurfaces > 0, lockSurface.screen !== null)
        onLayoutFellBack: function(error, preset) { root.noteLayoutFallback(error, preset) }
        anchors.fill: parent
        // Only a picture (or a video's poster) made for this look; otherwise
        // the theme colour. A video's poster is not blurred yet.
        backgroundPath: root.isVideoPicture(root.look)
          ? (root.videoRequestKey === root.lookVideoKey ? root.videoPosterRender : "")
          : !root.pictureWanted ? root.lockWallpaperPath
          : root.pictureRequestKey === root.lookPictureKey ? root.pictureRenderPath : ""
        backgroundPrepared: root.pictureWanted
        // Only the clip made for this look's video and screen.
        videoPath: root.lookVideoKey !== "" && root.videoRequestKey === root.lookVideoKey ? root.videoClipPath : ""
        onVideoFailed: function(reason) { root.noteVideoFailure(reason) }
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured || root.fingerprintUnavailable
        fingerprintUnavailable: root.fingerprintUnavailable
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        activePlayer: root.activePlayer
        artworkPath: artwork.path
        onArtworkFailed: function(path) { artwork.invalidate(path) }
        showUserInfo: root.settings.showUserInfo
        timeFormat: root.settings.timeFormat
        passwordText: root.enteredPassword
        userName: root.userName
        userDisplayName: root.userDisplayName
        avatarPath: root.userAvatarRenderPath
        avatarVersion: root.userAvatarVersion
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible || root.previewHolding
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "foamy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    // While holding (closed, keys still swallowed) the pointer goes through.
    mask: root.previewVisible ? null : previewNoInput

    Region { id: previewNoInput }

    LockView {
      objectName: "previewView"
      anchors.fill: parent
      visible: root.previewVisible
      // A preview isn't a lock: it never asks for the password.
      showUnlockHint: false
      backgroundPath: root.isVideoPicture(root.pictureLook)
        ? (root.videoRequestKey === root.previewVideoKey ? root.videoPosterRender : "")
        : !root.previewPictureKey ? root.lockWallpaperPath
        : root.pictureRequestKey === root.previewPictureKey ? root.pictureRenderPath : ""
      backgroundPrepared: root.previewPictureKey !== ""
      videoPath: root.previewVideoKey !== "" && root.videoRequestKey === root.previewVideoKey ? root.videoClipPath : ""
      onVideoFailed: function(reason) { root.noteVideoFailure(reason) }
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured || root.fingerprintUnavailable
      fingerprintUnavailable: root.fingerprintUnavailable
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      activePlayer: root.activePlayer
      artworkPath: artwork.path
      onArtworkFailed: function(path) { artwork.invalidate(path) }
      showUserInfo: root.settings.showUserInfo
      timeFormat: root.settings.timeFormat
      passwordText: ""
      userName: root.userName
      userDisplayName: root.userDisplayName
      avatarPath: root.userAvatarRenderPath
      avatarVersion: root.userAvatarVersion
      look: root.previewLook || root.look
      weather: root.weather
      primary: true
      onLayoutFellBack: function(error, preset) { root.noteLayoutFallback(error, preset) }
    }

    // Says what this is: a look on the screen, not a lock.
    Rectangle {
      objectName: "previewBanner"
      visible: root.previewVisible
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: FoamyStyle.gap * 3
      width: Math.min(parent.width - FoamyStyle.gap * 4, bannerColumn.implicitWidth + FoamyStyle.gap * 4)
      height: bannerColumn.implicitHeight + FoamyStyle.gap * 2
      radius: FoamyStyle.radius
      color: Qt.alpha(FoamyPalette.background, 0.92)
      border.width: 1
      border.color: FoamyPalette.border
      Accessible.role: Accessible.AlertMessage
      Accessible.name: previewBannerTitle.text + ". " + previewBannerHint.text

      Column {
        id: bannerColumn
        anchors.centerIn: parent
        width: parent.width - FoamyStyle.gap * 4
        spacing: Math.round(FoamyStyle.gap / 2)
        Text {
          id: previewBannerTitle
          objectName: "previewBannerTitle"
          textFormat: Text.PlainText
          width: parent.width
          text: FoamyI18n.t("Preview")
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
        }
        Text {
          id: previewBannerHint
          objectName: "previewBannerHint"
          textFormat: Text.PlainText
          width: parent.width
          text: FoamyI18n.t("Not locked. Any key or click closes the preview.")
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.previewVisible
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }

    // The overlay holds exclusive keyboard focus, so any key closes it too:
    // without a pointer it would otherwise block the keyboard until hidePreview.
    // While holding, keys are swallowed the same way.
    Item {
      id: previewKeys
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) { root.previewKeyPressed(event) }
    }
  }

  FoamyPeerIpc {
    id: weatherPeer
    // One call at a time (weatherBusy); the omarchy-shell fallback, for a
    // target IpcRegistry can't run, is bounded the same way.
    limit: 1
  }

  // Every weatherPollMs while a shown look has the weather (the display awake).
  Timer {
    interval: root.weatherPollMs
    repeat: true
    running: root.weatherWanted
    onRunningChanged: if (running) Qt.callLater(root.pollWeatherIfDue)
    onTriggered: root.pollWeather()
  }

  Timer {
    id: weatherRetryTimer
    interval: root.weatherRetryMs
    onTriggered: if (root.weatherWanted) root.requestWeather()
  }

  // The three-hour cutoff applies while a report is held, replies or not.
  Timer {
    interval: 60000
    repeat: true
    running: root.weatherReport !== null
    onTriggered: root.weatherClockMs = Date.now()
  }

  // Any key closes the preview; while holding, keys are only swallowed.
  function previewKeyPressed(event) {
    previewVisible = false
    if (event) event.accepted = true
  }

  function endPreviewHold() {
    previewHoldTimer.stop()
    previewHolding = false
  }

  Timer {
    id: previewHoldTimer
    interval: root.previewHoldMs
    onTriggered: root.previewHolding = false
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) {
        root.passwordAttemptOpen = false
        root.finishUnlock()
      } else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onPamMessage: {
      if (!messageIsError) root.noteFingerprintReachedDevice()
    }

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.settleFingerprintAttempt(true)
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: FingerprintModel.MATCH_RETRY_MS
    repeat: false
    onTriggered: root.startFingerprint()
  }

  // Detect resume both during an active attempt and during backoff.
  Timer {
    id: fingerprintSleepWatch
    interval: 1000
    repeat: true
    running: root.lockRequested && root.fingerprintConfigured && (!root.fingerprintPaused || root.fingerprintAuthenticating)
    property double lastTickMs: 0
    onRunningChanged: lastTickMs = Date.now()
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept) root.restartFingerprintAfterSleep()
    }
  }

  // Timers stand still through a suspend, so the first tick after a resume
  // sees the wall clock jump. Runs only for the seconds after a lock request
  // that a suspend can take to begin.
  Timer {
    id: fingerprintResumeTimer
    interval: 1000
    repeat: true
    property int ticksLeft: 0
    property double lastTickMs: 0
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept && root.lockRequested && root.fingerprintPaused) {
        stop()
        root.fingerprintSleptWhilePaused = true
        root.resumeFingerprint()
        root.armBlankTimer()
      } else if (slept || !root.fingerprintPaused || --ticksLeft <= 0) {
        stop()
      }
    }
  }

  Timer {
    id: fingerprintReachTimer
    interval: FingerprintModel.REACH_TIMEOUT_MS
    repeat: false
    onTriggered: root.timeoutFingerprintReach()
  }

  // Match the view's URL, logical size and fill mode so the first lock frame
  // can use an already decoded image. Video uses only a cached still frame.
  Variants {
    model: Quickshell.screens
    Image {
      required property var modelData
      visible: false
      source: width > 0 && height > 0 ? root.lockWallpaperUrl : ""
      width: modelData.width
      height: modelData.height
      sourceSize.width: width
      sourceSize.height: height
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
    }
  }

  Process {
    id: wallpaperProbeProc
    // The helper resolves the link like readlink -f and stats the target:
    // {"ok":true,"path":"/…","signature":"…"}, the signature changing with the
    // file's size, mtime or ctime. Any failure keeps the themed background.
    command: ["timeout", "--kill-after=1s", "2s"].concat(FoamyNative.command(
      FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["wallpaper", root.currentBackgroundLink]))
    clearEnvironment: true
    environment: ({ PATH: "/usr/bin", LANG: "C.UTF-8" })
    stdout: StdioCollector { id: backgroundOutput; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var data = null
      if (FoamyNative.unavailable(exitCode)) {
        root.wallpaperHelperUnavailable = true
      } else if (exitCode === 0 && exitStatus === 0) {
        try { data = JSON.parse(backgroundOutput.text) } catch (error) { data = null }
      }
      if (!data || data.ok !== true || typeof data.path !== "string" || data.path[0] !== "/"
          || typeof data.signature !== "string" || data.signature.length === 0) {
        root.backgroundPath = ""
        root.videoPosterPath = ""
        root.wallpaperError = root.wallpaperHelperUnavailable ? "helper-unavailable" : "wallpaper-unavailable"
      } else {
        if (data.path !== root.backgroundPath || data.signature !== root.backgroundSignature) {
          root.videoPosterPath = ""
          root.backgroundPath = data.path
          root.backgroundSignature = data.signature
          root.backgroundVersion += 1
        }
        root.wallpaperError = ""
        root.refreshPoster()
      }
      if (root.backgroundProbePending) root.refreshBackground()
    }
  }

  Process {
    id: posterProc
    property string sourcePath: ""
    property string sourceSignature: ""
    property string request: ""
    // A video Omarchy wallpaper's still: the poster of the helper's
    // video-probe (the same sandboxed probe and cache as a picture source's
    // video), never a decoder outside the sandbox. Its own limit is 60 s.
    command: ["timeout", "--kill-after=1s", "65s"].concat(root.posterProbeCommand)
    clearEnvironment: true
    environment: ({ HOME: root.home, XDG_CACHE_HOME: Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache",
      PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: posterOutput; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A theme can change during extraction; never show the previous theme's frame.
      if (sourcePath !== root.backgroundPath || sourceSignature !== root.backgroundSignature) {
        root.refreshPoster()
        return
      }
      var result = Model.videoProbeResult(exitCode === 0 && exitStatus === 0 ? posterOutput.text : "", root.videoCacheDirectory)
      if (result.ok && result.poster) {
        root.videoPosterPath = result.poster
        root.wallpaperError = ""
      } else {
        root.videoPosterPath = ""
        root.wallpaperError = FoamyNative.unavailable(exitCode) ? "video-poster-unavailable" : "video-poster-failed"
      }
    }
  }

  Process {
    id: passwdIdentityProc
    command: ["getent", "passwd", root.userName]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPasswdIdentity(text)
    }
    onExited: {
      if (root.userName && !accountsIdentityProc.running) accountsIdentityProc.running = true
    }
  }

  Process {
    id: accountsIdentityProc
    // AccountsService owns the desktop-facing real name and avatar. getent and
    // ~/.face remain usable when the service or its optional fields are absent.
    command: [
      "bash", "-c",
      "uid=$(id -u -- \"$1\") || exit 1; exec busctl --system --json=short get-property org.freedesktop.Accounts \"/org/freedesktop/Accounts/User${uid}\" org.freedesktop.Accounts.User RealName IconFile UserName HomeDirectory",
      "lock-identity", root.userName
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAccountsIdentity(text)
    }
  }

  Process {
    id: pictureProc
    property string request: ""
    // The helper's own job limit is 9 s.
    command: ["timeout", "--kill-after=1s", "12s"].concat(FoamyNative.command(
      FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["artwork"]))
    clearEnvironment: true
    environment: ({ HOME: root.home, XDG_CACHE_HOME: Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache",
      PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: pictureOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (FoamyNative.unavailable(exitCode)) {
        root.pictureHelperUnavailable = true
        root.applyPictureResult('{"ok":false,"error":"helper-unavailable"}')
      } else {
        root.applyPictureResult(pictureOutput.text)
      }
      if (root.picturePending) {
        root.picturePending = false
        root.refreshPicture()
      }
    }
  }

  Process {
    id: videoProc
    property string request: ""
    // The helper's own job limit is 60 s (hashing up to 2 GiB, ffprobe and
    // the poster, each in its sandbox).
    command: ["timeout", "--kill-after=1s", "65s"].concat(FoamyNative.command(
      FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["video-probe"]))
    clearEnvironment: true
    environment: ({ HOME: root.home, XDG_CACHE_HOME: Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache",
      PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: videoOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (FoamyNative.unavailable(exitCode)) {
        root.videoHelperUnavailable = true
        root.applyVideoResult('{"ok":false,"error":"helper-unavailable"}', videoProc.request)
      } else {
        root.applyVideoResult(videoOutput.text, videoProc.request)
      }
      if (root.videoPending) {
        root.videoPending = false
        root.refreshVideo()
      }
    }
  }

  Process {
    id: avatarThumbnailProc
    property string request: ""
    command: ["timeout", "--kill-after=1s", "10s"].concat(FoamyNative.command(
      FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["artwork"]))
    clearEnvironment: true
    environment: ({ HOME: root.home, XDG_CACHE_HOME: Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache",
      PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: avatarOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (FoamyNative.unavailable(exitCode)) {
        root.avatarHelperUnavailable = true
        root.applyAvatarResult('{"ok":false,"error":"helper-unavailable"}')
      } else {
        root.applyAvatarResult(avatarOutput.text)
      }

      if (avatarThumbnailPending) {
        avatarThumbnailPending = false
        refreshAvatarThumbnail()
      }
    }
  }

  // The probe hands fprintd-list's raw output (errors included) to
  // classifyProbe, which answers yes, no, or unknown; only a definitive
  // answer may change fingerprintConfigured. See applyFingerprintProbe.
  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1; then LC_ALL=C fprintd-list \"$USER\" 2>&1; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: root.applyFingerprintProbe(fingerprintCheckStdout.text)
  }

  // Retries a probe that could not reach fprintd, paced like the attempt
  // retries so a daemon that stays unreachable is asked about ever less often.
  Timer {
    id: fingerprintRecheckTimer
    interval: FingerprintModel.ERROR_RETRY_BASE_MS
    repeat: false
    onTriggered: root.refreshFingerprintStatus()
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-lock-stranded \"$PPID\""]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.currentlyLocked()
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    interval: root.settings.blankAfterSec === null ? 30000 : root.settings.blankAfterSec * 1000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      var screens = root.realScreenCount()
      // Only an arriving display wakes the reader; unplugging one must not.
      if (screens > root.knownScreenCount) {
        root.resumeFingerprint()
        if (root.lockRequested) root.armBlankTimer()
      }
      root.knownScreenCount = screens
      root.requestSessionLock()
      root.refreshPicture()
      root.refreshVideoScreens()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  // Service entries are not exposed through the scoped shell API. Watch the
  // same shell.json as Omarchy and retain the last valid preferences on errors.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfiguration(text())
    onFileChanged: reload()
    onLoadFailed: {
      root.entryState = "unreadable"
      root.configError = "Cannot read " + root.configPath
      console.warn("foamy.lock: " + root.configError + "; keeping previous settings")
    }
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    knownScreenCount = realScreenCount()
    refreshBackground()
    refreshFingerprintStatus()
    refreshUserIdentity()
    checkStrandedLock()
    Qt.callLater(checkLockRoute)
  }

  function statusJson() {
    checkLockRoute()
    var reasons = conflictReasons()
    return JSON.stringify({
      settings: root.settings,
      configError: root.configError,
      preset: root.look.preset,
      look: root.look,
      lookError: root.lookError,
      layoutError: root.layoutError,
      fallbackPreset: root.fallbackPreset,
      activeSurfaces: root.activeSurfaces,
      previewPreset: root.previewLook ? root.previewLook.preset : "",
      // User presets: their ids and names, the items skipped, the link.
      userPresets: root.userPresets.map(function(preset) { return { id: preset.id, name: preset.name } }),
      userPresetsInvalid: root.userPresetsInvalid,
      userPresetsError: root.userPresetsError,
      userPreset: root.userPresetLink,
      // Never the place name: status is readable by any local process.
      weather: { state: root.weatherState, shown: root.weather !== null, polls: root.weatherPolls,
        updatedAt: root.weatherReport ? new Date(root.weatherReport.updatedAtMs).toISOString() : "" },
      locked: root.currentlyLocked(),
      requested: root.lockRequested,
      pending: root.pendingSessionLock,
      sessionLocked: sessionLock.locked,
      secure: sessionLock.secure,
      realScreens: root.realScreenCount(),
      passwordPam: root.passwordPamConfigured,
      fingerprint: root.fingerprintConfigured,
      fingerprintUnavailable: root.fingerprintUnavailable,
      fingerprintPaused: root.fingerprintPaused,
      displayBlanked: root.displayBlanked,
      authenticating: root.authenticating,
      wallpaperError: root.wallpaperError,
      artworkState: artwork.state,
      artworkError: artwork.error,
      userName: root.userName,
      displayName: root.userDisplayName || root.userName,
      avatarPath: root.userAvatarPath,
      avatarRenderPath: root.userAvatarRenderPath,
      avatarError: root.avatarError,
      pictureError: root.pictureError,
      picturePath: root.pictureRenderPath,
      // A video background: the probe's poster and clip ("" without), why
      // not, and the last view to give up on the clip ("error", "stall").
      video: { poster: root.videoPosterRender, clip: root.videoClipPath, error: root.videoError,
        failure: root.videoFailure, request: root.videoRequestKey ? JSON.parse(root.videoRequestKey) : null },
      conflict: reasons.length > 0,
      conflictReasons: reasons,
      ipcFastPath: IpcResolver.fastPath(root),
      // 4.5: this plugin answers the "lock" target on the omarchy-shell socket.
      ipcRouteFirst: lockRoute.answering,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  // Keep the host IPC contract used by Omarchy lock and idle commands. On 4.5
  // FoamyIpc also registers with IpcRegistry, so omarchy-shell reaches this
  // over the shell socket, including omarchy-system-sleep-lock's pre-suspend
  // poll. Only lock, isLocked, status, preview and hidePreview exist: nothing
  // here can unlock.
  FoamyIpc {
    id: lockIpc
    target: "lock"

    function lock(): string {
      root.checkLockRoute()
      if (!root.passwordPamConfigured) return "missing-pam"
      // The pre-suspend service requests a lock even when already locked.
      if (root.currentlyLocked()) root.noteSleepRequested()
      if (!root.currentlyLocked() && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.currentlyLocked() ? "true" : "false"
    }

    function status(): string {
      return root.statusJson()
    }

    function preview(): string {
      // Like previewLook and previewPreset: no overlay over a real lock.
      if (root.currentlyLocked()) return "locked"
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshUserIdentity()
      root.previewLook = null
      root.previewVisible = true
      root.openWeather()
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      root.previewLook = null
      return "ok"
    }
  }

  // Re-claims the front of IpcRegistry's "lock" list on start, on
  // checkLockRoute() and every few seconds on 4.5 (a short array scan), so a
  // lock service registered or promoted later cannot take the route over.
  FoamyIpcPreference {
    id: lockRoute
    handler: lockIpc
    onOthersChanged: Qt.callLater(root.checkLockRoute)
  }

  // A target only this plugin uses, so its status (and the conflict flag)
  // stays reachable even if another lock service answers "lock".
  FoamyIpc {
    id: foamyLockIpc
    target: "foamy.lock"

    function status(): string {
      return root.statusJson()
    }

    // The preview overlay with a built-in preset instead of the saved look.
    // Nothing is saved; `lock preview` and hidePreview go back to the look.
    // Like the rest of IPC, nothing here can unlock.
    // Everything an editor needs to offer choices without hard-coding them:
    // elements, zones, styles, the element keys and their limits, presets (with
    // their looks and thumbnails), background sources and the saved look.
    // Read-only. Version 2 added elementLimits (scale, opacity, offset, glass,
    // screens; see Layout.elementLimits). Version 3 added the weather element,
    // the new date and calendar styles, each element's own keys
    // (elementKeysFor; their values and defaults in elementLimits.*.options),
    // statusItems, and weather: whether Foamy Weather answers here
    // (`target`: a foamy.weather target is registered; `state`: the last
    // answer's, see weatherState).
    function catalog(): string {
      var dir = FoamyNative.localPath(Qt.resolvedUrl("."))
      var presets = []
      for (var i = 0; i < Layout.SELECTABLE_PRESETS.length; i++) {
        var name = Layout.SELECTABLE_PRESETS[i]
        presets.push({ name: name, look: Layout.preset(name), thumbnail: dir + "/previews/presets/" + name + ".png" })
      }
      var keysFor = {}
      for (var e = 0; e < Layout.ELEMENTS.length; e++) keysFor[Layout.ELEMENTS[e]] = Layout.elementKeys(Layout.ELEMENTS[e])
      return JSON.stringify({ version: 3, elements: Layout.ELEMENTS, elementKeys: Layout.ELEMENT_KEYS,
        elementKeysFor: keysFor, statusItems: Layout.STATUS_ITEMS,
        weather: { target: IpcResolver.handlersFor(root, "foamy.weather").length > 0, state: root.weatherState },
        elementLimits: Layout.elementLimits(), screens: Layout.SCREENS,
        zones: Layout.ZONES, passwordZones: Layout.PASSWORD_ZONES, styles: Layout.STYLES,
        presets: presets, backgroundSources: Layout.BACKGROUND_SOURCES, backgroundDecor: Layout.DECORATIONS,
        glassTints: Layout.GLASS_TINTS, defaultPreset: Layout.DEFAULT_PRESET,
        // Video backgrounds: background.motion and its defaults (additive).
        backgroundMotions: Layout.MOTIONS, backgroundDefaults: Layout.BACKGROUND_DEFAULTS,
        look: root.look, lookError: root.lookError,
        // User presets (R2-2): newest first, the items skipped, the link
        // and the limits of savePreset.
        userPresets: root.catalogUserPresets(dir), userPresetsInvalid: root.userPresetsInvalid,
        userPresetsError: root.userPresetsError, userPreset: root.userPresetLink,
        userPresetLimits: { count: Layout.USER_PRESET_LIMIT, bytes: Layout.USER_PRESETS_BYTES,
          name: Layout.USER_PRESET_NAME_LENGTH } })
    }

    // The preview overlay with an unsaved look: a JSON object with the same
    // keys as the foamy.lock entry (preset, layout, background, glass),
    // validated by the same rules. Nothing is saved; nothing can unlock.
    function previewLook(look: string): string {
      var entry = null
      var text = String(look || "")
      var big = Layout.ipcArgumentError(text)
      if (big) return "invalid: " + big
      try { entry = JSON.parse(text) } catch (error) { return "invalid-json" }
      var parsed = Layout.parseLook(entry)
      if (!parsed.valid) return "invalid: " + parsed.error
      if (root.currentlyLocked()) return "locked"
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshUserIdentity()
      root.previewLook = parsed.look
      root.previewVisible = true
      root.openWeather()
      return "ok"
    }

    // Save a look from an editor: the foamy.lock entry's look keys (preset,
    // layout, background, glass) and `userPreset` (the user preset it came
    // from), validated like shell.json. They replace the entry's look keys
    // (omitted ones are removed, so a reset drops its overrides, and a look
    // saved without `userPreset` drops the link); every other setting in the
    // entry is kept. Written through Omarchy's own updateEntryInline
    // (FileView atomicWrites: a symlinked shell.json stays a symlink), so
    // the change comes back through the normal config watch. "write-failed"
    // when Omarchy would skip the write (shell.json unreadable). Nothing here
    // can unlock.
    function saveLook(look: string): string {
      var keys = ["preset", "layout", "background", "glass", "userPreset"]
      var request = null
      var text = String(look || "")
      var big = Layout.ipcArgumentError(text)
      if (big) return "invalid: " + big
      try { request = JSON.parse(text) } catch (error) { return "invalid-json" }
      if (!request || typeof request !== "object" || Array.isArray(request)) return "invalid: expected an object"
      for (var key in request)
        if (keys.indexOf(key) === -1) return "invalid: unknown key " + key
      var parsed = Layout.parseLook(request)
      if (!parsed.valid) return "invalid: " + parsed.error
      if (request.userPreset !== undefined && Layout.userPresetIdError(request.userPreset))
        return "invalid: userPreset must be a user preset's id"
      if (root.currentlyLocked()) return "locked"
      var base = root.writableEntry()
      if (typeof base === "string") return base
      var next = {}
      for (var existing in base)
        if (existing !== "id" && keys.indexOf(existing) === -1) next[existing] = base[existing]
      for (var i = 0; i < keys.length; i++)
        if (request[keys[i]] !== undefined) next[keys[i]] = request[keys[i]]
      return root.writeEntry(next)
    }

    // A built-in preset by name, or a user preset as `user:<id>`.
    function previewPreset(name: string): string {
      var user = String(name).indexOf("user:") === 0 ? Layout.findUserPreset(root.userPresets, String(name).slice(5)) : null
      if (!user && Layout.SELECTABLE_PRESETS.indexOf(name) === -1) return "unknown-preset"
      if (root.currentlyLocked()) return "locked"
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshUserIdentity()
      root.previewLook = user ? user.effective : Layout.preset(name)
      root.previewVisible = true
      root.openWeather()
      return "ok"
    }

    // User presets (Layout.js, "user presets"), one item per call, merged
    // into the entry as last read: the list itself never crosses IPC (an
    // argument is at most 64 KiB). The replies are saveLook's (ok,
    // unchanged, invalid-json, invalid: …, locked, unsupported, no-entry,
    // write-failed) plus full (50 presets), too-large (256 KiB of presets)
    // and unknown-preset (renamePreset). Nothing here can unlock.

    // `preset`: { id, name, look }, `look` with the look keys saveLook takes
    // but `userPreset`. The id is the caller's own, so a retry is the same
    // save ("unchanged" once the first landed). A known id is updated where
    // it is; a new one goes first.
    function savePreset(preset: string): string {
      var item = null
      var text = String(preset || "")
      var big = Layout.ipcArgumentError(text)
      if (big) return "invalid: " + big
      try { item = JSON.parse(text) } catch (error) { return "invalid-json" }
      var problem = Layout.userPresetError(item)
      if (problem) return "invalid: " + problem
      if (root.currentlyLocked()) return "locked"
      var base = root.writableEntry()
      if (typeof base === "string") return base
      var change = Layout.savingPreset(base, item)
      return change.error || root.writeEntry(change.entry)
    }

    function renamePreset(presetId: string, name: string): string {
      var problem = Layout.userPresetIdError(presetId) || Layout.userPresetNameError(name)
      if (problem) return "invalid: " + problem
      if (root.currentlyLocked()) return "locked"
      var base = root.writableEntry()
      if (typeof base === "string") return base
      var change = Layout.renamingPreset(base, presetId, name)
      return change.error || root.writeEntry(change.entry)
    }

    // An id that isn't there answers "unchanged"; the saved look keeps
    // working, without its link.
    function deletePreset(presetId: string): string {
      var problem = Layout.userPresetIdError(presetId)
      if (problem) return "invalid: " + problem
      if (root.currentlyLocked()) return "locked"
      var base = root.writableEntry()
      if (typeof base === "string") return base
      var change = Layout.deletingPreset(base, presetId)
      return change.error || root.writeEntry(change.entry)
    }
  }
}
