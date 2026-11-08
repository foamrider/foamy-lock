// Placement shell: the free-placement keys (scale, opacity, offset, glass,
// screens) on one view, case by case: what the geometry check reports, that
// decorations keep fitting the un-offset zones, that offsets mirror and that
// `latchFallback: false` only reports; late weather and status readings
// re-run the check, and the status sources exist only while an item needs
// them. Shapes: zone shapes keep to the un-offset zones, module shapes
// follow their modules (offset, scale, late media and weather, a title
// that widens the pill, primary-only), mirror, never move the geometry
// check, and an absorbing zero-padding box is the module's own surface:
// the harness compares the two grabs (PLACEMENT_PIXELS) pixel for pixel.
// Written into a temporary app by the harness.
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
  function exact(a, b) { return Math.abs(a - b) < 1e-6 }
  // The shapes drawn, in drawing order.
  function surfaces() { return findNamed(view, "decoration").surfaces }
  // A box around one module: Lock Studio's "Wrap in a shape", padded.
  function around(name, pad, color) {
    return { kind: "box", wrap: { modules: [name] }, pad: { x: pad, y: pad }, radius: "auto",
      fill: { color: color || "surface", opacity: 1 }, absorb: true }
  }
  // The single shape drawn is `rect` grown by `pad` on every side, exactly.
  function expectAround(rect, pad, what) {
    var all = surfaces()
    if (all.length !== 1) return fail(what + ": " + all.length + " shapes drawn: " + JSON.stringify(all))
    var s = all[0]
    if (!exact(s.x, rect.x - pad) || !exact(s.y, rect.y - pad) || !exact(s.width, rect.width + 2 * pad) || !exact(s.height, rect.height + 2 * pad))
      fail(what + ": the shape " + JSON.stringify(s) + " isn't around " + JSON.stringify(rect) + " by " + pad)
  }
  // Grab the view into the app's directory, as PPM, for the harness.
  function grab(name) {
    var file = Qt.resolvedUrl(name + ".ppm").toString().replace("file://", "")
    if (!view.grabToImage(function(result) { if (!result.saveToFile(file)) fail("saving " + file) })) fail("grab " + name)
  }
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
    { name: "shapes: a zone island keeps its place, a module island follows", phases: [
      { apply: function() { view.look = look({ preset: "island" }) },
        check: function() { expectProblem(""); shellRoot.saved = JSON.stringify(surfaces()) } },
      { apply: function() { view.look = look({ preset: "island", layout: { clock: { offset: { x: 0.03, y: 0.02 } } } }) },
        check: function() {
          if (JSON.stringify(surfaces()) !== shellRoot.saved) fail("the zone island followed an offset: " + JSON.stringify(surfaces()))
        } },
      // The island as the media player's background: offset, scale and
      // the pill's own corners, wherever it goes.
      { apply: function() {
          view.look = look({ layout: { media: { zone: "top-center", style: "pill", offset: { x: 0.03, y: 0.02 }, scale: 1.5 },
            date: { hidden: true }, clock: { hidden: true } },
            background: { shapes: [around("media", 10, "black")] } })
        },
        check: function() {
          expectProblem("")
          var media = findNamed(view, "mediaRow")
          expectAround(view.drawnRect("media"), 10, "offset and scaled")
          if (!exact(view.shapeGeometry[0].radius, media.radius + 10)) fail("not concentric: " + view.shapeGeometry[0].radius + " for " + media.radius)
          if (media.color.a !== 0 || media.border.width !== 0) fail("the absorbed pill still draws its surface")
          shellRoot.saved = view.drawnRect("media")
        } },
      // Late media: no player, no shape; it comes back around it.
      { apply: function() { view.activePlayer = null },
        check: function() {
          if (surfaces().length !== 0) fail("a shape around nothing playing: " + JSON.stringify(surfaces()))
          expectProblem("")
        } },
      { apply: function() { view.activePlayer = player; player.trackTitle = "A much longer title that widens the pill" },
        check: function() {
          var now = view.drawnRect("media")
          if (!(now.width > shellRoot.saved.width)) fail("the pill didn't widen: " + now.width)
          expectAround(now, 10, "a wider title")
        } },
      { apply: function() { player.trackTitle = "Evening Light" },
        check: function() { expectAround(view.drawnRect("media"), 10, "the title back") } },
      // Primary only: not on a secondary view, and no empty pill there.
      { apply: function() {
          view.look = look({ layout: { media: { screens: "primary" } }, background: { shapes: [around("media", 4)] } })
        },
        check: function() { expectAround(view.drawnRect("media"), 4, "primary") } },
      { apply: function() { view.primary = false },
        check: function() { if (surfaces().length !== 0) fail("a shape around a primary-only module on a secondary view") } },
      { apply: function() { view.primary = true; view.look = Layout.defaults() }, check: function() {} }
    ] },
    { name: "shapes: weather arriving late, privacy and nothing shown", phases: [
      { apply: function() {
          view.weather = null
          view.look = look({ layout: { weather: { hidden: false, zone: "top-center", style: "pill" } },
            background: { shapes: [around("weather", 6), { kind: "panel", edge: "top", wrap: { modules: ["weather"] }, size: { min: { px: 40 } } }] } })
        },
        check: function() {
          var all = surfaces()
          if (all.length !== 1 || all[0].kind !== "panel" || all[0].height !== 40) fail("without weather: only the panel's minimum: " + JSON.stringify(all))
        } },
      { apply: function() { view.weather = shellRoot.sampleWeather },
        check: function() {
          var all = surfaces()
          var r = view.drawnRect("weather")
          if (all.length !== 2 || !exact(all[0].x, r.x - 6) || !exact(all[0].width, r.width + 12)) fail("the weather's box: " + JSON.stringify(all))
          if (!(all[1].height > 40)) fail("the panel didn't grow to the weather: " + JSON.stringify(all[1]))
        } },
      { apply: function() { view.weather = null; view.look = Layout.defaults() }, check: function() {} }
    ] },
    { name: "shapes: a module panel mirrors right to left", phases: [
      { apply: function() {
          view.look = look({ layout: { media: { offset: { x: 0.05, y: -0.03 } } },
            background: { shapes: [{ kind: "panel", edge: "start", wrap: { modules: ["media"] }, pad: 20, border: { color: "accent", width: 2, sides: "inner" } }] } })
        },
        check: function() {
          expectProblem("")
          var r = view.drawnRect("media")
          var s = surfaces()[0]
          if (s.x !== 0 || s.width !== Math.ceil(r.x + r.width + 20)) fail("the start panel: " + JSON.stringify(s) + " for " + JSON.stringify(r))
          shellRoot.saved = s
        } },
      { apply: function() { view.rightToLeft = true },
        check: function() {
          var s = surfaces()[0], ltr = shellRoot.saved
          if (!near(s.x, view.width - ltr.x - ltr.width) || s.width !== ltr.width || s.y !== ltr.y) fail("not mirrored: " + JSON.stringify(s))
          var line = view.shapeGeometry[0].line
          if (!line || line.x !== s.x) fail("the inner edge isn't on the inside: " + JSON.stringify(line))
        } },
      { apply: function() { view.rightToLeft = false; view.look = Layout.defaults() }, check: function() {} }
    ] },
    { name: "shapes: never part of the geometry check, never a fallback", phases: [
      { apply: function() { view.look = look({ layout: { status: { offset: { x: 0.3, y: 0 } } } }) },
        check: function() { expectProblem("element-offscreen"); shellRoot.saved = view.geometryKey } },
      { apply: function() {
          view.look = look({ layout: { status: { offset: { x: 0.3, y: 0 } } }, background: { shapes: [
            { kind: "panel", edge: "bottom", wrap: { modules: ["password", "account"] }, pad: 200, fill: { color: "black", opacity: 1 } },
            { kind: "box", wrap: { modules: ["status"] }, pad: { x: 120, y: 120 }, stretch: "across", inset: 0 },
            { kind: "frame", inset: 24, style: "glow" }, around("media", 0)] } })
        },
        check: function() {
          expectProblem("element-offscreen")
          if (view.geometryKey !== shellRoot.saved) fail("shapes changed the geometry key")
        } },
      { apply: function() {
          view.look = look({ background: { shapes: [{ kind: "panel", edge: "bottom", wrap: { zones: ["bottom-center"] }, pad: 200 },
            { kind: "box", wrap: { zones: ["middle-center", "top-center"] }, stretch: "across", pad: { x: 0, y: 120 }, fill: { frost: true } }] } })
          view.latchFallback = true
        },
        check: function() {
          if (view.fallbackPreset !== "" || shellRoot.fellBack !== 0) fail("a shape caused a fallback: " + view.layoutError)
          // The band moves the bottom row; nothing else does.
          if (!view.bottomBand) fail("a bottom panel around the bottom-center zone is a band")
          view.latchFallback = false
          view.look = Layout.defaults()
        } }
    ] },
    // The island lines up exactly: a zero-padding "surface" box that absorbs
    // the pill draws the pill's own surface. Each pair of grabs (the pill
    // alone, then absorbed) must be the same picture; the harness compares.
    { name: "shapes: absorb draws the module's own surface", phases: (function() {
        var out = []
        var tints = ["none", "accent", "solid"]
        var glasses = [undefined, 0.3]
        for (var t = 0; t < tints.length; t++) for (var g = 0; g < glasses.length; g++) (function(tint, glass, at) {
          var media = { zone: "top-center", style: "pill", offset: { x: 0.0131, y: 0.0207 }, scale: 1.35 }
          if (glass !== undefined) media.glass = glass
          var entry = { layout: { media: media, date: { hidden: true }, clock: { hidden: true } }, glass: { tint: tint } }
          out.push({ apply: function() { view.look = look(entry) },
            check: function() { expectProblem(""); grab("absorb-" + at + "-alone") } })
          out.push({ apply: function() {
              var absorbed = JSON.parse(JSON.stringify(entry))
              absorbed.background = { shapes: [around("media", 0)] }
              view.look = look(absorbed)
            },
            check: function() {
              expectAround(view.drawnRect("media"), 0, "zero padding")
              grab("absorb-" + at + "-shape")
              console.log("PLACEMENT_PIXELS absorb-" + at + "-alone.ppm absorb-" + at + "-shape.ppm " + tint + " " + glass)
            } })
        })(tints[t], glasses[g], t * glasses.length + g)
        out.push({ apply: function() { view.look = Layout.defaults() }, check: function() {} })
        return out
      })() },
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
    // The disc turns only while the player plays, with GPU rendering (the
    // offscreen renderer is software: gpuRendering is set by hand, as the
    // video suite does), motion not reduced, the display awake and the
    // element shown; stopped, it goes back upright. The other new styles
    // draw inside the screen and never turn.
    { name: "the media disc turns only while it may", phases: [
      { apply: function() { view.gpuRendering = false; view.look = look({ layout: { media: { style: "disc" } } }) },
        check: function() {
          expectProblem("")
          var media = findNamed(view, "mediaRow")
          if (media.discSpinning) fail("the disc turns under the software renderer")
          if (findNamed(media, "albumArt").rotation !== 0) fail("the disc isn't upright")
          if (!findNamed(media, "discHole").visible) fail("the disc has no centre hole")
          view.gpuRendering = true
        } },
      { apply: function() {},
        check: function() {
          var media = findNamed(view, "mediaRow")
          if (media.discSpinning !== !view.reduceMotion) fail("the disc doesn't turn while playing: " + media.discSpinning)
          player.isPlaying = false
          if (media.discSpinning) fail("the disc turns while paused")
          player.isPlaying = true
          view.displayAwake = false
          if (media.discSpinning || media.discMotion) fail("the disc turns while blanked")
          view.displayAwake = true
          view.look = look({ layout: { media: { style: "disc", hidden: true } } })
        } },
      { apply: function() {},
        check: function() {
          var media = findNamed(view, "mediaRow")
          if (media.discSpinning) fail("a hidden disc turns")
          view.look = look({ layout: { media: { style: "card" } } })
        } },
      { apply: function() {},
        check: function() {
          var media = findNamed(view, "mediaRow")
          if (media.discSpinning || findNamed(media, "albumArt").rotation !== 0) fail("the card's thumbnail is turned: " + findNamed(media, "albumArt").rotation)
          view.look = look({ layout: { media: { style: "minimal" } } })
        } },
      { apply: function() {},
        check: function() {
          expectProblem("")
          var media = findNamed(view, "mediaRow"), line = findNamed(media, "mediaMinimal")
          if (line.text !== "\u266a Evening Light \u2014 Sample Artist") fail("the minimal line: " + line.text)
          if (findNamed(media, "albumArt").visible || findNamed(media, "mediaControls").visible) fail("the minimal style shows a cover or controls")
          if (media.color.a !== 0) fail("the minimal style has a surface")
          view.look = look({ layout: { media: { style: "hero" } } })
        } },
      { apply: function() {},
        check: function() {
          expectProblem("")
          var media = findNamed(view, "mediaRow"), art = findNamed(media, "albumArt")
          if (!art.visible || art.width !== media.width || art.width < 240) fail("the hero's cover: " + art.width + " in " + media.width)
          if (findNamed(media, "mediaTitle").y < art.height || findNamed(media, "mediaArtist").y < findNamed(media, "mediaTitle").y)
            fail("the title and artist belong under the cover")
          if (findNamed(media, "mediaControls").visible) fail("the hero has no controls")
          view.gpuRendering = false
          view.look = Layout.defaults()
        } }
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
