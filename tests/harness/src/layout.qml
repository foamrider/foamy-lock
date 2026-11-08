// Layout shell: one preset (__PRESET__) through sizes, clock formats, typing
// and primary/non-primary states, then right-to-left (everything, the
// decorations included, must mirror); then, for foamy, every preset on one
// view and back, and the fallback chain on a screen too small for it.
// Written into a temporary app by the harness.
import QtQuick
import Quickshell
import "fixtures" as Fixture
import "Layout.js" as Layout
ShellRoot {
  id: shellRoot
  readonly property string presetName: "__PRESET__"
  readonly property var sizes: [[1920, 1080], [3440, 1440], [1280, 720], [1080, 1920], [800, 1000]]
  property int fellBack: 0
  property var fellBackTo: []
  // foamy only: one view switched through every preset (hidden account
  // included), forwards and backwards, must end where it started.
  readonly property var cycle: {
    var forward = Layout.SELECTABLE_PRESETS.slice(1)
    return forward.concat(["foamy"], forward.slice().reverse(), ["foamy"])
  }
  // State 0 (1920×1080, primary, idle), the mirror state's reference.
  property var leftToRight: null
  property int cycleAt: -1
  property var reference: null
  readonly property var tracked: ["dateLabel", "clockLabel", "identityBlock", "avatar", "nameLabel", "inputField", "fingerprintNotice", "mediaRow", "statusFooter", "calendarBlock", "weatherBlock"]
  readonly property var elementNames: ["dateLabel", "clockLabel", "identityBlock", "inputField", "mediaRow", "statusFooter", "calendarBlock",
    "weatherBlock"]
  readonly property var modelNames: ({ dateLabel: "date", clockLabel: "clock", identityBlock: "account", inputField: "password",
    mediaRow: "media", statusFooter: "status", calendarBlock: "calendar", weatherBlock: "weather" })

  function geometry() {
    var out = {}
    for (var i = 0; i < tracked.length; i++) {
      var item = findNamed(view, tracked[i])
      var at = item.mapToItem(view, 0, 0)
      out[tracked[i]] = [Math.round(at.x), Math.round(at.y), Math.round(item.width), Math.round(item.height), item.visible].join(",")
    }
    return out
  }

  function checkAccountShape(label) {
    var account = findNamed(view, "identityBlock")
    var avatar = findNamed(view, "avatar")
    var name = findNamed(view, "nameLabel")
    if (Math.abs(avatar.width - avatar.height) > 1) return fail(label + ": avatar " + avatar.width + "x" + avatar.height)
    var parts = [avatar, name]
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i]
      if (!p.visible) continue
      if (p.x < -1 || p.y < -1 || p.x + p.width > account.width + 1 || p.y + p.height > account.height + 1)
        return fail(label + ": " + p.objectName + " outside the account box: " + [p.x, p.y, p.width, p.height] + " in " + [account.width, account.height])
    }
  }

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
      // Start on foamy and switch at the first state, as previewPreset does.
      look: Layout.defaults()
      // The widest weather, for any preset that would show it (none does).
      weather: ({ temperature: -12, unit: "C", code: "heavyrainandthunder", high: -3, low: -18,
        condition: "Heavy rain and thunder with strong gusts along the coast tonight",
        location: "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Ynys Môn, Cymru", updatedAtMs: 1 })
      avatarPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
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

  // Each state: [width, height, 12h, typing, primary, right-to-left].
  readonly property var states: {
    var out = []
    for (var i = 0; i < sizes.length; i++)
      for (var primary = 1; primary >= 0; primary--)
        out.push([sizes[i][0], sizes[i][1], i % 2 === 1, primary === 0, primary === 1, false])
    out.push([1920, 1080, false, false, true, true])
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
            + (state[5] ? " right-to-left" : "")
          view.rightToLeft = state[5]
          view.width = state[0]; view.height = state[1]
          view.timeFormat = state[2] ? "12h" : "24h"
          view.passwordText = state[3] ? "example" : ""
          view.primary = state[4]
          if (index === 0) view.look = Layout.preset(shellRoot.presetName)
          applied = true
          return
        }
        shellRoot.check(state)
        if (index === 0) shellRoot.leftToRight = shellRoot.layoutRects()
        if (state[5]) shellRoot.checkMirror(shellRoot.leftToRight)
        var capture = Qt.resolvedUrl("capture-" + shellRoot.presetName + "-" + index + ".png").toString().replace("file://", "")
        if (!view.grabToImage(function(result) { result.saveToFile(capture) })) shellRoot.fail("capture failed")
        console.log("layout ok: " + presetName + " " + label)
        applied = false
        index++
        return
      }
      if (presetName !== "foamy") { shellRoot.finish(); return }
      if (shellRoot.cycleAt < shellRoot.cycle.length) {
        if (shellRoot.cycleAt === -1) {
          view.width = 1920; view.height = 1080
          view.timeFormat = "24h"; view.passwordText = ""; view.primary = true; view.rightToLeft = false
          view.look = Layout.defaults()
          shellRoot.cycleAt = 0
          return
        }
        if (shellRoot.reference === null) shellRoot.reference = shellRoot.geometry()
        if (applied) {
          var name = shellRoot.cycle[shellRoot.cycleAt]
          label = "cycle " + shellRoot.cycleAt + " " + name
          shellRoot.checkAccountShape(label)
          if (view.fallbackPreset !== "") shellRoot.fail("fell back: " + view.layoutError)
          shellRoot.checkBackground()
          if (shellRoot.cycleAt === shellRoot.cycle.length - 1) {
            var now = shellRoot.geometry()
            for (var key in now)
              if (now[key] !== shellRoot.reference[key]) shellRoot.fail("after the cycle " + key + " is " + now[key] + ", was " + shellRoot.reference[key])
            console.log("layout ok: preset cycle back to foamy")
          }
          applied = false
          shellRoot.cycleAt++
          return
        }
        view.look = Layout.preset(shellRoot.cycle[shellRoot.cycleAt])
        applied = true
        return
      }
      // The fallback chain: a customised corner look on a screen too small
      // for it falls back to foamy, which doesn't fit either, then to the
      // field-only layout, which does; nothing falls back further.
      if (!applied) {
        label = "fallback"
        view.primary = true
        view.passwordText = ""
        view.rightToLeft = false
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

  // Visible elements and decoration surfaces, in view coordinates.
  function layoutRects() {
    var out = { elements: {}, surfaces: findNamed(view, "decoration").surfaces }
    for (var i = 0; i < elementNames.length; i++) {
      var item = findNamed(view, elementNames[i])
      if (item.visible) out.elements[elementNames[i]] = [item.x, item.y, item.width, item.height]
    }
    return out
  }

  // Right-to-left: every element and decoration surface sits where its
  // left-to-right twin is, mirrored (within a pixel).
  function checkMirror(ltr) {
    var rtl = layoutRects()
    function near(a, b) { return Math.abs(a - b) <= 1 }
    for (var name in ltr.elements) {
      var l = ltr.elements[name], r = rtl.elements[name]
      if (!r) return fail(name + " vanished in right-to-left")
      if (!near(r[0], view.width - l[0] - l[2]) || !near(r[1], l[1]) || !near(r[2], l[2]) || !near(r[3], l[3]))
        return fail(name + " doesn't mirror: " + r + " for " + l)
    }
    if (rtl.surfaces.length !== ltr.surfaces.length) return fail("decoration surfaces differ in right-to-left")
    for (var i = 0; i < ltr.surfaces.length; i++) {
      var a = ltr.surfaces[i], b = rtl.surfaces[i]
      if (!near(b.x, view.width - a.x - a.width) || !near(b.y, a.y) || !near(b.width, a.width) || !near(b.height, a.height))
        return fail("decoration surface " + i + " doesn't mirror: " + JSON.stringify(b) + " for " + JSON.stringify(a))
    }
  }

  function contains(outer, inner) {
    return inner.x >= outer.x - 1 && inner.y >= outer.y - 1 && inner.x + inner.width <= outer.x + outer.width + 1
      && inner.y + inner.height <= outer.y + outer.height + 1
  }

  // Decorations are background: on screen, and each shown element (the
  // field above all) wholly inside or wholly outside each surface, and
  // inside a frame. A drawn background holds its still frame here (software
  // renderer) and the system panel has its readings.
  function checkBackground() {
    var decoration = findNamed(view, "decoration")
    var decor = view.effectiveLook.background.decor
    if (decoration.visible !== (decor !== "none")) return fail("decoration " + decor + " visible: " + decoration.visible)
    var surfaces = decoration.surfaces
    if (decor !== "none" && surfaces.length === 0) return fail("decoration " + decor + " draws nothing")
    for (var s = 0; s < surfaces.length; s++) {
      var surface = surfaces[s]
      if (!(surface.width > 0 && surface.height > 0) || surface.x < -1 || surface.y < -1
          || surface.x + surface.width > view.width + 1 || surface.y + surface.height > view.height + 1)
        return fail(decor + " surface outside the view: " + JSON.stringify(surface))
      for (var i = 0; i < elementNames.length; i++) {
        var item = findNamed(view, elementNames[i])
        if (!item.visible) continue
        // Decorations fit the zones, so an offset element may cross them.
        if (Layout.isOffset(view.placed[modelNames[elementNames[i]]])) continue
        // What draws: centred text is narrower than its full-width item.
        var r = view.drawnRect(modelNames[elementNames[i]])
        var inside = contains(surface, r)
        if (surface.frame ? !inside : (!inside && Layout.intersects(surface, r, 1)))
          return fail(elementNames[i] + " " + JSON.stringify(r) + " straddles the " + decor + " surface " + JSON.stringify(surface))
      }
    }
    var backdrop = findNamed(view, "backdrop")
    var drawn = Layout.DRAWN_SOURCES.indexOf(view.effectiveLook.background.source) !== -1
    if (backdrop.visible !== drawn) return fail("backdrop visible: " + backdrop.visible + " for " + view.effectiveLook.background.source)
    if (drawn && (backdrop.moving || backdrop.phase !== backdrop.stillPhase))
      return fail("the drawn background moves under the software renderer: " + [backdrop.moving, backdrop.phase, backdrop.stillPhase, backdrop.source])
    if (view.placed.status.style === "system" && findNamed(view, "statusFooter").visible
        && !(view.systemUptime > 0 && view.memoryTotal > 0 && view.systemLoad !== ""))
      return fail("the system panel has no readings: " + [view.systemUptime, view.memoryTotal, view.systemLoad])
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
    // No geometry problem at all (the field, every element on screen, no
    // overlap between zones), whether or not it would fall back.
    var problem = view.geometryProblem()
    if (problem !== "" || view.geometryProblemCode !== "") return fail("geometry problem: " + problem + " " + view.geometryProblemCode)
    checkField(state[4])
    var account = findNamed(view, "identityBlock")
    var avatar = findNamed(view, "avatar")
    if (account.visible && Math.abs(avatar.width - avatar.height) > 1)
      return fail("the avatar isn't round: " + avatar.width + "x" + avatar.height)
    var hint = findNamed(view, "unlockHint")
    var shown = view.placed.account.hidden === false
    if (!state[4] && account.visible) return fail("the account shows on a secondary screen")
    if (state[4] && shown && !account.visible) return fail("the account is missing on the primary screen")
    if (!state[4] && !state[3] && hint.visible) return fail("field chrome shows on a secondary screen while nothing is typed")
    checkBackground()
    // Whatever else is on screen stays inside it.
    var names = ["dateLabel", "clockLabel", "identityBlock", "mediaRow", "statusFooter", "calendarBlock", "weatherBlock"]
    if (findNamed(view, "weatherBlock").visible) return fail("a built-in preset shows the weather")
    for (var i = 0; i < names.length; i++) {
      var item = findNamed(view, names[i])
      if (!item.visible) continue
      if (item.x < -1 || item.y < -1 || item.x + item.width > view.width + 1 || item.y + item.height > view.height + 1)
        return fail(names[i] + " outside the view: " + [item.x, item.y, item.width, item.height])
    }
  }
}
