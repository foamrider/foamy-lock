// Layout shell: one preset (__PRESET__) through sizes, clock formats, typing
// and primary/non-primary states; then, for foamy, the fallback chain on a
// screen too small for it. Written into a temporary app by the harness.
import QtQuick
import Quickshell
import "fixtures" as Fixture
import "Layout.js" as Layout
ShellRoot {
  id: shellRoot
  readonly property string presetName: "__PRESET__"
  readonly property var sizes: [[1920, 1080], [3440, 1440], [1280, 720], [800, 1000]]
  property int fellBack: 0
  property var fellBackTo: []

  FloatingWindow {
    visible: true
    implicitWidth: 3440; implicitHeight: 1440
    color: "black"
    LockView {
      id: view
      userName: "foamy"
      userDisplayName: "Foamy User"
      backgroundPath: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
      activePlayer: player
      artworkPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
      fingerprintConfigured: true
      look: Layout.preset(shellRoot.presetName)
      onPasswordTextEdited: function(value) { passwordText = value }
      onLayoutFellBack: function(error, preset) { shellRoot.fellBack++; shellRoot.fellBackTo.push(preset + ":" + error) }
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

  function findNamed(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findNamed(item.children[i], name)
      if (found) return found
    }
    return null
  }
  function fail(message) {
    console.error("LAYOUT_FAIL [" + presetName + " " + step.label + "] " + message)
    Qt.exit(1)
  }

  // Each state: [width, height, 12h, typing, primary].
  readonly property var states: {
    var out = []
    for (var i = 0; i < sizes.length; i++)
      for (var primary = 1; primary >= 0; primary--)
        out.push([sizes[i][0], sizes[i][1], i % 2 === 1, primary === 0, primary === 1])
    return out
  }

  Timer {
    id: step
    property int index: 0
    property bool applied: false
    property string label: ""
    // Above the view's 300 ms geometry debounce.
    interval: 700
    repeat: true
    running: true
    onTriggered: {
      if (index < shellRoot.states.length) {
        var state = shellRoot.states[index]
        if (!applied) {
          label = state[0] + "x" + state[1] + (state[2] ? " 12h" : "") + (state[3] ? " typing" : "") + (state[4] ? "" : " secondary")
          view.width = state[0]; view.height = state[1]
          view.timeFormat = state[2] ? "12h" : "24h"
          view.passwordText = state[3] ? "example" : ""
          view.primary = state[4]
          applied = true
          return
        }
        shellRoot.check(state)
        var capture = Qt.resolvedUrl("capture-" + shellRoot.presetName + "-" + index + ".png").toString().replace("file://", "")
        if (!view.grabToImage(function(result) { result.saveToFile(capture) })) shellRoot.fail("capture failed")
        console.log("layout ok: " + presetName + " " + label)
        applied = false
        index++
        return
      }
      if (presetName !== "foamy") { shellRoot.finish(); return }
      // The fallback chain: a customised corner look on a screen too small
      // for it falls back to foamy, which doesn't fit either, then to the
      // field-only layout, which does; nothing falls back further.
      if (!applied) {
        label = "fallback"
        view.primary = true
        view.passwordText = ""
        view.look = Layout.parseLook({ preset: "corner", layout: { media: { zone: "bottom-center" } } }).look
        view.width = 320; view.height = 240
        applied = true
        interval = 1600
        return
      }
      if (view.fallbackPreset !== "field-only") shellRoot.fail("expected field-only, got " + JSON.stringify(view.fallbackPreset))
      if (shellRoot.fellBack !== 2 || shellRoot.fellBackTo[0].indexOf("foamy:") !== 0)
        shellRoot.fail("expected corner -> foamy -> field-only, got " + JSON.stringify(shellRoot.fellBackTo))
      if (!view.layoutError) shellRoot.fail("no layoutError after a fallback")
      shellRoot.checkField(true)
      console.log("layout ok: fallback " + JSON.stringify(shellRoot.fellBackTo))
      shellRoot.finish()
    }
  }

  function finish() {
    console.log("LAYOUT_PASS: " + presetName + " " + states.length + " states" + (presetName === "foamy" ? " + fallback chain" : ""))
    Qt.quit()
  }

  function checkField(primary) {
    var field = findNamed(view, "inputField")
    var input = findNamed(view, "passwordInput")
    if (!field || !input) return fail("no password field")
    if (!field.visible || !input.enabled) return fail("the password field must stay live")
    if (!input.activeFocus) return fail("the password input lost focus")
    var margin = Math.round(4 * view.uiScale)
    if (field.x < margin || field.y < margin || field.x + field.width > view.width - margin
        || field.y + field.height > view.height - margin)
      return fail("field outside the view: " + [field.x, field.y, field.width, field.height] + " in " + view.width + "x" + view.height)
    var hint = findNamed(view, "unlockHint")
    if (primary && view.passwordText === "" && !hint.visible) return fail("primary view without the unlock hint")
  }

  function check(state) {
    if (view.fallbackPreset !== "" || view.layoutError !== "")
      return fail("a built-in preset fell back: " + view.layoutError + " -> " + view.fallbackPreset)
    checkField(state[4])
    var account = findNamed(view, "identityBlock")
    var hint = findNamed(view, "unlockHint")
    var shown = view.placed.account.hidden === false
    if (!state[4] && account.visible) return fail("the account shows on a secondary screen")
    if (state[4] && shown && !account.visible) return fail("the account is missing on the primary screen")
    if (!state[4] && !state[3] && hint.visible) return fail("field chrome shows on a secondary screen while nothing is typed")
    // Whatever else is on screen stays inside it.
    var names = ["dateLabel", "clockLabel", "identityBlock", "mediaRow", "statusFooter"]
    for (var i = 0; i < names.length; i++) {
      var item = findNamed(view, names[i])
      if (!item.visible) continue
      if (item.x < -1 || item.y < -1 || item.x + item.width > view.width + 1 || item.y + item.height > view.height + 1)
        return fail(names[i] + " outside the view: " + [item.x, item.y, item.width, item.height])
    }
  }
}
