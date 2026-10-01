import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Services.Mpris
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model
// Fingerprint recovery adapted from Omarchy PR #7158 (e77ed414f283).
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
  property string userDisplayName: ""
  property string userAvatarPath: ""
  property string userAvatarRenderPath: ""
  property int userAvatarVersion: 0
  property bool avatarThumbnailPending: false
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating
  readonly property bool fingerprintUnavailable: fingerprintConfigured && !fingerprintAttemptReachedDevice && FingerprintModel.isUnavailable(fingerprintUnreachedStreak)
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  property var settings: Model.defaults()
  property string configError: ""
  readonly property var activePlayer: settings.showMedia
    ? Model.selectPlayer(Mpris.players.values) : null
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
    if (result.valid) settings = result.settings
    else console.warn("foamy.lock: " + configError + "; keeping previous settings")
  }

  onSettingsChanged: {
    if (lockRequested) armBlankTimer()
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
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
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

    avatarThumbnailProc.command = [
      "bash", "-c",
      'mkdir -p -- "$1" && exec magick "$2" -auto-orient -filter Lanczos -resize "256x256^" -gravity center -extent 256x256 "png:$3"',
      "foamy-lock-avatar", avatarCacheDirectory, userAvatarPath, userAvatarCachePath
    ]
    avatarThumbnailProc.running = true
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
    fingerprintAuthenticating = false
    fingerprintUnreachedStreak = 0
    fingerprintAttemptReachedDevice = false
    fingerprintLastNudgeMs = 0
    fingerprintLastSettleMs = 0
    fingerprintResumedAtMs = 0
    fingerprintProbeStreak = 0
    fingerprintRecheckTimer.stop()
    fingerprintRetryTimer.stop()
    fingerprintReachTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
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
    if (!root.locked && !lockRequested) return

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
    nudgeFingerprint()
  }

  // A keypress, touch, or cursor move is the user saying the reader is worth
  // trying now, so collapse a backed-off wait to a prompt retry rather than
  // ride out the cap. Rate-limited (see shouldNudge): a moving cursor raises a
  // wake per motion event, and without the floor each fresh backoff wait would
  // be re-collapsed straight back into the storm the backoff exists to prevent;
  // past the floor, the current tier paces repeat nudges.
  function nudgeFingerprint() {
    if (!lockRequested || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return
    if (!fingerprintRetryTimer.running) return
    var now = Date.now()
    if (!FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, fingerprintLastSettleMs, fingerprintRetryTimer.interval)) return
    fingerprintLastNudgeMs = now
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }

  function armFingerprintRetry(delayMs) {
    fingerprintRetryTimer.interval = delayMs
    fingerprintRetryTimer.armedAt = Date.now()
    fingerprintRetryTimer.restart()
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
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

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
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    fingerprintAttemptReachedDevice = false
    if (!fingerprintPam.start()) {
      // A start that fails before PAM even runs is a configuration problem
      // (the PAM file removed under the lock), not a reader miss. Settle for
      // pacing, then re-check: an unconfigured result hides the icon and stops
      // the retries rather than counting toward "reader unavailable".
      settleFingerprintAttempt()
      refreshFingerprintStatus()
      return
    }
    // Bound the wait for the first prompt: a claim fprintd accepts but never
    // completes (a device open stuck behind a wedged claim) otherwise sits here
    // for GDBus's full call timeout without erroring, and nothing downstream
    // re-arms. A daemon restarted under the verify is not that case; it fails
    // the attempt promptly. See REACH_TIMEOUT_MS for the bound's limits.
    fingerprintReachTimer.restart()
  }

  // A verify prompt is the only PAM message pam_fprintd relays, and only once
  // the claim has landed, so any non-error message means this attempt reached
  // the reader. Errors after the prompt are outside this recovery policy. It may now
  // wait for a finger as long as pam_fprintd allows, so the reach bound stops.
  function noteFingerprintReachedDevice() {
    fingerprintAttemptReachedDevice = true
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
  function settleFingerprintAttempt() {
    if (!fingerprintAuthenticating) return
    fingerprintAuthenticating = false
    fingerprintReachTimer.stop()
    if (!lockRequested || !fingerprintConfigured) return

    // The sleep watch ticks every second while locked, so a settle that finds
    // its last tick far in the past is the first thing to run after a resume:
    // this attempt was in flight across the suspend and was ended by the
    // restart, not by the reader. Judged from the tick rather than the
    // attempt's own age so a suspend shorter than the reach bound is caught
    // too, before the tick itself gets a chance to.
    var now = Date.now()
    if (!fingerprintAttemptReachedDevice && fingerprintSleepWatch.running
        && FingerprintModel.spannedSleep(now - fingerprintSleepWatch.lastTickMs, fingerprintSleepWatch.interval)) {
      noteFingerprintResumed()
    }

    // Reached attempts are the steady state (one per swipe window), so only
    // the misses and the recovery from them leave a trace.
    var previousStreak = fingerprintUnreachedStreak
    var inGrace = FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)
    fingerprintUnreachedStreak = FingerprintModel.nextStreak(previousStreak, fingerprintAttemptReachedDevice, inGrace)
    if (!fingerprintAttemptReachedDevice) {
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
      settleFingerprintAttempt()
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
      color: Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
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
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
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
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
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
      root.settleFingerprintAttempt()
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: FingerprintModel.MATCH_RETRY_MS
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A wait that took far longer on the wall clock than its interval
      // spanned a suspend; see noteFingerprintResumed.
      if (FingerprintModel.spannedSleep(Date.now() - armedAt, interval)) root.noteFingerprintResumed()
      root.startFingerprint()
    }
  }

  // Watches the wall clock for the whole lock, so a resume is noticed within
  // a tick whatever the loop was doing -- mid-wait, or with an attempt in
  // flight that the restart is about to end.
  Timer {
    id: fingerprintSleepWatch
    interval: 1000
    repeat: true
    running: root.lockRequested && root.fingerprintConfigured
    property double lastTickMs: 0
    onRunningChanged: lastTickMs = Date.now()
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept) root.restartFingerprintAfterSleep()
    }
  }

  Timer {
    id: fingerprintReachTimer
    interval: FingerprintModel.REACH_TIMEOUT_MS
    repeat: false
    onTriggered: root.timeoutFingerprintReach()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
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
    onExited: function(exitCode) {
      userAvatarRenderPath = exitCode === 0 ? userAvatarCachePath : userAvatarPath
      userAvatarVersion += 1

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
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1; then fprintd-list \"$USER\" 2>&1; else echo no; fi"]
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
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
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
    refreshBackground()
    refreshFingerprintStatus()
    refreshUserIdentity()
    checkStrandedLock()
  }

  // Keep the host IPC contract used by Omarchy lock and idle commands.
  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        settings: root.settings,
        configError: root.configError,
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        fingerprintUnavailable: root.fingerprintUnavailable,
        authenticating: root.authenticating,
        artworkState: artwork.state,
        artworkError: artwork.error,
        userName: root.userName,
        displayName: root.userDisplayName || root.userName,
        avatarPath: root.userAvatarPath,
        avatarRenderPath: root.userAvatarRenderPath,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
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
}
