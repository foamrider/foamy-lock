// Placement shell: the free-placement keys (scale, opacity, offset, glass,
// screens) on one view, case by case: what the geometry check reports, that
// decorations keep fitting the un-offset zones, that offsets mirror and that
// `latchFallback: false` only reports; late weather and status readings
// re-run the check, and the status sources exist only while an item needs
// them. Written into a temporary app by the harness.
import QtQuick
import Quickshell
import "fixtures" as Fixture
import "Layout.js" as Layout
ShellRoot {
  id: shellRoot
  property int fellBack: 0
  property string label: ""
  property int caseAt: 0
  property int phase: 0
  // One case's saved values between its phases.
  property var saved: null
  readonly property var elementNames: ({ date: "dateLabel", clock: "clockLabel", account: "identityBlock",
    password: "inputField", media: "mediaRow", status: "statusFooter", calendar: "calendarBlock", weather: "weatherBlock" })
  readonly property var sampleWeather: ({ temperature: 6, unit: "C", code: "lightrain", condition: "Light rain", high: 10, low: 2,
    location: "Bergen", updatedAtMs: 1 })
  function sources() {
    return [Fixture.Sources.volumeSources, Fixture.Sources.bluetoothSources, Fixture.Sources.keyboardSources].join(",")
  }

  FloatingWindow {
    visible: true
    implicitWidth: 1920; implicitHeight: 1080
    color: "black"
    LockView {
      id: view
      width: 1920; height: 1080
      userName: "foamy"
      userDisplayName: "Foamy User"
      backgroundPath: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
      activePlayer: player
      artworkPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
      fingerprintConfigured: true
      avatarPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
      latchFallback: false
      onPasswordTextEdited: function(value) { passwordText = value }
      onLayoutFellBack: shellRoot.fellBack++
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
    console.error("PLACEMENT_FAIL [" + label + "] " + message)
    step.running = false
    Qt.exit(1)
  }
  function look(entry) {
    var parsed = Layout.parseLook(entry)
    if (!parsed.valid) fail("invalid look " + JSON.stringify(entry) + ": " + parsed.error)
    return parsed.look
  }
  function near(a, b) { return Math.abs(a - b) <= 1 }
  function sameRect(a, b) { return near(a.x, b.x) && near(a.y, b.y) && near(a.width, b.width) && near(a.height, b.height) }
  function expectProblem(code) {
    var problem = view.geometryProblem()
    if (problem !== code) fail("expected " + JSON.stringify(code) + ", got " + JSON.stringify(problem))
    if (view.geometryProblemCode !== code) fail("geometryProblemCode is " + JSON.stringify(view.geometryProblemCode))
    if (view.fallbackPreset !== "" || shellRoot.fellBack !== 0) fail("fell back while only reporting: " + view.fallbackPreset)
  }

  // Each case: a name, the view's state, and one or more phases. A phase
  // sets the view up (`apply`), and the next tick (after the 300 ms
  // debounce) checks it (`check`).
  readonly property var cases: [
    { name: "every key accepted at its default draws nothing new", phases: [
      { apply: function() { view.look = Layout.defaults() },
        check: function() { expectProblem(""); shellRoot.saved = JSON.stringify(view.elementRects) } },
      { apply: function() { view.look = look({ layout: { clock: { scale: 1, opacity: 1, offset: { x: 0, y: 0 }, screens: "all" } } }) },
        check: function() {
          expectProblem("")
          if (JSON.stringify(view.elementRects) !== shellRoot.saved) fail("defaults moved something: " + JSON.stringify(view.elementRects))
        } }
    ] },
    { name: "element rectangles for an overlay", phases: [
      { apply: function() { view.look = Layout.defaults() },
        check: function() {
          var rects = view.elementRects
          for (var name in elementNames) {
            var shown = view.elementShown(name)
            if (shown !== (rects[name] !== undefined)) fail(name + " shown " + shown + " but rect " + JSON.stringify(rects[name]))
            if (shown && !sameRect(rects[name], view.drawnRect(name))) fail(name + " rect " + JSON.stringify(rects[name]))
          }
        } }
    ] },
    { name: "scale, opacity and glass reach the element", phases: [
      { apply: function() {
          view.look = look({ layout: { clock: { scale: 1.5, opacity: 0.5 }, password: { scale: 1.2, glass: 0.5, style: "box" },
            media: { glass: 0.3 }, status: { opacity: 0.4 } } })
        },
        check: function() {
          expectProblem("")
          var clock = findNamed(view, "clockLabel"), field = findNamed(view, "inputField")
          var media = findNamed(view, "mediaRow"), status = findNamed(view, "statusFooter")
          if (!near(clock.uiScale, view.uiScale * 1.5) || clock.opacity !== 0.5) fail("clock scale/opacity " + [clock.uiScale, clock.opacity])
          // The centre column grows with the element (up to the screen).
          if (!near(clock.width, Math.min(Math.round(560 * view.uiScale * 1.5), view.width - Math.round(64 * view.uiScale))))
            fail("the clock's column didn't grow: " + clock.width)
          if (field.height !== Math.round(56 * view.uiScale * 1.2)) fail("field height " + field.height)
          if (status.opacity !== 0.4) fail("status opacity " + status.opacity)
          if (!near(media.color.a * 1000, view.glassAt(0.3).a * 1000) || !(media.color.a < view.glass.a))
            fail("media glass " + media.color.a + " vs " + view.glass.a)
          if (!near(field.color.a * 1000, view.glassAt(0.5).a * 1000)) fail("field glass " + field.color.a)
        } }
    ] },
    { name: "a centred scaled element stops at the screen's margins", phases: [
      { apply: function() { view.width = 1080; view.height = 1920; view.look = look({ layout: { date: { scale: 2 } } }) },
        check: function() {
          var date = findNamed(view, "dateLabel")
          if (date.width !== view.width - Math.round(64 * view.uiScale)) fail("date width " + date.width)
        } }
    ] },
    { name: "an offset off-screen", phases: [
      { apply: function() { view.width = 1920; view.height = 1080; view.look = look({ layout: { status: { offset: { x: 0.3, y: 0 } } } }) },
        check: function() { expectProblem("element-offscreen") } }
    ] },
    { name: "an offset onto another zone's element", phases: [
      { apply: function() { view.look = look({ layout: { status: { offset: { x: -0.4, y: 0.07 } } } }) },
        check: function() { expectProblem("element-overlap") } }
    ] },
    { name: "an offset element against its own stack", phases: [
      // The clock pulls up into the date by design; moved, that is an overlap.
      { apply: function() { view.look = look({ layout: { clock: { offset: { x: 0, y: 0.01 } } } }) },
        check: function() { expectProblem("element-overlap") } }
    ] },
    { name: "an offset onto the field", phases: [
      { apply: function() { view.look = look({ layout: { media: { offset: { x: 0.3, y: -0.1 } } } }) },
        check: function() { expectProblem("password-overlap") } }
    ] },
    { name: "the field moved up stays below the top third", phases: [
      { apply: function() { view.look = look({ layout: { password: { offset: { x: 0, y: -0.2 } } } }) },
        check: function() {
          expectProblem("")
          if (!(findNamed(view, "inputField").y >= view.height / 3)) fail("field at " + findNamed(view, "inputField").y)
        } },
      { apply: function() { view.look = look({ layout: { password: { offset: { x: 0, y: -0.5 } } } }) },
        check: function() { expectProblem("password-high") } }
    ] },
    { name: "a scale that overflows", phases: [
      { apply: function() { view.width = 1280; view.height = 720; view.look = look({ layout: { clock: { style: "poster", scale: 2 } } }) },
        check: function() { expectProblem("password-overlap") } },
      { apply: function() {
          view.width = 1920; view.height = 600
          view.look = look({ preset: "zen", layout: { clock: { hidden: false, zone: "middle-start", style: "poster", scale: 2 } } })
        },
        check: function() { expectProblem("element-offscreen") } }
    ] },
    { name: "an offset mirrors in right-to-left", phases: [
      { apply: function() { view.width = 1920; view.height = 1080; view.look = look({ layout: { media: { offset: { x: 0.1, y: -0.05 } } } }) },
        check: function() {
          expectProblem("")
          var media = findNamed(view, "mediaRow")
          shellRoot.saved = { x: media.x, y: media.y, width: media.width }
          if (!near(media.x, Math.round(32 * view.uiScale) + 192)) fail("offset x " + media.x)
        } },
      { apply: function() { view.rightToLeft = true },
        check: function() {
          expectProblem("")
          var media = findNamed(view, "mediaRow"), ltr = shellRoot.saved
          if (!near(media.x, view.width - ltr.x - ltr.width) || !near(media.y, ltr.y)) fail("not mirrored: " + [media.x, media.y] + " for " + [ltr.x, ltr.y])
        } },
      { apply: function() { view.rightToLeft = false }, check: function() {} }
    ] },
    { name: "a primary-only element on a secondary view", phases: [
      { apply: function() { view.look = look({ layout: { clock: { screens: "primary" } } }) },
        check: function() {
          if (!findNamed(view, "clockLabel").visible || !findNamed(view, "dateLabel").visible) fail("primary view lost the clock or date")
        } },
      { apply: function() { view.primary = false },
        check: function() {
          expectProblem("")
          if (findNamed(view, "clockLabel").visible) fail("the clock shows on a secondary view")
          if (!findNamed(view, "dateLabel").visible) fail("the date vanished on a secondary view")
          if (view.elementRects.clock !== undefined) fail("a hidden clock has a rectangle")
          var input = findNamed(view, "passwordInput")
          if (!input.enabled || !input.activeFocus) fail("the secondary view's input isn't live")
        } },
      { apply: function() { view.primary = true }, check: function() {} }
    ] },
    { name: "decorations ignore offsets", phases: [
      { apply: function() { view.look = look({ preset: "sheet" }) },
        check: function() { expectProblem(""); shellRoot.saved = JSON.stringify(findNamed(view, "decoration").surfaces) } },
      { apply: function() { view.look = look({ preset: "sheet", layout: { clock: { offset: { x: -0.1, y: 0.02 } } } }) },
        check: function() {
          var surfaces = JSON.stringify(findNamed(view, "decoration").surfaces)
          if (surfaces !== shellRoot.saved) fail("the sheet followed the offset: " + surfaces + ", was " + shellRoot.saved)
          var clock = findNamed(view, "clockLabel")
          if (!near(view.drawnRect("clock").x - view.reservedRect("clock").x, -192)) fail("clock not offset: " + clock.x)
        } }
    ] },
    { name: "weather arriving late re-runs the check", phases: [
      { apply: function() {
          view.weather = null
          view.look = look({ layout: { weather: { hidden: false, zone: "middle-center", offset: { x: 0, y: 0.2 } } } })
        },
        check: function() {
          expectProblem("")
          if (findNamed(view, "weatherBlock").visible || view.elementRects.weather !== undefined) fail("weather shows without data")
        } },
      { apply: function() { view.weather = shellRoot.sampleWeather },
        check: function() {
          expectProblem("element-overlap")
          if (!findNamed(view, "weatherBlock").visible) fail("the weather didn't show")
        } },
      { apply: function() { view.weather = null }, check: function() { expectProblem("") } }
    ] },
    { name: "weather glass, details and place", phases: [
      { apply: function() {
          view.weather = shellRoot.sampleWeather
          view.look = look({ layout: { weather: { hidden: false, style: "pill", glass: 0.3, screens: "primary" } } })
        },
        check: function() {
          expectProblem("")
          var surface = findNamed(view, "weatherSurface")
          if (!surface.visible || !near(surface.color.a * 1000, view.glassAt(0.3).a * 1000)) fail("weather glass " + surface.color.a)
          if (findNamed(view, "weatherBlock").width >= 200) fail("the temperature alone is wide: " + findNamed(view, "weatherBlock").width)
          shellRoot.saved = findNamed(view, "weatherBlock").width
        } },
      { apply: function() { view.look = look({ layout: { weather: { hidden: false, style: "pill", details: "full", location: true } } }) },
        check: function() {
          expectProblem("")
          if (!(findNamed(view, "weatherBlock").width > shellRoot.saved)) fail("the details didn't widen the pill")
        } },
      { apply: function() { view.primary = false },
        check: function() { if (!findNamed(view, "weatherBlock").visible) fail("weather left a secondary view") } },
      { apply: function() {
          view.primary = true
          view.look = look({ layout: { weather: { hidden: false, screens: "primary" } } })
        }, check: function() {} },
      { apply: function() { view.primary = false },
        check: function() { if (findNamed(view, "weatherBlock").visible) fail("a primary-only weather on a secondary view") } },
      { apply: function() { view.primary = true; view.weather = null; view.look = Layout.defaults() }, check: function() {} }
    ] },
    { name: "status sources only while an item needs them", phases: [
      { apply: function() { view.look = Layout.defaults() },
        check: function() {
          if (sources() !== "0,0,0" || view.systemShown) fail("sources without items: " + sources() + " " + view.systemShown)
        } },
      { apply: function() { view.look = look({ layout: { status: { items: ["volume", "bluetooth", "keyboard", "network"] } } }) },
        check: function() {
          expectProblem("")
          if (sources() !== "1,1,1" || view.systemShown) fail("sources for three items: " + sources() + " " + view.systemShown)
          for (var name of ["volume", "bluetooth", "keyboard", "network"])
            if (!findNamed(view, name + "Status").visible) fail(name + " doesn't show")
          if (findNamed(view, "batteryStatus")) fail("an item not named is made")
          if (view.volumePercent !== 64 || view.keyboardLayout === "") fail("readings " + [view.volumePercent, view.keyboardLayout])
        } },
      { apply: function() { view.look = look({ layout: { status: { items: ["uptime"], style: "system" } } }) },
        check: function() {
          if (sources() !== "0,0,0") fail("sources after the items went: " + sources())
          if (!view.uptimeWanted || view.loadWanted || view.memoryWanted) fail("/proc reads " + [view.uptimeWanted, view.loadWanted, view.memoryWanted])
        } },
      { apply: function() { view.look = look({ layout: { status: { items: ["volume"], hidden: true } } }) },
        check: function() { if (sources() !== "0,0,0") fail("sources for a hidden status: " + sources()) } },
      { apply: function() { view.look = look({ layout: { status: { items: ["volume"] } } }); Fixture.Sources.volumeAvailable = false },
        check: function() {
          expectProblem("")
          if (findNamed(view, "statusFooter").visible || view.elementRects.status !== undefined) fail("an empty status shows")
        } },
      { apply: function() { view.look = look({ layout: { status: { items: ["volume", "network"] } } }) },
        check: function() {
          if (findNamed(view, "volumeStatus").visible || !findNamed(view, "networkStatus").visible) fail("an unavailable item shows")
          Fixture.Sources.volumeAvailable = true
        } },
      // A host's samples (Lock Studio): no source of the view's own.
      { apply: function() {
          view.liveSources = false
          view.hasVolume = true
          view.volumePercent = 30
          view.volumeMuted = true
        },
        check: function() {
          if (sources() !== "0,0,0") fail("sources with liveSources false: " + sources())
          if (!findNamed(view, "volumeStatus").visible) fail("the sample volume doesn't show")
        } },
      { apply: function() { view.liveSources = true; view.look = Layout.defaults() }, check: function() {} }
    ] },
    { name: "latchFallback false reports, true falls back", phases: [
      { apply: function() { view.look = look({ layout: { status: { offset: { x: 0.3, y: 0 } } } }) },
        check: function() {
          expectProblem("element-offscreen")
          if (view.layoutError !== "") fail("layoutError set while only reporting: " + view.layoutError)
        } },
      { apply: function() { view.latchFallback = true; view.checkGeometry() },
        check: function() {
          if (view.fallbackPreset !== "foamy" || view.layoutError !== "element-offscreen" || shellRoot.fellBack !== 1)
            fail("expected the foamy fallback: " + [view.fallbackPreset, view.layoutError, shellRoot.fellBack])
          if (view.geometryProblem() !== "") fail("foamy has a problem: " + view.geometryProblem())
          shellRoot.fellBack = 0
          view.latchFallback = false
          view.look = Layout.defaults()
        } }
    ] }
  ]

  Timer {
    id: step
    // Above the view's 300 ms geometry debounce.
    interval: 450
    repeat: true
    running: true
    property bool applied: false
    onTriggered: {
      if (shellRoot.caseAt >= shellRoot.cases.length) {
        console.log("PLACEMENT_PASS: " + shellRoot.cases.length + " cases")
        running = false
        Qt.quit()
        return
      }
      var item = shellRoot.cases[shellRoot.caseAt]
      var phase = item.phases[shellRoot.phase]
      shellRoot.label = item.name + " #" + shellRoot.phase
      if (!applied) {
        phase.apply()
        applied = true
        return
      }
      phase.check()
      applied = false
      if (!running) return
      if (++shellRoot.phase === item.phases.length) {
        console.log("placement ok: " + item.name)
        shellRoot.phase = 0
        shellRoot.caseAt++
      }
    }
  }
}
