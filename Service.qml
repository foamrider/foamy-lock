import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Services.Mpris
import Quickshell.Wayland
// Qualify the theme singleton to avoid QtQuick.Color taking precedence.
import qs.Commons as Commons
import "kit"
import "kit/FoamyIpcResolver.js" as IpcResolver
import "Model.js" as Model
// Fingerprint recovery adapted from Omarchy PR #7158 and v4.5.0-rc1 (03ff1ef).
import "FingerprintModel.js" as FingerprintModel

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
  property double fingerprintRetryDueMs: 0
  property int fingerprintRetryBackoffMs: 0
  property int knownScreenCount: 0
  property double fingerprintLastNudgeMs: 0
  property double fingerprintLastSettleMs: 0
  property double fingerprintResumedAtMs: 0
  property int fingerprintProbeStreak: 0
  property bool previewVisible: false
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
  readonly property bool videoBackground: Model.isVideoPath(backgroundPath)
  readonly property string lockWallpaperPath: videoBackground ? videoPosterPath : backgroundPath
  readonly property string lockWallpaperUrl: Model.fileUrl(lockWallpaperPath, backgroundVersion)
  property string userDisplayName: ""
  property string userAvatarPath: ""
  property string userAvatarRenderPath: ""
  property int userAvatarVersion: 0
  property bool avatarThumbnailPending: false
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
    allowed: root.settings.showMedia && root.settings.showArtwork
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
    // Services may have been added or removed with this edit.
    Qt.callLater(claimLockRoute)
  }

  // Other live handlers for the "lock" IPC target in 4.5's IpcRegistry, which
  // answers the omarchy-shell socket. 4.0 has no registry: an empty list.
  function otherLockHandlers() {
    var registry = IpcResolver.registry(root)
    if (!registry || !Array.isArray(registry.handlers)) return []
    return registry.handlers.filter(function(handler) {
      return handler && handler !== lockIpc && handler.enabled && handler.target === "lock"
    })
  }

  // The socket answers from the first enabled handler for a target. When a
  // second lock service is loaded anyway, keep `lock`, `isLocked` and
  // `status` on this one, the lock the user enabled, so the request and the
  // pre-suspend status poll always reach the same session lock; status then
  // reports the conflict. This only reorders the registry's list: no other
  // handler is removed, disabled or called.
  function claimLockRoute() {
    var registry = IpcResolver.registry(root)
    if (registry && Array.isArray(registry.handlers)) {
      var index = registry.handlers.indexOf(lockIpc)
      if (index > 0 && otherLockHandlers().length > 0) {
        registry.handlers.splice(index, 1)
        registry.handlers.unshift(lockIpc)
      }
    }
    var reasons = conflictReasons()
    var key = reasons.join(",")
    if (key && key !== conflictLogged) console.warn("foamy.lock: another lock service is loaded (" + key + "); keep omarchy.lock in disabledPlugins")
    conflictLogged = key
  }

  function conflictReasons() {
    var reasons = []
    if (stockLockEnabled === true) reasons.push("stock-lock-enabled")
    if (otherLockHandlers().length > 0) reasons.push("lock-target-shared")
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
    if (readlinkProc.running) {
      backgroundProbePending = true
      return
    }
    backgroundProbePending = false
    readlinkProc.running = true
  }

  function refreshPoster() {
    if (!videoBackground) {
      videoPosterPath = ""
      return
    }
    if (posterProc.running) return
    posterProc.sourcePath = backgroundPath
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

    // The same sandboxed decoder as media artwork (artwork.py), bounded by
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
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshUserIdentity()
    })

    return true
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
        anchors.fill: parent
        backgroundPath: root.lockWallpaperPath
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
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "foamy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.lockWallpaperPath
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
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }

    // The overlay holds exclusive keyboard focus, so any key closes it too:
    // without a pointer it would otherwise block the keyboard until hidePreview.
    Item {
      id: previewKeys
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) { root.previewKeyPressed(event) }
    }
  }

  function previewKeyPressed(event) {
    previewVisible = false
    if (event) event.accepted = true
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
    id: readlinkProc
    command: ["timeout", "--kill-after=1s", "2s", "bash", "-c",
      'path=$(readlink -f -- "$1") && signature=$(stat -Lc "%s:%y:%z" -- "$path") && jq -cn --arg path "$path" --arg signature "$signature" \'{path:$path,signature:$signature}\'',
      "foamy-lock-wallpaper", root.currentBackgroundLink]
    stdout: StdioCollector { id: backgroundOutput; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var data = null
      if (exitCode === 0 && exitStatus === 0) {
        try { data = JSON.parse(backgroundOutput.text) } catch (error) { data = null }
      }
      if (!data || typeof data.path !== "string" || data.path[0] !== "/" || typeof data.signature !== "string") {
        root.backgroundPath = ""
        root.videoPosterPath = ""
        root.wallpaperError = "wallpaper-unavailable"
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
    // 4.5 owns this helper and its decoder/cache. 4.0.6 has no helper and
    // keeps the plain background for videos without importing any new QML API.
    command: ["timeout", "--kill-after=1s", "16s", "bash", "-c",
      '[[ -f $1 ]] || exit 69; exec bash "$1" "$2"', "foamy-lock-poster",
      (root.omarchyPath || Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell/plugins/lock/poster.sh", sourcePath]
    stdout: StdioCollector { id: posterOutput; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A theme can change during extraction; never show the previous theme's frame.
      if (sourcePath !== root.backgroundPath || sourceSignature !== root.backgroundSignature) {
        root.refreshPoster()
        return
      }
      var path = String(posterOutput.text || "").trim()
      if (exitCode === 0 && exitStatus === 0 && path[0] === "/" && !Model.isVideoPath(path)) {
        root.videoPosterPath = path
        root.wallpaperError = ""
      } else {
        root.videoPosterPath = ""
        root.wallpaperError = exitCode === 69 ? "video-poster-unavailable" : "video-poster-failed"
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
    id: avatarThumbnailProc
    property string request: ""
    command: ["timeout", "--kill-after=1s", "10s", "/usr/bin/python3", "-I", "-B",
      decodeURIComponent(Qt.resolvedUrl("artwork.py").toString().replace(/^file:\/\//, ""))]
    clearEnvironment: true
    environment: ({ HOME: root.home, XDG_CACHE_HOME: Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache",
      PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      write(request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { id: avatarOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyAvatarResult(avatarOutput.text)

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
    Qt.callLater(claimLockRoute)
  }

  function statusJson() {
    claimLockRoute()
    var reasons = conflictReasons()
    return JSON.stringify({
      settings: root.settings,
      configError: root.configError,
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
      authenticating: root.authenticating,
      wallpaperError: root.wallpaperError,
      artworkState: artwork.state,
      artworkError: artwork.error,
      userName: root.userName,
      displayName: root.userDisplayName || root.userName,
      avatarPath: root.userAvatarPath,
      avatarRenderPath: root.userAvatarRenderPath,
      avatarError: root.avatarError,
      conflict: reasons.length > 0,
      conflictReasons: reasons,
      ipcFastPath: IpcResolver.fastPath(root),
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
      root.claimLockRoute()
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
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshUserIdentity()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }

  // A target only this plugin uses, so its status (and the conflict flag)
  // stays reachable even if another lock service answers "lock".
  FoamyIpc {
    target: "foamy.lock"

    function status(): string {
      return root.statusJson()
    }
  }
}
