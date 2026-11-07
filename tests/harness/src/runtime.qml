import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: shell
  property var stock: null
  Service { id: service }
  IpcHandler {
    target: "test"
    function submit(value: string): string { service.submitPassword(value); return "ok" }
    function failures(): string { return String(service.failedAttempts) }
    function fingerprintState(): string {
      return JSON.stringify({starts: service.testFingerprintPam.starts,
        generation: service.testFingerprintPam.generation,
        streak: service.fingerprintUnreachedStreak,
        delay: service.testRetry.interval, retrying: service.testRetry.running,
        active: service.testFingerprintPam.active,
        probing: service.fingerprintProbeStreak,
        probeRetrying: service.testProbeRetry.running,
        backoff: service.fingerprintRetryBackoffMs, due: service.fingerprintRetryDueMs,
        resumeWatching: service.testResume.running})
    }
    function fingerprintFail(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.error(1)
      service.testFingerprintPam.completed(1)
      return "ok"
    }
    function blank(): string { service.runBlank(); return "ok" }
    function wake(): string { service.runWake(); return "ok" }
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
