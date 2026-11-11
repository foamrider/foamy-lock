import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: shell
  property var stock: null
  // A stand-in for Foamy Weather's service (4.5 only): a foamy.weather
  // target in IpcRegistry that answers current() with `reply`, where
  // __UPDATED__ becomes the time `age` seconds ago (ISO 8601).
  property var weatherPeer: null
  property string weatherReply: ""
  property int weatherAge: 0
  property int weatherCalls: 0
  // Stands in for Omarchy's shell: records what saveLook asks it to write.
  QtObject {
    id: fakeShell
    property string module: ""
    property var entry: null
    function updateEntryInline(moduleName, settings) {
      var changed = JSON.stringify(entry) !== JSON.stringify(settings)
      module = moduleName
      entry = settings
      return changed
    }
  }
  Service { id: service; shell: fakeShell }
  function weatherAnswer() {
    weatherCalls++
    return weatherReply.replace("__UPDATED__", new Date(Date.now() - weatherAge * 1000).toISOString())
  }
  IpcHandler {
    target: "test"
    function submit(value: string): string { service.submitPassword(value); return "ok" }
    function failures(): string { return String(service.failedAttempts) }
    function savedEntry(): string { return JSON.stringify({module: fakeShell.module, entry: fakeShell.entry}) }
    function fingerprintState(): string {
      return JSON.stringify({starts: service.testFingerprintPam.starts,
        generation: service.testFingerprintPam.generation,
        streak: service.fingerprintUnreachedStreak,
        delay: service.testRetry.interval, retrying: service.testRetry.running,
        active: service.testFingerprintPam.active,
        probing: service.fingerprintProbeStreak,
        probeRetrying: service.testProbeRetry.running,
        backoff: service.fingerprintRetryBackoffMs, due: service.fingerprintRetryDueMs,
        resumeWatching: service.testResume.running, probeRunning: service.testFingerprintCheck.running})
    }
    function fingerprintFail(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.error(1)
      service.testFingerprintPam.completed(1)
      return "ok"
    }
    function blank(): string { service.runBlank(); return "ok" }
    function wake(): string { service.runWake(); return "ok" }
    function displayCommands(): string {
      return JSON.stringify({wake: service.testWake.running, blank: service.testBlank.running, blanked: service.displayBlanked,
        blankQueued: service.blankAfterWake, blankInterval: service.testIdleBlank.interval, blankArmed: service.testIdleBlank.running})
    }
    // runBlank, and the display commands as it left them (one call, so the
    // wake it may wait for is still the one that was running).
    function blankNow(): string { service.runBlank(); return displayCommands() }
    // The idle countdown as a suspend leaves it: armed long ago.
    function blankGap(): string { service.testIdleBlank.armedAt -= 60000; return "ok" }
    function identityRefresh(): string { service.refreshUserIdentity(); return "ok" }
    function identity(): string {
      return JSON.stringify({name: service.userDisplayName, passwd: service.testPasswd.running,
        accounts: service.testAccounts.running})
    }
    function posterUnstartable(value: bool): string { service.testPosterUnstartable = value; return "ok" }
    function posterState(): string { return JSON.stringify({running: service.testPoster.running}) }
    function unpause(): string { service.resumeFingerprint(); return "ok" }
    function sleepGap(): string { service.testResume.lastTickMs -= 10000; return "ok" }
    function strandedCheck(): string { service.strandedLockResolved = false; service.checkStrandedLock(); return "ok" }
    function strandedResolved(): string { return String(service.strandedLockResolved) }
    function staleLock(value: bool): string { service.testStaleLocked = value; return "ok" }
    function fingerprintMismatch(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.completed(1)
      return "ok"
    }
    function oldPrompt(): string { service.fingerprintAttemptPromptedAtMs -= 3000; return "ok" }
    function wallpaperRefresh(): string { service.refreshBackground(); return "ok" }
    function wallpaperState(): string {
      return JSON.stringify({path: service.lockWallpaperPath, version: service.backgroundVersion,
        source: service.backgroundPath, error: service.wallpaperError})
    }
    function fingerprintPrompt(): string { service.testFingerprintPam.pamMessage(); return "ok" }
    function fingerprintMatch(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.completed(0)
      return "ok"
    }
    function fingerprintProbe(): string { service.refreshFingerprintStatus(); return "ok" }
    function resume(): string { service.restartFingerprintAfterSleep(); return "ok" }
    function missingPam(): string { service.passwordPamConfigured = false; return "ok" }
    function doubleReport(value: bool): string { service.testPasswordPam.doubleReport = value; return "ok" }
    function previewState(): string { return String(service.previewVisible) }
    function previewKey(): string { var event = { accepted: false }; service.previewKeyPressed(event); return String(event.accepted) }
    // The overlay's parts: the banner, the hint, the keyboard hold.
    // foamy.lock's JSON calls with arguments just over and at 64 KiB.
    function bigArguments(): string {
      var ipc = service.testFoamyIpc
      function pad(head, bytes) { return head + " ".repeat(bytes - head.length) }
      var look = '{"preset":"zen"}'
      return JSON.stringify({
        previewLook: { over: ipc.previewLook(pad(look, 65537)), at: ipc.previewLook(pad(look, 65536)) },
        saveLook: { over: ipc.saveLook(pad(look, 65537)), at: ipc.saveLook(pad('{"preset":"zen","bogus":1}', 65536)) },
        savePreset: { over: ipc.savePreset(pad(look, 65537)), at: ipc.savePreset(pad('{"id":"big"}', 65536)) } })
    }
    function previewParts(): string {
      function find(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var children = item.children || []
        for (var i = 0; i < children.length; i++) { var found = find(children[i], name); if (found) return found }
        return null
      }
      var banner = find(service, "previewBanner")
      var view = find(service, "previewView")
      var title = banner ? find(banner, "previewBannerTitle") : null
      var hint = banner ? find(banner, "previewBannerHint") : null
      // Drawn, not only set (the banner once laid out at zero width and drew
      // an empty box): the title whole on its line, the hint with room.
      function drawn(text) {
        return !!text && text.text !== "" && text.width > 0 && text.paintedWidth > 0 && text.paintedHeight > 0
          && !text.truncated && text.opacity > 0
      }
      return JSON.stringify({ visible: service.previewVisible, holding: service.previewHolding,
        banner: !!banner && banner.visible, title: title ? title.text : "", hint: hint ? hint.text : "",
        plain: !!title && title.textFormat === Text.PlainText && hint.textFormat === Text.PlainText,
        drawn: drawn(title) && drawn(hint) && title.width >= Math.ceil(title.implicitWidth) - 1
          && banner.width >= title.width && banner.height > title.height + hint.height,
        size: banner ? [banner.width, banner.height, title.width, title.implicitWidth, title.paintedWidth] : [],
        view: !!view && view.visible, unlockHint: view ? view.showUnlockHint : null })
    }
    // 4.5 only: what the omarchy-shell socket would answer, with a second
    // "lock" handler (standing in for omarchy.lock) registered ahead of foamy.
    function registry() {
      var probe = Qt.createQmlObject('import QtQuick; import qs.Commons; QtObject { function registry() { return IpcRegistry } }', service, "RegistryProbe")
      var found = probe.registry()
      probe.destroy()
      return found
    }
    function registryDirect(): string {
      var found = registry()
      return JSON.stringify({direct: found.call("lock", "status", []), refused: found.call("lock", "destroy", [])})
    }
    // Put the stand-in ahead of foamy without telling foamy, as if another
    // service (or a later prefer()) had promoted itself.
    function registryShadow(): string {
      var found = registry()
      shell.stock = Qt.createQmlObject('import qs.Commons; ShellIpc { target: "lock"; function status(): string { return "stock" } function lock(): string { return "stock" } function isLocked(): string { return "stock" } }', service, "StockLock")
      found.unregister(shell.stock)
      found.handlers.unshift(shell.stock)
      return String(found.handlerFor("lock") === shell.stock)
    }
    function registryRoute(): string {
      var found = registry()
      return JSON.stringify({first: found.handlerFor("lock") !== shell.stock,
        status: found.call("lock", "status", []), isLocked: found.call("lock", "isLocked", []),
        lock: found.call("lock", "lock", [])})
    }
    // "none" removes the target; current false stands in for an older
    // Foamy Weather (the target without current()).
    function weatherPeer(reply: string, age: string, current: bool): string {
      shell.weatherReply = reply
      shell.weatherAge = Number(age)
      shell.weatherCalls = 0
      var kind = reply === "none" ? "" : current ? "current" : "older"
      if (shell.weatherPeer && shell.weatherPeer.kind === kind) return "ok"
      if (shell.weatherPeer) {
        registry().unregister(shell.weatherPeer)
        shell.weatherPeer.destroy()
        shell.weatherPeer = null
      }
      if (!kind) return "ok"
      var body = current ? 'function current(): string { return shell.weatherAnswer() }' : 'function forecast(): string { return "{}" }'
      shell.weatherPeer = Qt.createQmlObject('import qs.Commons; ShellIpc { target: "foamy.weather"; readonly property string kind: "'
        + kind + '"; ' + body + ' }', shell, "WeatherPeer")
      return "ok"
    }
    function weather(): string {
      return JSON.stringify({ calls: shell.weatherCalls, state: service.weatherState, polls: service.weatherPolls,
        pendingLeft: service.weatherPendingLeft, retrying: service.testWeatherRetry.running, wanted: service.weatherWanted,
        report: service.weatherReport, shown: service.weather })
    }
    function registryCleanup(): string {
      var found = registry()
      found.unregister(shell.stock)
      shell.stock.destroy()
      shell.stock = null
      service.checkLockRoute()
      return "ok"
    }
  }
}
