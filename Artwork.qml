import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var player: null
  property bool allowed: true
  property bool locked: false
  property var hosts: []
  property var fileRoots: []
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache"
  readonly property string cacheDirectory: cacheHome + "/omarchy/foamy.lock/artwork/"
  readonly property var roots: [cacheHome].concat(
    Quickshell.env("XDG_RUNTIME_DIR") ? [Quickshell.env("XDG_RUNTIME_DIR")] : []).concat(fileRoots)
  readonly property string trackKey: allowed ? Model.artworkKey(player) : ""
  readonly property string requestKey: trackKey ? JSON.stringify([trackKey, hosts, roots]) : ""
  property string path: ""
  property string state: "empty"
  property string error: ""
  property bool initialized: false
  property bool busy: false
  property int generation: 0
  property var job: null
  property var entries: []
  property double lastStarted: 0

  function cached(key) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].key === key) return entries[i]
    }
    return null
  }

  function remember(entry) {
    entries = [entry].concat(entries.filter(function(other) { return other.key !== entry.key })).slice(0, 16)
  }

  function invalidate(failedPath) {
    if (!failedPath || failedPath !== path) return
    entries = entries.filter(function(entry) { return entry.path !== failedPath })
    remember({ key: requestKey, path: "", error: "thumbnail-unavailable", retryAt: Date.now() + 60000 })
    refresh()
  }

  function refresh() {
    if (!initialized) return
    generation += 1
    debounce.stop()
    // Cancellation never waits for a decoder or network operation before lock.
    // busy stays true until exit, preventing overlap with the replacement job.
    if (busy) worker.running = false
    path = ""
    error = ""
    if (!requestKey) { state = "empty"; return }
    var entry = cached(requestKey)
    if (entry && entry.path) {
      remember(entry)
      path = entry.path
      state = "ready"
      return
    }
    if (locked) { state = "locked-miss"; return }
    if (entry && Date.now() < entry.retryAt) {
      state = "fallback"
      error = entry.error
      return
    }
    state = "loading"
    if (!busy) {
      // Coalesce metadata bursts and cap sustained track churn to one job/2s.
      debounce.interval = Math.max(400, 2000 - (Date.now() - lastStarted))
      debounce.start()
    }
  }

  function startJob() {
    if (busy || locked || !requestKey) return
    job = { key: requestKey, generation: generation,
      request: JSON.stringify({ url: String(player.trackArtUrl || ""), hosts: hosts, roots: roots }) }
    lastStarted = Date.now()
    busy = true
    worker.stdinEnabled = true
    worker.running = true
    watchdog.start()
  }

  function acceptResult(text) {
    if (!job || job.generation !== generation || locked || job.key !== requestKey) return
    var result
    try { result = JSON.parse(text) }
    catch (parseError) { result = { ok: false, error: "invalid-helper-result" } }
    if (!result || typeof result !== "object" || Array.isArray(result))
      result = { ok: false, error: "invalid-helper-result" }
    var filename = typeof result.path === "string" ? result.path.slice(cacheDirectory.length) : ""
    if (result.ok === true && result.path === cacheDirectory + filename && /^[a-f0-9]{64}\.png$/.test(filename)) {
      remember({ key: job.key, path: result.path })
      path = result.path
      state = "ready"
      error = ""
    } else {
      // Only stable codes enter logs/status; URLs and media metadata stay private.
      var code = typeof result.error === "string" && /^[a-z-]{1,48}$/.test(result.error)
        ? result.error : "invalid-helper-result"
      remember({ key: job.key, path: "", error: code, retryAt: Date.now() + 60000 })
      state = "fallback"
      error = code
      console.warn("foamy.lock artwork: " + code)
    }
  }

  onRequestKeyChanged: refresh()
  onLockedChanged: refresh()
  Component.onCompleted: { initialized = true; refresh() }

  Timer { id: debounce; onTriggered: root.startJob() }
  Timer {
    id: watchdog
    interval: 10000
    onTriggered: {
      worker.signal(9)
      root.acceptResult('{"ok":false,"error":"helper-timeout"}')
    }
  }
  Process {
    id: worker
    command: ["/usr/bin/python3", "-I", decodeURIComponent(Qt.resolvedUrl("artwork.py").toString().replace(/^file:\/\//, ""))]
    clearEnvironment: true
    environment: ({ HOME: Quickshell.env("HOME"), XDG_CACHE_HOME: root.cacheHome,
      XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"), PATH: "/usr/bin", LANG: "C.UTF-8" })
    onStarted: {
      if (!root.job || root.job.generation !== root.generation || root.locked) { running = false; return }
      write(root.job.request + "\n")
      stdinEnabled = false
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.acceptResult(text) }
    onExited: {
      watchdog.stop()
      root.busy = false
      // Stream delivery can precede or follow exit. Defer until both have had
      // a chance to run, then recover failed starts or schedule the newest track.
      Qt.callLater(function() {
        if (root.job && root.job.generation === root.generation && root.state === "loading")
          root.acceptResult('{"ok":false,"error":"helper-exited"}')
        root.refresh()
      })
    }
  }
}
