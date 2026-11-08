// Lock Studio test driver: loaded by studio/shell.qml (FOAMY_LOCK_STUDIO_TEST=1)
// from the harness's own app root as StudioTest.qml, with the real window and
// StudioWindow handed in. Drives the canvas through its test hooks (the
// functions its pointer and key handlers call), checks the resulting look
// JSON, captures the window, measures costs and finally waits for the
// harness to raise the window over IPC. Written by tests/harness (studio).
import QtQuick
import Quickshell
import Quickshell.Io
import "Layout.js" as Layout
import "Draft.js" as Draft

Item {
  id: test

  property var window: null
  property var studio: null
  readonly property string out: Quickshell.env("FOAMY_LOCK_STUDIO_OUT") || ""
  readonly property var canvas: studio ? studio.canvas : null
  readonly property var view: canvas ? canvas.view : null
  // Right to left (an RTL Omarchy language): start and end swap on screen,
  // and offsets' x mirrors.
  readonly property bool rtl: studio ? studio.rightToLeft : false
  // On screen, towards the centre from the start column.
  readonly property int inward: rtl ? -1 : 1
  property string label: "start"
  property int at: 0
  property bool done: false
  property var saved: ({})

  function fail(message) {
    console.error("STUDIO_FAIL [" + label + "] " + message)
    runner.running = false
    Qt.exit(1)
  }
  function ok(message) { console.info("studio ok: " + message) }
  function expect(condition, message) { if (!condition) fail(message) }
  function json(value) { return JSON.stringify(value) }
  function expectDraft(expected) {
    // Key order aside (QML hands objects back sorted).
    if (!Draft.same(studio.draft, JSON.parse(expected))) fail("draft " + json(studio.draft) + ", expected " + expected)
  }
  function near(a, b, slack) { return Math.abs(a - b) <= (slack === undefined ? 1 : slack) }
  function reset() {
    canvas.cancelGesture()
    studio.history = Draft.history({ preset: "foamy" })
    studio.previewState = "idle"
    studio.shortcutsOpen = false
  }
  function anchorOf(gesture, zone) {
    for (var i = 0; i < gesture.anchors.length; i++) if (gesture.anchors[i].zone === zone) return gesture.anchors[i]
    return null
  }
  // Every text input under `item` that has the keyboard.
  function focusedInputs(item, found) {
    if (item.cursorPosition !== undefined && item.activeFocus) found.push(item)
    for (var i = 0; i < item.children.length; i++) focusedInputs(item.children[i], found)
    return found
  }
  function path(name) { return test.out + "/" + name }
  // Save the window as PNG (for people) and PPM (for the harness's pixel
  // checks), then continue.
  function capture(name, next) {
    if (!studio.grabToImage(function(result) {
      if (!result.saveToFile(path(name + ".png")) || !result.saveToFile(path(name + ".ppm"))) fail("saving " + name)
      console.info("STUDIO_CAPTURE " + name + " " + path(name + ".png"))
      next()
    })) fail("grabToImage " + name)
  }
  // The shown modules' rectangles in window pixels, for the pixel check.
  function windowRects() {
    var origin = view.mapToItem(studio, 0, 0)
    var rects = {}
    for (var name in view.elementRects) {
      var r = view.elementRects[name]
      rects[name] = { x: Math.round(origin.x + r.x * canvas.zoom), y: Math.round(origin.y + r.y * canvas.zoom),
        width: Math.round(r.width * canvas.zoom), height: Math.round(r.height * canvas.zoom) }
    }
    return rects
  }
  function rss() {
    gc()
    status.reload()
    var match = /VmRSS:\s+(\d+)/.exec(String(status.text()))
    return match ? Number(match[1]) : -1
  }
  // Mean time of `count` alternating commits of looks a and b (ms).
  function commitCost(a, b, count) {
    var started = Date.now()
    for (var i = 0; i < count; i++) studio.commit(i % 2 === 0 ? a : b)
    return (Date.now() - started) / count
  }

  FileView { id: status; path: "/proc/self/status"; printErrors: false; blockLoading: true }
  FileView { id: ipcDone; path: test.path("ipc-done"); printErrors: false; blockLoading: true }

  // Each step: a name, how long to wait before it, and its body, which
  // calls next() when it is done (captures finish asynchronously).
  readonly property var steps: [
    { name: "window and focus", wait: 1200, run: function(next) {
        expect(window.title === "Lock Studio", "title " + window.title)
        studio.Window.window.requestActivate()
        // The 1920 × 1080 reference keeps the expected numbers fixed.
        studio.monitorKey = "reference:1920x1080"
        next()
      } },
    { name: "no input has the keyboard", wait: 800, run: function(next) {
        expect(studio.monitor.width === 1920 && studio.monitor.height === 1080, "monitor " + json(studio.monitor))
        var focused = studio.Window.activeFocusItem
        ok("active window " + studio.Window.active + ", focus on " + (focused ? focused.toString() : "nothing"))
        expect(focused === null || focused.cursorPosition === undefined, "a text input has active focus: " + focused)
        var inputs = focusedInputs(studio, [])
        expect(inputs.length === 0, "inputs with active focus: " + inputs)
        expect(canvas.activeFocus, "the canvas should have the keyboard")
        expect(!view.inputEnabled && !view.enabled && !view.latchFallback, "the view takes no input and never falls back")
        // Sample data in the app's language, never the user's own.
        expect(view.userName === "sample" && view.userDisplayName !== "" && view.userDisplayName.indexOf("studio.") !== 0
          && view.activePlayer.trackTitle !== "" && view.activePlayer.trackTitle.indexOf("studio.") !== 0,
          "sample data: " + view.userDisplayName + ", " + view.activePlayer.trackTitle)
        next()
      } },
    { name: "elements drawn", wait: 0, run: function(next) {
        for (var i = 0; i < Layout.ELEMENTS.length; i++) {
          var name = Layout.ELEMENTS[i]
          var shown = name !== "calendar"
          var r = view.elementRects[name]
          expect(shown === (r !== undefined), name + " rect " + json(r))
          if (shown) expect(r.width > 4 && r.height > 4 && view.elementItem(name).visible, name + " is drawn: " + json(r))
        }
        expect(near(canvas.zoom, Math.min((canvas.width - 2) / 1920, (canvas.height - 2) / 1080), 0.001), "zoom " + canvas.zoom)
        console.info("STUDIO_RECTS " + json(windowRects()))
        capture("studio-idle", next)
      } },
    { name: "drag to another zone's anchor", wait: 0, run: function(next) {
        reset()
        expect(canvas.beginMove("media"), "beginMove media")
        var g = canvas.gesture
        var anchor = anchorOf(g, "bottom-end")
        expect(anchor !== null && g.anchors.length === 9, "anchors " + json(g.anchors))
        // 3 view px right of and 2 above the anchor: inside the 8 canvas px.
        var dx = anchor.x + anchor.width / 2 - (g.start.x + g.start.width / 2) + 3
        var dy = anchor.y - g.start.y - 2
        canvas.moveGesture(dx * canvas.zoom, dy * canvas.zoom, Qt.NoModifier)
        var result = canvas.gesture.result
        expect(result.zone === "bottom-end", "zone " + result.zone)
        expect(result.x && result.x.kind === "anchor" && result.y && result.y.kind === "anchor", "snapped " + json(result))
        test.saved.anchor = anchor
        capture("studio-dragging", next)
      } },
    { name: "drop on the anchor", wait: 0, run: function(next) {
        canvas.finishGesture()
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-end"}}}')
        expect(canvas.liveLook === null && canvas.gesture === null, "the drag is over")
        var r = view.drawnRect("media"), a = test.saved.anchor
        expect(near(r.x, a.x) && near(r.y, a.y), "media sits on the anchor: " + json(r) + " vs " + json(a))
        expect(studio.selected === "media", "selected " + studio.selected)
        next()
      } },
    { name: "undo and redo", wait: 0, run: function(next) {
        expect(studio.appKey(Qt.Key_Z, Qt.ControlModifier, ""), "Ctrl+Z")
        expectDraft('{"preset":"foamy"}')
        expect(studio.appKey(Qt.Key_Z, Qt.ControlModifier | Qt.ShiftModifier, ""), "Ctrl+Shift+Z")
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-end"}}}')
        studio.undo()
        next()
      } },
    { name: "Shift-drag skips snapping", wait: 0, run: function(next) {
        reset()
        canvas.beginMove("status")
        canvas.moveGesture(-32 * inward * canvas.zoom, 47 * canvas.zoom, Qt.ShiftModifier)
        var free = canvas.gesture.result
        expect(free.x === null && free.y === null, "no snap with Shift: " + json(free))
        expect(near(free.rect.x, canvas.gesture.start.x - 32 * inward, 0.01) && near(free.rect.y, canvas.gesture.start.y + 47, 0.01), "free rect " + json(free.rect))
        canvas.finishGesture()
        // 32 px towards the start edge on screen: a negative x either way.
        expectDraft('{"preset":"foamy","layout":{"status":{"offset":{"x":-0.016667,"y":0.043519}}}}')
        // The same move with snapping lands somewhere else.
        reset()
        canvas.beginMove("status")
        canvas.moveGesture(-32 * inward * canvas.zoom, 47 * canvas.zoom, Qt.NoModifier)
        var snapped = canvas.gesture.result
        expect(snapped.x !== null || snapped.y !== null, "the same move snaps without Shift")
        expect(!near(snapped.rect.y, free.rect.y, 0.01) || !near(snapped.rect.x, free.rect.x, 0.01), "snapped " + json(snapped.rect))
        test.saved.snapped = snapped.rect
        test.saved.free = free.rect
        next()
      } },
    { name: "Shift pressed mid-drag takes effect without moving", wait: 0, run: function(next) {
        canvas.keyPressed(Qt.Key_Shift, Qt.ShiftModifier)
        var r = canvas.gesture.result
        expect(r.x === null && r.y === null && near(r.rect.x, test.saved.free.x, 0.01) && near(r.rect.y, test.saved.free.y, 0.01),
          "Shift pressed: " + json(r))
        canvas.keyReleased(Qt.Key_Shift, Qt.NoModifier)
        r = canvas.gesture.result
        expect(near(r.rect.x, test.saved.snapped.x, 0.01) && near(r.rect.y, test.saved.snapped.y, 0.01), "Shift released: " + json(r))
        canvas.cancelGesture()
        expectDraft('{"preset":"foamy"}')
        next()
      } },
    { name: "Alt holds the axis", wait: 0, run: function(next) {
        canvas.beginMove("media")
        var start = canvas.gesture.start
        canvas.moveGesture(10 * inward * canvas.zoom, 0, Qt.AltModifier)
        canvas.moveGesture(90 * inward * canvas.zoom, -70 * canvas.zoom, Qt.AltModifier | Qt.ShiftModifier)
        var r = canvas.gesture.result.rect
        expect(r.y === start.y && near(r.x, start.x + 90 * inward, 0.01), "held to x: " + json(r))
        canvas.cancelGesture()
        next()
      } },
    { name: "the password field never reaches the top third", wait: 0, run: function(next) {
        reset()
        canvas.beginMove("password")
        var zones = canvas.gesture.anchors.map(function(a) { return a.zone })
        expect(zones.join() === Layout.PASSWORD_ZONES.join(), "password anchors " + zones)
        canvas.moveGesture(0, -900 * canvas.zoom, Qt.NoModifier)
        var r = canvas.gesture.result
        expect(r.rect.y >= 1080 / 3 && Layout.PASSWORD_ZONES.indexOf(r.zone) !== -1, "dragged up: " + json(r))
        canvas.finishGesture()
        var item = studio.look.elements.password
        expect(Layout.PASSWORD_ZONES.indexOf(item.zone) !== -1, "zone " + item.zone)
        expect(Draft.parse(studio.draft).valid, "the lock accepts it: " + json(studio.draft))
        next()
      } },
    { name: "the field's drop holds on the lock", wait: 450, run: function(next) {
        expect(view.drawnRect("password").y >= 1080 / 3, "field top " + view.drawnRect("password").y)
        var problem = view.geometryProblem()
        expect(problem !== "password-high" && problem !== "password-offscreen", "problem " + problem)
        ok("password dropped as " + json(studio.draft))
        next()
      } },
    { name: "corner handles scale", wait: 0, run: function(next) {
        reset()
        studio.selected = "clock"
        var start = view.drawnRect("clock")
        expect(canvas.beginResize({ x: 1, y: 1 }), "beginResize")
        canvas.moveGesture(start.width * 0.21 * canvas.zoom, 0, Qt.NoModifier)
        expect(canvas.gesture.scale === 1.2, "snapped scale " + canvas.gesture.scale)
        canvas.moveGesture(start.width * 0.23 * canvas.zoom, 0, Qt.ShiftModifier)
        expect(!near(canvas.gesture.scale * 20, Math.round(canvas.gesture.scale * 20), 0.001), "free scale " + canvas.gesture.scale)
        canvas.finishGesture()
        expectDraft('{"preset":"foamy","layout":{"clock":{"scale":1.25}}}')
        next()
      } },
    { name: "keyboard edits", wait: 0, run: function(next) {
        reset()
        studio.selected = "media"
        var towards = rtl ? Qt.Key_Left : Qt.Key_Right
        canvas.keyPressed(towards, Qt.NoModifier)
        var offset = studio.look.elements.media.offset
        expect(offset && near(offset.x * 1920, 22.5, 1) && offset.y === 0, "arrow: " + json(studio.draft))
        canvas.keyPressed(Qt.Key_Up, Qt.ShiftModifier)
        expect(Math.round(studio.look.elements.media.offset.y * 1080) === -1, "Shift+arrow: " + json(studio.draft))
        canvas.keyPressed(towards, Qt.ControlModifier)
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-center","order":2}}}')
        canvas.keyPressed(Qt.Key_Plus, Qt.NoModifier)
        expect(studio.look.elements.media.scale === 1.05, "+ " + json(studio.draft))
        canvas.keyPressed(Qt.Key_Delete, Qt.NoModifier)
        expect(studio.look.elements.media.hidden === true, "Delete hides")
        studio.selected = "password"
        var before = Draft.stable(studio.draft)
        canvas.keyPressed(Qt.Key_Delete, Qt.NoModifier)
        expect(Draft.stable(studio.draft) === before, "the field can't be hidden")
        canvas.keyPressed(Qt.Key_Up, Qt.ControlModifier)
        canvas.keyPressed(Qt.Key_Up, Qt.ControlModifier)
        expect(studio.look.elements.password.zone === "middle-center", "Ctrl+Up stops at the middle row: " + studio.look.elements.password.zone)
        studio.appKey(Qt.Key_BracketRight, Qt.NoModifier, "]")
        expect(studio.selected === "media", "] selects the next module: " + studio.selected)
        studio.appKey(Qt.Key_BracketLeft, Qt.NoModifier, "[")
        expect(studio.selected === "password", "[ selects the previous module")
        var undos = 0
        while (Draft.canUndo(studio.history)) { studio.appKey(Qt.Key_Z, Qt.ControlModifier, ""); undos++ }
        expect(undos === 6, "undo steps " + undos)
        expectDraft('{"preset":"foamy"}')
        next()
      } },
    { name: "preview states", wait: 0, run: function(next) {
        studio.previewState = "typing"
        expect(view.passwordText.length > 0 && view.showPassword, "typing")
        studio.previewState = "wrong"
        expect(view.errorState && view.failedAttempts === 1, "wrong password")
        capture("studio-wrong-password", next)
      } },
    { name: "no media", wait: 0, run: function(next) {
        studio.previewState = "noMedia"
        expect(view.elementRects.media === undefined && !view.hasMedia, "no media")
        studio.previewState = "idle"
        next()
      } },
    { name: "problems on every size", wait: 0, run: function(next) {
        reset()
        // The status moved onto the clock: an overlap everywhere.
        studio.commit({ preset: "foamy", layout: { status: { offset: { x: -0.4, y: 0.07 } } } })
        studio.selected = "status"
        next()
      } },
    { name: "problems reported", wait: 900, run: function(next) {
        var problems = studio.checker.problems
        expect(problems.length >= 1, "problems: " + json(problems))
        var shown = null
        for (var i = 0; i < problems.length; i++) if (problems[i].key === studio.monitor.key) shown = problems[i]
        expect(shown && shown.code === "element-overlap" && shown.names.indexOf("status") !== -1, "on the canvas: " + json(shown))
        expect(json(canvas.problemNames) === json(shown.names), "outlined " + json(canvas.problemNames))
        expect(studio.applyBlocked === problems.some(function(p) { return !p.reference }), "only a connected screen's problem blocks Apply")
        ok("checker: " + studio.checker.viewCount + " views, check " + studio.checker.lastCheckMs + " ms; " + studio.problemText(shown))
        capture("studio-problem", next)
      } },
    { name: "shortcuts", wait: 0, run: function(next) {
        reset()
        next()
      } },
    { name: "shortcuts open", wait: 450, run: function(next) {
        expect(studio.checker.problems.length === 0, "the checker cleared: " + json(studio.checker.problems))
        expect(studio.appKey(Qt.Key_Question, Qt.ShiftModifier, "?") && studio.shortcutsOpen, "? opens the shortcuts")
        capture("studio-shortcuts", next)
      } },
    { name: "shortcuts close", wait: 0, run: function(next) {
        expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && !studio.shortcutsOpen, "Esc closes them")
        next()
      } },
    { name: "F6 moves between panes", wait: 0, run: function(next) {
        studio.selected = "clock"
        canvas.forceActiveFocus()
        var order = []
        for (var i = 0; i < 4; i++) {
          studio.appKey(Qt.Key_F6, Qt.NoModifier, "")
          for (var p = 0; p < studio.panes.length; p++) if (studio.panes[p].activeFocus) order.push(p)
        }
        expect(order.join() === "2,3,0,1" && canvas.activeFocus, "panes in turn: " + order + ", back on the canvas " + canvas.activeFocus)
        studio.appKey(Qt.Key_F6, Qt.ShiftModifier, "")
        expect(studio.panes[0].activeFocus, "Shift+F6 goes back")
        var focused = studio.Window.activeFocusItem
        expect(focused && focused.cursorPosition === undefined, "never a text input: " + focused)
        canvas.forceActiveFocus()
        next()
      } },
    { name: "costs", wait: 600, run: function(next) {
        var a = { preset: "foamy" }, b = { preset: "foamy", layout: { clock: { scale: 1.1 }, media: { zone: "bottom-end" } } }
        var withChecker = commitCost(a, b, 20)
        var started = Date.now()
        for (var i = 0; i < 10; i++) canvas.measureAnchors("clock")
        var anchorsMs = (Date.now() - started) / 10
        // One pointer move of a drag: snapping, the dragged look, the relayout.
        canvas.beginMove("media")
        started = Date.now()
        for (var m = 0; m < 50; m++) canvas.moveGesture(m * 3, -m * 2, Qt.NoModifier)
        var moveMs = (Date.now() - started) / 50
        canvas.cancelGesture()
        studio.checker.active = false
        var withoutChecker = commitCost(a, b, 20)
        studio.checker.active = true
        // Memory per checker view: six more sizes, measured before and after.
        var extra = []
        for (var e = 0; e < 6; e++) extra.push({ key: "cost:" + e, label: "cost " + e, reference: true, width: 1920, height: 1080 })
        var rssBefore = rss()
        started = Date.now()
        studio.checker.sizes = studio.monitors.concat(extra)
        var createMs = (Date.now() - started) / 6
        test.saved.cost = { views: studio.monitors.length, commit: withChecker, bare: withoutChecker, anchors: anchorsMs,
          move: moveMs, create: createMs, rssBefore: rssBefore }
        next()
      } },
    { name: "cost of a checker view", wait: 900, run: function(next) {
        var c = test.saved.cost
        var perView = (rss() - c.rssBefore) / 6
        studio.checker.sizes = Qt.binding(function() { return studio.monitors })
        console.info("STUDIO_COST checkerViews=" + c.views + " commitMs=" + c.commit.toFixed(2) + " commitMsWithoutChecker=" + c.bare.toFixed(2)
          + " perCheckerViewMs=" + ((c.commit - c.bare) / c.views).toFixed(2) + " createViewMs=" + c.create.toFixed(1)
          + " perCheckerViewKiB=" + Math.round(perView) + " checkMs=" + studio.checker.lastCheckMs + " (9 views)"
          + " anchorsAtDragStartMs=" + c.anchors.toFixed(1) + " pointerMoveMs=" + c.move.toFixed(2) + " rssKiB=" + rss())
        reset()
        next()
      } },
    { name: "raise over IPC", wait: 300, run: function(next) {
        console.info("STUDIO_IPC_WAIT")
        test.saved.ipcTries = 0
        next()
      } },
    { name: "the harness raised the window", wait: 0, run: function(next) {
        ipcDone.reload()
        var text = String(ipcDone.text() || "").trim()
        if (text === "") {
          if (++test.saved.ipcTries > 100) fail("no IPC result from the harness")
          runner.interval = 200
          runner.restart()
          return
        }
        expect(text === "raised", "studio raise answered " + JSON.stringify(text))
        expect(window.visible, "the window stays shown")
        next()
      } }
  ]

  Timer {
    id: runner
    interval: 100
    running: test.studio !== null && !test.done
    onTriggered: {
      if (test.at >= test.steps.length) {
        test.done = true
        console.info("STUDIO_PASS")
        Qt.quit()
        return
      }
      var step = test.steps[test.at]
      test.label = step.name
      running = false
      try {
        step.run(function() {
          ok(step.name)
          test.at++
          var following = test.steps[test.at]
          runner.interval = following ? Math.max(1, following.wait) : 1
          runner.restart()
        })
      } catch (error) {
        test.fail(error + (error.stack ? "\n" + error.stack : ""))
      }
    }
  }
}
