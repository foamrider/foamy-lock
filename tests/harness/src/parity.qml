// Parity shell: the current LockView and the baseline's, side by side, driven
// through the same states and compared item by item. Written into a temporary
// app directory by the harness, which replaces __NAMES__.
import QtQuick
import Quickshell
import "fixtures" as Fixture
import "baseline" as Baseline
ShellRoot {
  id: shellRoot
  readonly property var names: __NAMES__
  readonly property string wallpaper: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
  readonly property string artwork: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
  readonly property var battery: ({ready: true, isPresent: true, isLaptopBattery: true, percentage: 0.82, state: 0})

  FloatingWindow {
    visible: true
    implicitWidth: 3440; implicitHeight: 1440
    color: "black"
    LockView {
      id: current
      onPasswordTextEdited: function(value) { passwordText = value }
      onClearFailureRequested: failureMessage = ""
    }
  }
  FloatingWindow {
    visible: true
    implicitWidth: 3440; implicitHeight: 1440
    color: "black"
    Baseline.LockView {
      id: reference
      onPasswordTextEdited: function(value) { passwordText = value }
      onClearFailureRequested: failureMessage = ""
    }
  }
  QtObject {
    id: player
    property string trackTitle: "Evening Light"
    property string trackArtist: "Sample Artist"
    property bool isPlaying: true
    property bool canGoPrevious: true
    property bool canGoNext: true
    property bool canTogglePlaying: true
    property bool canPlay: true
    property bool canPause: true
  }

  // Each state starts from the defaults, so states don't depend on order.
  function reset(v, w, h) {
    v.width = w; v.height = h
    v.userName = "foamy"; v.userDisplayName = "Foamy User"; v.avatarPath = ""
    v.backgroundPath = wallpaper; v.activePlayer = player; v.artworkPath = artwork
    v.fingerprintConfigured = true; v.fingerprintUnavailable = false
    v.showUserInfo = true; v.timeFormat = "24h"; v.rightToLeft = false
    v.failureMessage = ""; v.failedAttempts = 0; v.authenticatingPassword = false
    v.inputEnabled = true; v.passwordText = ""
  }
  readonly property var states: [
    { name: "1920x1080 default", apply: function(v) { reset(v, 1920, 1080) } },
    { name: "3440x1440 default", apply: function(v) { reset(v, 3440, 1440) } },
    { name: "2560x1080 typing", apply: function(v) { reset(v, 2560, 1080); v.passwordText = "example" } },
    { name: "800x1000 typing", apply: function(v) { reset(v, 800, 1000); v.passwordText = "example" } },
    { name: "1280x720 12h failure offline no media", apply: function(v) {
      reset(v, 1280, 720); v.timeFormat = "12h"; v.failureMessage = "Authentication failed (1)"; v.failedAttempts = 1
      v.fingerprintConfigured = false; v.activePlayer = null; Fixture.Networking.connectivity = Fixture.Networking.None } },
    { name: "1280x720 checking hidden identity no battery", apply: function(v) {
      reset(v, 1280, 720); v.showUserInfo = false; v.authenticatingPassword = true; v.passwordText = "example"
      Fixture.Power.displayDevice = null } },
    { name: "1920x1080 fingerprint unavailable no artwork", apply: function(v) {
      reset(v, 1920, 1080); v.fingerprintUnavailable = true; v.artworkPath = "" } },
    { name: "700x1200 portrait no wallpaper", apply: function(v) { reset(v, 700, 1200); v.backgroundPath = "" } },
    { name: "1920x1080 right-to-left typing", apply: function(v) { reset(v, 1920, 1080); v.rightToLeft = true; v.passwordText = "example" } }
  ]

  function findNamed(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findNamed(item.children[i], name)
      if (found) return found
    }
    return null
  }
  function snapshot(view) {
    var out = {}
    for (var i = 0; i < names.length; i++) {
      var item = findNamed(view, names[i])
      if (!item) { out[names[i]] = null; continue }
      var at = item.mapToItem(view, 0, 0)
      out[names[i]] = { x: at.x, y: at.y, w: item.width, h: item.height, visible: item.visible,
        opacity: item.opacity,
        text: item.echoMode === undefined && item.text !== undefined ? String(item.text) : null,
        px: item.font !== undefined ? item.font.pixelSize : null }
    }
    return out
  }
  function differences(a, b) {
    var found = []
    for (var name in b) {
      if (!a[name] || !b[name]) { if (a[name] !== b[name]) found.push(name + ": present " + !!a[name] + " vs " + !!b[name]); continue }
      for (var key in b[name]) {
        var x = a[name][key], y = b[name][key]
        var same = typeof y === "number" ? Math.abs(x - y) <= 1 : x === y
        if (!same) found.push(name + "." + key + ": " + x + " vs " + y)
      }
    }
    return found
  }

  Timer {
    property int index: 0
    property bool applied: false
    interval: 600
    repeat: true
    running: true
    onTriggered: {
      if (index >= shellRoot.states.length) {
        console.log("PARITY_PASS: " + shellRoot.states.length + " states, " + shellRoot.names.length + " items each")
        Qt.quit()
        return
      }
      var state = shellRoot.states[index]
      if (!applied) {
        Fixture.Networking.connectivity = Fixture.Networking.Full
        Fixture.Power.displayDevice = shellRoot.battery
        state.apply(current)
        state.apply(reference)
        applied = true
        return
      }
      var diff = shellRoot.differences(shellRoot.snapshot(current), shellRoot.snapshot(reference))
      if (diff.length > 0) {
        console.error("PARITY_FAIL [" + state.name + "] current vs baseline:\n  " + diff.join("\n  "))
        Qt.exit(1)
        return
      }
      console.log("parity ok: " + state.name)
      applied = false
      index++
    }
  }
}
