// Lock Studio test driver: loaded by studio/shell.qml (FOAMY_LOCK_STUDIO_TEST=1)
// from the harness's own app root as StudioTest.qml, with the real window and
// StudioWindow handed in. Drives the canvas through its test hooks (the
// functions its pointer and key handlers call), checks the resulting look
// JSON, captures the window, measures costs and finally waits for the
// harness to raise the window over IPC. Written by tests/harness (studio).
import QtQuick
import Quickshell
import Quickshell.Io
import "kit"
import "Layout.js" as Layout
import "Draft.js" as Draft

Item {
  id: test

  property var window: null
  property var studio: null
  readonly property string out: Quickshell.env("FOAMY_LOCK_STUDIO_OUT") || ""
  // A picture to "choose" (the harness wrote it; the chooser never runs).
  readonly property string picture: Quickshell.env("FOAMY_LOCK_STUDIO_PICTURE") || ""
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
    // Saving: the lock's look is the default again; nothing asked or ending.
    studio.session = "ready"
    studio.restoreReport = null
    studio.savedDraft = { preset: "foamy" }
    studio.quitAsked = false
    studio.quitAfterApply = false
    studio.quitting = false
    studio.quitDone = false
    studio.history = Draft.history({ preset: "foamy" })
    studio.notice = null
    studio.previewDraft = null
    studio.previewState = "idle"
    studio.shortcutsOpen = false
    studio.page = "module"
    studio.pendingPreset = ""
    studio.libraryDrag = ""
    studio.presetMenu.close()
  }
  // The first item under `item` with this objectName, or null.
  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = find(children[i], name)
      if (found) return found
    }
    return null
  }
  // A point in `item`, or in the lock view (its pixels), in window pixels.
  function scenePoint(item, x, y) { return item.mapToItem(null, x, y) }
  function viewToScene(x, y) { return view.mapToItem(null, x, y) }
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

  // --- saving: the fake omarchy-shell, the draft file, waiting ---------------
  // The harness's stand-in for omarchy-shell is first on PATH; its answer is
  // the mode written here, and it records every call (count, call-<n>).
  readonly property string fake: Quickshell.env("FOAMY_LOCK_STUDIO_FAKE") || ""
  readonly property string draftPath: Quickshell.env("XDG_STATE_HOME") + "/foamy-lock/studio-draft.json"
  property int caughtQuits: 0
  // shell.qml calls this instead of Qt.quit() while the driver runs.
  function catchQuit() { caughtQuits++ }
  // Synchronous, and "" for a file that isn't there (a FileView keeps the
  // last text it read). The harness sets QML_XHR_ALLOW_FILE_READ.
  function readFile(file) {
    var request = new XMLHttpRequest()
    request.open("GET", "file://" + file, false)
    try {
      request.send()
    } catch (error) {
      return ""
    }
    return String(request.responseText || "")
  }
  function writeFile(file, text) {
    writer.path = file
    writer.setText(text)
  }
  function fakeCalls() { return Number(readFile(fake + "/count").trim()) || 0 }
  function fakeCall(n) { return readFile(fake + "/call-" + n).replace(/\n$/, "").split("\n") }
  function setMode(mode) { writeFile(fake + "/mode", mode + "\n") }
  function hasDraft() { return readFile(draftPath).trim() !== "" }
  // Poll `condition` every 50 ms, then next(); fail after `limit` ms.
  function waitFor(condition, what, next, limit) {
    var deadline = Date.now() + (limit || 15000)
    poller.check = function() {
      try {
        if (condition()) next()
        else if (Date.now() > deadline) fail("timed out waiting for " + what)
        else poller.restart()
      } catch (error) {
        fail(error + (error.stack ? "\n" + error.stack : ""))
      }
    }
    poller.restart()
  }
  // A look the lock doesn't have yet: the saved one, dimmed by `dim`.
  function unappliedEdit(dim) {
    studio.commit(Draft.setBackground(studio.savedDraft, "dim", dim))
  }
  function settled() { return !studio.checker.pending && studio.session === "ready" && studio.unapplied }
  function noticeIs(key, kind) {
    return studio.notice && studio.notice.kind === kind && studio.notice.text === key
  }
  // Apply's result for each fake answer: the words, the kind, whether it is
  // saved, and how many calls (two when the first didn't answer).
  readonly property var applyCases: [
    { mode: "ok", text: "studio.applied", kind: "ok", saved: true, calls: 1 },
    { mode: "unchanged", text: "studio.applied", kind: "ok", saved: true, calls: 1 },
    { mode: "invalid-json", text: "studio.result.invalid-json", kind: "error", saved: false, calls: 1 },
    { mode: "invalid", text: "studio.result.invalid", value: "layout has an unknown element: x", kind: "error", saved: false, calls: 1 },
    { mode: "locked", text: "studio.result.locked.apply", kind: "warning", saved: false, calls: 1 },
    { mode: "unsupported", text: "studio.result.unsupported", kind: "error", saved: false, calls: 1 },
    { mode: "no-entry", text: "studio.result.no-entry", kind: "error", saved: false, calls: 1 },
    { mode: "unexpected", text: "studio.result.unexpected", kind: "error", saved: false, calls: 1 },
    { mode: "not-ready", text: "studio.result.not-ready", kind: "warning", saved: false, calls: 1 },
    { mode: "not-running", text: "studio.result.not-running", kind: "error", saved: false, calls: 1 },
    { mode: "target-not-found", text: "studio.result.target-not-found", kind: "error", saved: false, calls: 1 },
    { mode: "function-not-found", text: "studio.result.function-not-found", kind: "error", saved: false, calls: 1 },
    { mode: "failed", text: "studio.result.failed", kind: "error", saved: false, calls: 1 },
    { mode: "not-responding", text: "studio.result.not-responding.apply", kind: "warning", saved: false, calls: 2 },
    { mode: "not-responding-once", text: "studio.applied", kind: "ok", saved: true, calls: 2 }
  ]
  // One Apply against the fake, checked: a step body.
  function applyCase(index, next) {
    var c = applyCases[index]
    reset()
    setMode(c.mode === "not-responding-once" ? c.mode + ":" + Date.now() : c.mode)
    var before = fakeCalls()
    var saved = studio.savedDraft
    unappliedEdit(0.31 + index / 100)
    var sent = studio.draft
    waitFor(settled, "the checker", function() {
      expect(studio.canApply, "Apply is enabled with a change: " + json(studio.draft))
      studio.apply()
      expect(studio.notice && studio.notice.kind === "busy" && !studio.canApply, "applying shows and holds Apply")
      waitFor(function() { return !studio.sources.applying && studio.notice && studio.notice.kind !== "busy" }, "the apply result", function() {
        var expected = c.value ? FoamyI18n.t(c.text, c.value) : FoamyI18n.t(c.text)
        expect(noticeIs(expected, c.kind), c.mode + ": notice " + json(studio.notice) + ", expected " + expected)
        expect(studio.notice.text.indexOf("Saved") === -1 && studio.notice.text.indexOf("in time") === -1, "never the helper's words")
        var calls = fakeCalls() - before
        expect(calls === c.calls, c.mode + ": " + calls + " calls to omarchy-shell")
        var args = fakeCall(fakeCalls())
        expect(args[0] === "foamy.lock" && args[1] === "saveLook" && args.length === 3, "the call: " + json(args))
        expect(args[2] === JSON.stringify(Draft.ordered(sent)), "the look in the lock's key order: " + args[2])
        if (c.saved) {
          expect(Draft.same(studio.savedDraft, sent) && !studio.unapplied && !studio.canApply, c.mode + ": the draft is the saved look")
        } else {
          expect(Draft.same(studio.savedDraft, saved) && studio.unapplied && studio.canApply, c.mode + ": nothing changes, Apply stays")
        }
        // The draft file: deleted after a save, kept otherwise.
        waitFor(function() { return studio.sources.draftIdle && hasDraft() === !c.saved }, c.mode + ": the draft file " + (c.saved ? "deleted" : "kept"), next)
      })
    })
  }

  FileView { id: writer; printErrors: false; blockWrites: true; atomicWrites: false }
  Timer {
    id: poller
    interval: 50
    property var check: null
    onTriggered: check()
  }
  Process {
    id: whichShell
    command: ["bash", "-c", "command -v omarchy-shell"]
    stdout: StdioCollector { id: whichOutput; waitForEnd: true }
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
        // The desktop, as the lock reads it: the wallpaper and the lock's entry.
        expect(studio.lockSettings.timeFormat === "12h" && view.timeFormat === "12h", "the lock's time format: " + view.timeFormat)
        expect(studio.sources.wallpaperPath.indexOf("wallpaper.png") !== -1 && view.backgroundPath === studio.sources.wallpaperPath,
          "the Omarchy wallpaper: " + studio.sources.wallpaperPath + " " + studio.sources.wallpaperError)
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
        expect(!studio.applyBlocked || !studio.canApply, "a blocking problem disables Apply")
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
    { name: "inspector: style, size, opacity", wait: 0, run: function(next) {
        reset()
        studio.selectModule("clock")
        var styles = find(studio.inspector, "studioStyles")
        expect(styles && styles.visible && styles.options.length === Layout.STYLES.clock.length, "clock style tiles " + (styles ? styles.options : ""))
        // The cursor walks on screen: towards the end is Right, or Left right to left.
        styles.forceActiveFocus()
        styles.step(inward, 0)
        expect(styles.cursor === 1, "the cursor moved to the next tile: " + styles.cursor)
        styles.choose(styles.cursor)
        expectDraft('{"preset":"foamy","layout":{"clock":{"style":"bold"}}}')
        var size = find(studio.inspector, "studioSize")
        size.stepBy(4)
        expectDraft('{"preset":"foamy","layout":{"clock":{"style":"bold","scale":1.2}}}')
        // A drag shows live and commits once.
        var steps = studio.history.past.length
        size.moved(1.5)
        expect(studio.previewDraft !== null && Draft.same(studio.look.elements.clock.scale, 1.2)
          && view.look.elements.clock.scale === 1.5, "the drag shows on the canvas only: " + json(view.look.elements.clock))
        size.moved(1.6)
        size.committed(1.6)
        expect(studio.previewDraft === null && studio.history.past.length === steps + 1, "one undo step for a drag")
        expect(studio.look.elements.clock.scale === 1.6, "scale " + studio.look.elements.clock.scale)
        var opacity = find(studio.inspector, "studioOpacity")
        opacity.committed(0.55)
        expect(studio.look.elements.clock.opacity === 0.55, "opacity " + json(studio.look.elements.clock))
        expect(!find(studio.inspector, "studioGlass").visible, "the bold clock has no glass")
        // The field keeps to its limits.
        studio.selectModule("password")
        expect(!find(studio.inspector, "studioShown").visible, "the field can't be hidden")
        find(studio.inspector, "studioOpacity").committed(0.4)
        expect(studio.look.elements.password.opacity === 0.7, "the field's opacity floor: " + studio.look.elements.password.opacity)
        expect(find(studio.inspector, "studioSize").from === 0.85, "the field's scale floor")
        next()
      } },
    { name: "inspector: glass, zone, offset, screens, shown", wait: 0, run: function(next) {
        reset()
        studio.selectModule("media")
        var glass = find(studio.inspector, "studioGlass")
        expect(glass.visible && glass.value === 1, "the media card's glass, from the look: " + glass.value)
        glass.committed(0.4)
        expectDraft('{"preset":"foamy","layout":{"media":{"glass":0.4}}}')
        var own = find(studio.inspector, "studioGlassReset")
        expect(own.visible, "the look's glass can come back")
        own.clicked()
        expectDraft('{"preset":"foamy"}')
        var zones = find(studio.inspector, "studioZones")
        zones.picked("bottom-end")
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-end"}}}')
        // Offsets in grid steps (22.5 px at 1080): X towards the reading end.
        var x = find(studio.inspector, "studioOffsetX"), y = find(studio.inspector, "studioOffsetY")
        x.committed(-2)
        y.committed(-1)
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-end","offset":{"x":-0.023437,"y":-0.02037}}}}')
        expect(x.value === -2 && x.detail === FoamyI18n.t("studio.px", FoamyI18n.number(-45, 0)), "X shows " + x.value + " (" + x.detail + ")")
        expect(near(view.drawnRect("media").y, view.reservedRect("media").y - 22, 0.5), "moved up 22 px")
        var resetButton = find(studio.inspector, "studioResetPosition")
        expect(resetButton.enabled, "an offset can be reset")
        resetButton.clicked()
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-end"}}}')
        expect(!resetButton.enabled, "nothing to reset")
        find(studio.inspector, "studioScreens").picked("primary")
        expect(studio.look.elements.media.screens === "primary", "screens " + json(studio.draft))
        // The field: never into the top row, and the fields keep it below the top third.
        studio.selectModule("password")
        zones = find(studio.inspector, "studioZones")
        expect(!zones.usable("top-center") && zones.usable("middle-center"), "the field's zones")
        zones.forceActiveFocus()
        zones.cursor = 4
        zones.step(0, -1)
        expect(zones.cursor === 4, "the cursor skips the top row: " + zones.cursor)
        find(studio.inspector, "studioOffsetY").committed(-40)
        expect(view.drawnRect("password").y >= 1080 / 3, "the field stays below the top third: " + json(view.drawnRect("password")))
        expect(!find(studio.inspector, "studioScreens").visible || !find(studio.inspector, "studioScreens").parent.visible, "the field takes no screens")
        // Shown: the calendar comes on and goes off again, one step each.
        studio.selectModule("calendar")
        var shown = find(studio.inspector, "studioShown")
        expect(shown.visible && !shown.checked, "the calendar is hidden")
        shown.toggled()
        expect(studio.look.elements.calendar.hidden === false && view.elementRects.calendar !== undefined, "shown on the canvas")
        studio.selectModule("media")
        capture("studio-inspector", next)
      } },
    { name: "inspector: every edit is one undo step", wait: 0, run: function(next) {
        var undos = 0
        while (Draft.canUndo(studio.history)) { studio.undo(); undos++ }
        expect(undos === 9, "undo steps " + undos)
        expectDraft('{"preset":"foamy"}')
        next()
      } },
    { name: "library: drag a hidden module onto the canvas", wait: 0, run: function(next) {
        reset()
        studio.libraryDragStart("calendar")
        expect(studio.selected === "calendar" && studio.page === "module", "the dragged module is selected")
        // Over the library: nothing on the canvas yet.
        studio.libraryDragMove(scenePoint(studio.library, 40, 40), Qt.NoModifier)
        expect(canvas.gesture === null, "not over the canvas")
        // Over the canvas, 3 px off the top-start anchor: it snaps there.
        studio.libraryDragMove(viewToScene(400, 300), Qt.NoModifier)
        var g = canvas.gesture
        expect(g && g.insert && view.elementRects.calendar !== undefined, "the calendar follows the pointer: " + json(view.elementRects.calendar))
        var anchor = anchorOf(g, "top-start")
        studio.libraryDragMove(viewToScene(anchor.x + anchor.width / 2 + 3, anchor.y + anchor.height / 2 - 2), Qt.NoModifier)
        expect(canvas.gesture.result.zone === "top-start" && canvas.gesture.result.x.kind === "anchor", "snapped: " + json(canvas.gesture.result))
        expectDraft('{"preset":"foamy"}')
        capture("studio-library-drag", next)
      } },
    { name: "library: the drop shows it there", wait: 0, run: function(next) {
        studio.libraryDragEnd()
        expectDraft('{"preset":"foamy","layout":{"calendar":{"zone":"top-start","hidden":false}}}')
        expect(canvas.gesture === null && studio.libraryDrag === "", "the drag is over")
        // Dropped off the canvas: nothing changes.
        studio.libraryDragStart("calendar")
        studio.libraryDragMove(viewToScene(900, 500), Qt.NoModifier)
        studio.libraryDragMove(scenePoint(studio.library, 40, 40), Qt.NoModifier)
        expect(canvas.gesture === null, "left the canvas")
        studio.libraryDragEnd()
        expectDraft('{"preset":"foamy","layout":{"calendar":{"zone":"top-start","hidden":false}}}')
        next()
      } },
    { name: "library: drag from the canvas onto the library hides", wait: 0, run: function(next) {
        expect(canvas.beginMove("media"), "beginMove media")
        canvas.moveGesture(-50 * inward * canvas.zoom, 0, Qt.NoModifier, scenePoint(studio.library, 60, 120))
        expect(canvas.hiding && studio.library.dropTarget, "over the library: drop to hide")
        canvas.finishGesture()
        expect(studio.look.elements.media.hidden === true, "media hidden: " + json(studio.draft))
        // The field never hides.
        canvas.beginMove("password")
        canvas.moveGesture(-50 * canvas.zoom, 0, Qt.NoModifier, scenePoint(studio.library, 60, 120))
        expect(!canvas.hiding, "the field isn't hidden by a drop")
        canvas.cancelGesture()
        // The keyboard: Insert shows, Delete hides, Up and Down walk.
        studio.selectModule("media")
        studio.library.forceActiveFocus()
        expect(studio.library.keyPressed(Qt.Key_Insert, Qt.NoModifier) && !studio.look.elements.media.hidden, "Insert shows")
        expect(studio.library.keyPressed(Qt.Key_Delete, Qt.NoModifier) && studio.look.elements.media.hidden, "Delete hides")
        studio.library.keyPressed(Qt.Key_Down, Qt.NoModifier)
        expect(studio.selected === "status", "Down selects the next module: " + studio.selected)
        studio.selectModule("password")
        studio.library.keyPressed(Qt.Key_Delete, Qt.NoModifier)
        expect(!studio.look.elements.password.hidden, "Delete never hides the field")
        canvas.forceActiveFocus()
        next()
      } },
    { name: "presets: the menu", wait: 0, run: function(next) {
        reset()
        studio.presetMenu.open()
        expect(studio.presetMenu.visible && studio.presetMenu.cursor === 0, "open on the current preset")
        expect(find(studio.presetMenu, "studioPresetItem-fluent") !== null, "every preset is listed")
        studio.presetMenu.keyPressed(Qt.Key_Down)
        expect(studio.presetMenu.cursor === 4, "Down moves a row: " + studio.presetMenu.cursor)
        next()
      } },
    { name: "presets: the menu drawn", wait: 600, run: function(next) {
        capture("studio-preset-menu", next)
      } },
    { name: "presets: without changes a pick is immediate", wait: 0, run: function(next) {
        studio.presetMenu.keyPressed(Qt.Key_Return)
        expect(!studio.presetMenu.visible && studio.pendingPreset === "", "picked and closed")
        expectDraft('{"preset":"dock"}')
        studio.undo()
        expectDraft('{"preset":"foamy"}')
        next()
      } },
    { name: "presets: with changes it asks", wait: 0, run: function(next) {
        studio.commit({ preset: "foamy", layout: { clock: { scale: 1.2 } }, background: { dim: 0.5 } })
        studio.requestPreset("corner")
        expect(studio.pendingPreset === "corner" && find(studio, "studioPresetDialog").visible, "the question shows")
        expectDraft('{"preset":"foamy","layout":{"clock":{"scale":1.2}},"background":{"dim":0.5}}')
        capture("studio-preset-dialog", next)
      } },
    { name: "presets: replace, keep and cancel", wait: 0, run: function(next) {
        studio.answerPreset(false)
        expectDraft('{"preset":"corner"}')
        studio.undo()
        expectDraft('{"preset":"foamy","layout":{"clock":{"scale":1.2}},"background":{"dim":0.5}}')
        studio.requestPreset("corner")
        expect(find(studio, "studioPresetKeep").enabled, "the changes can be kept")
        studio.answerPreset(true)
        expectDraft('{"preset":"corner","layout":{"clock":{"scale":1.2}},"background":{"dim":0.5}}')
        studio.undo()
        studio.requestPreset("zen")
        expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && studio.pendingPreset === "", "Esc cancels")
        expectDraft('{"preset":"foamy","layout":{"clock":{"scale":1.2}},"background":{"dim":0.5}}')
        // The strip asks the same way.
        studio.requestPreset("island")
        expect(studio.pendingPreset === "island", "the strip asks too")
        studio.cancelPreset()
        next()
      } },
    { name: "background page", wait: 0, run: function(next) {
        reset()
        find(studio.library, "studioSceneBackground").clicked()
        var page = studio.scenePage
        expect(studio.page === "background" && page.visible && !studio.inspector.visible, "the background page shows")
        find(page, "studioSource-aurora").clicked()
        expectDraft('{"preset":"foamy","background":{"source":"aurora"}}')
        find(page, "studioDecor").picked("frame")
        find(page, "studioSource-omarchy").clicked()
        find(page, "studioBlur").committed(0.5)
        expectDraft('{"preset":"foamy","background":{"decor":"frame","blur":0.5}}')
        // The Omarchy wallpaper, as the lock finds it.
        expect(studio.sources.wallpaperPath !== "" && view.backgroundPath === studio.sources.wallpaperPath && !view.backgroundPrepared,
          "the wallpaper on the canvas: " + view.backgroundPath)
        // The file chooser's replies (it never runs here).
        studio.sources.applyPick(1, '{"ok":false,"code":"PORTAL_UNAVAILABLE","error":"no portal"}')
        expect(find(page, "studioPictureProblem").text === FoamyI18n.t("studio.pick.PORTAL_UNAVAILABLE"), "portal error: " + find(page, "studioPictureProblem").text)
        studio.sources.applyPick(127, "")
        expect(find(page, "studioPictureProblem").text === FoamyI18n.t("studio.helperUnavailable"), "no helper")
        studio.sources.applyPick(0, '{"ok":true,"cancelled":true}')
        expect(studio.sources.pickError === "", "cancelled is no error")
        studio.sources.applyPick(0, '{"ok":true,"path":"/home/you/clip.gif"}')
        expect(studio.sources.pickError === "UNSUPPORTED", "a file the lock can't use: " + studio.sources.pickError)
        expectDraft('{"preset":"foamy","background":{"decor":"frame","blur":0.5}}')
        // A picture: the theme colour until the helper has prepared it.
        studio.sources.applyPick(0, JSON.stringify({ ok: true, path: test.picture }))
        expectDraft(JSON.stringify({ preset: "foamy", background: { source: "picture", path: test.picture, decor: "frame", blur: 0.5 } }))
        expect(view.backgroundPath === "", "not decoded here, not yet prepared: " + view.backgroundPath)
        test.saved.waits = 0
        next()
      } },
    { name: "the picture is prepared by the helper", wait: 300, run: function(next) {
        var s = studio.sources
        if (s.pictureSource !== test.picture && !s.pictureError) {
          if (++test.saved.waits > 60) fail("the picture wasn't prepared: " + s.pictureError)
          runner.interval = 250
          runner.restart()
          return
        }
        expect(s.pictureError === "" && s.picturePath.indexOf(s.pictureDirectory) === 0, "prepared: " + s.picturePath + " " + s.pictureError)
        expect(view.backgroundPath === s.picturePath && view.backgroundPrepared, "the canvas shows the prepared picture")
        capture("studio-background", next)
      } },
    { name: "a missing picture is reported", wait: 0, run: function(next) {
        studio.sources.applyPick(0, '{"ok":true,"path":"/nonexistent/foamy-lock-studio/gone.png"}')
        test.saved.waits = 0
        next()
      } },
    { name: "the helper says it is missing", wait: 300, run: function(next) {
        var s = studio.sources
        if (s.pictureError !== "background-missing") {
          if (++test.saved.waits > 60) fail("no error for a missing picture: " + s.pictureError)
          runner.interval = 250
          runner.restart()
          return
        }
        expect(find(studio.scenePage, "studioPictureProblem").text === FoamyI18n.t("studio.picture.missing"), "missing picture")
        expect(view.backgroundPath === "", "the theme colour shows")
        next()
      } },
    { name: "glass and dim page", wait: 0, run: function(next) {
        reset()
        find(studio.library, "studioSceneGlass").clicked()
        var page = studio.scenePage
        expect(studio.page === "glass" && find(page, "studioDim").visible, "the glass and dim page shows")
        find(page, "studioDim").stepBy(1)
        find(page, "studioGlassOpacity").committed(0.4)
        find(page, "studioTint").picked("accent")
        expectDraft('{"preset":"foamy","background":{"dim":0.3},"glass":{"opacity":0.4,"tint":"accent"}}')
        find(page, "studioDim").committed(0.95)
        expect(studio.look.background.dim === 0.9, "dim keeps to 90 %: " + studio.look.background.dim)
        studio.selectModule("media")
        studio.page = "glass"
        capture("studio-glass", next)
      } },
    { name: "back to the inspector", wait: 0, run: function(next) {
        reset()
        studio.selectModule("clock")
        expect(studio.inspector.visible && !studio.scenePage.visible, "the inspector is back")
        canvas.forceActiveFocus()
        next()
      } },
    { name: "accessibility: the tab order", wait: 0, run: function(next) {
        reset()
        canvas.forceActiveFocus()
        // Tab from the canvas all the way round: every stop has a name and a
        // role, and the order reaches every pane.
        var item = canvas, stops = []
        for (var i = 0; i < 300; i++) {
          item = item.nextItemInFocusChain(true)
          if (!item || item === canvas) break
          stops.push(item)
        }
        expect(item === canvas, "Tab comes back to the canvas after " + stops.length + " stops")
        var names = []
        for (var s = 0; s < stops.length; s++) {
          var stop = stops[s]
          var name = String(stop.Accessible.name || "")
          expect(name !== "" && stop.Accessible.role !== Accessible.NoRole, "a stop without a name or role: " + stop + " " + stop.objectName)
          expect(stop.visible && stop.enabled, "a hidden or disabled stop: " + stop)
          names.push(stop.objectName || name)
        }
        var wanted = ["studioPresetButton", "studioPreview", "studioLibrary-clock", "studioSceneBackground", "studioZonesSwitch",
          "studioSnapSwitch", "studioPresetStrip"]
        for (var w = 0; w < wanted.length; w++) expect(names.indexOf(wanted[w]) !== -1, "Tab reaches " + wanted[w] + ": " + json(names))
        // Disabled buttons are skipped (nothing to apply, nothing to undo).
        expect(names.indexOf("studioApply") === -1 && names.indexOf("studioUndo") === -1, "disabled buttons are skipped")
        ok(stops.length + " tab stops, all named")
        next()
      } },
    // --- saving ---------------------------------------------------------------
    { name: "the fake omarchy-shell comes first", wait: 0, run: function(next) {
        expect(test.fake !== "", "FOAMY_LOCK_STUDIO_FAKE is set")
        whichShell.running = true
        waitFor(function() { return !whichShell.running && whichOutput.text !== "" }, "command -v omarchy-shell", function() {
          var found = whichOutput.text.trim()
          // Never the real shell: stop here if anything else would answer.
          if (found !== test.fake + "/bin/omarchy-shell") {
            console.error("STUDIO_FAIL [" + label + "] omarchy-shell resolves to " + found)
            Qt.exit(1)
            return
          }
          next()
        })
      } },
    { name: "the saved look and the draft on open", wait: 0, run: function(next) {
        reset()
        // shell.json has the lock's entry without look keys: the default.
        expect(Draft.same(studio.savedDraft, { preset: "foamy" }), "saved look " + json(studio.savedDraft))
        expect(studio.session === "ready" && !studio.unapplied && !studio.canApply, "no changes: nothing to apply")
        var status = find(studio, "studioStatus")
        expect(status && status.text === FoamyI18n.t("studio.matchesLock"), "status: " + (status ? status.text : "none"))
        // The canvas moves only while the window can be seen and has the keyboard.
        expect(view.displayAwake === (studio.awake && studio.Window.active), "displayAwake follows the window")
        studio.commit({ preset: "zen" })
        expect(studio.unapplied && status.text === FoamyI18n.t("studio.unapplied"), "an edit is not applied: " + status.text)
        waitFor(function() { return studio.sources.draftIdle && readFile(test.draftPath).indexOf('"zen"') !== -1 },
          "the draft written after an edit", next, 5000)
      } },
    { name: "the draft file holds the look and its undo steps", wait: 0, run: function(next) {
        var stored = JSON.parse(readFile(test.draftPath))
        expect(stored.version === 1 && Draft.same(stored.look, { preset: "zen" }), "look " + json(stored.look))
        expect(stored.history.length >= 1 && Draft.same(stored.history[stored.history.length - 1], { preset: "foamy" }), "history " + json(stored.history))
        next()
      } },
    { name: "a draft that differs asks on open", wait: 0, run: function(next) {
        // As on a new start: the draft on disk and shell.json are read again.
        studio.history = Draft.history({ preset: "foamy" })
        studio.session = "loading"
        studio.draftReport = null
        studio.sources.loadDraft()
        waitFor(function() { return studio.session === "ask" }, "the question", function() {
          var dialog = find(studio, "studioRestoreDialog")
          expect(dialog && dialog.visible && studio.questionOpen, "the restore question shows")
          expect(Draft.same(studio.draft, { preset: "zen" }), "the draft shows behind it: " + json(studio.draft))
          expect(Draft.canUndo(studio.history), "with its undo steps")
          expect(find(studio, "studioRestoreContinue").activeFocus, "Continue editing has the keyboard")
          expect(!studio.appKey(Qt.Key_Z, Qt.ControlModifier, "") && Draft.same(studio.draft, { preset: "zen" }), "keys behind it do nothing")
          capture("studio-restore", next)
        })
      } },
    { name: "start from saved deletes the draft", wait: 0, run: function(next) {
        find(studio, "studioRestoreSaved").clicked()
        expect(studio.session === "ready" && Draft.same(studio.draft, { preset: "foamy" }) && !Draft.canUndo(studio.history), "from the saved look")
        waitFor(function() { return studio.sources.draftIdle && !hasDraft() }, "the draft deleted", next)
      } },
    { name: "continue editing keeps it", wait: 0, run: function(next) {
        studio.commit({ preset: "corner" })
        waitFor(function() { return studio.sources.draftIdle && hasDraft() }, "the draft written", function() {
          studio.history = Draft.history({ preset: "foamy" })
          studio.session = "loading"
          studio.draftReport = null
          studio.sources.loadDraft()
          waitFor(function() { return studio.session === "ask" }, "the question", function() {
            // Esc keeps it too.
            expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, ""), "Esc answers")
            expect(studio.session === "ready" && Draft.same(studio.draft, { preset: "corner" }) && hasDraft(), "continuing: " + json(studio.draft))
            next()
          })
        })
      } },
    { name: "the lock's own look with undo steps doesn't ask", wait: 0, run: function(next) {
        studio.commit({ preset: "foamy" })
        waitFor(function() { return studio.sources.draftIdle && readFile(test.draftPath).indexOf('"look":{"preset":"foamy"}') !== -1 }, "the draft written", function() {
          studio.history = Draft.history({ preset: "zen" })
          studio.session = "loading"
          studio.draftReport = null
          studio.sources.loadDraft()
          waitFor(function() { return studio.session !== "loading" }, "the start", function() {
            expect(studio.session === "ready" && Draft.same(studio.draft, { preset: "foamy" }) && Draft.canUndo(studio.history),
              "the same look starts with its steps: " + json(studio.history))
            next()
          })
        })
      } },
    { name: "a corrupt draft is reported once", wait: 0, run: function(next) {
        reset()
        writeFile(test.draftPath, "{ not a draft")
        studio.session = "loading"
        studio.draftReport = null
        studio.sources.loadDraft()
        waitFor(function() { return studio.session === "ready" }, "the start", function() {
          expect(noticeIs(FoamyI18n.t("studio.draft.corrupt"), "warning"), "notice " + json(studio.notice))
          expect(Draft.same(studio.draft, { preset: "foamy" }), "from the saved look")
          expect(readFile(test.draftPath.replace("studio-draft.json", "studio-draft.corrupt.json")).indexOf("not a draft") !== -1, "set aside")
          expect(!hasDraft(), "the broken file is gone")
          studio.commit({ preset: "zen" })
          expect(studio.notice === null, "an edit clears it")
          // A helper that can't start, or another failure, never stops the app.
          studio.sources.applyDraft("draft-save", 127, "")
          expect(noticeIs(FoamyI18n.t("studio.draft.saveFailed", FoamyI18n.t("studio.helperUnavailable")), "warning"), "save failed: " + json(studio.notice))
          next()
        })
      } }
  ].concat(applyCases.map(function(c, index) {
    return { name: "apply: " + c.mode, wait: 0, run: function(next) { applyCase(index, next) } }
  })).concat([
    { name: "apply: answers without the fake", wait: 0, run: function(next) {
        reset()
        unappliedEdit(0.5)
        var entry = Draft.ordered(studio.draft)
        studio.sources.applyApply(127, "", entry)
        expect(noticeIs(FoamyI18n.t("studio.helperUnavailable"), "error"), "unavailable: " + json(studio.notice))
        studio.sources.applyApply(1, '{"ok":false,"code":"INVALID_REQUEST","error":"the look isn\'t JSON"}', entry)
        expect(noticeIs(FoamyI18n.t("studio.result.error", "INVALID_REQUEST"), "error"), "refused: " + json(studio.notice))
        studio.sources.applyApply(0, '{"ok":false,"result":"no-omarchy-shell","message":"omarchy-shell isn\'t installed.","confirmed":true,"attempts":0}', entry)
        expect(noticeIs(FoamyI18n.t("studio.result.no-omarchy-shell"), "error"), "no omarchy-shell: " + json(studio.notice))
        expect(studio.unapplied && Draft.same(studio.savedDraft, { preset: "foamy" }), "nothing saved")
        next()
      } },
    { name: "apply needs a change and no problem on a screen", wait: 0, run: function(next) {
        reset()
        expect(!studio.canApply && !find(studio, "studioApply").enabled, "nothing to apply")
        studio.commit({ preset: "foamy", layout: { status: { offset: { x: -0.4, y: 0.07 } } } })
        waitFor(function() { return !studio.checker.pending }, "the checker", function() {
          expect(studio.applyBlocked && !studio.canApply, "a problem on a connected screen blocks it")
          next()
        })
      } },
    { name: "preview full screen", wait: 0, run: function(next) {
        reset()
        setMode("ok")
        unappliedEdit(0.45)
        var before = fakeCalls()
        studio.previewFull()
        waitFor(function() { return !studio.sources.previewing && studio.notice && studio.notice.kind !== "busy" }, "the preview", function() {
          expect(noticeIs(FoamyI18n.t("studio.previewShown"), "ok"), "notice " + json(studio.notice))
          var args = fakeCall(fakeCalls())
          expect(fakeCalls() - before === 1 && args[0] === "foamy.lock" && args[1] === "previewLook"
            && args[2] === JSON.stringify(Draft.ordered(studio.draft)), "the call: " + json(args))
          expect(studio.unapplied && Draft.same(studio.savedDraft, { preset: "foamy" }), "a preview saves nothing")
          setMode("locked")
          studio.previewFull()
          waitFor(function() { return !studio.sources.previewing && studio.notice.kind !== "busy" }, "the preview", function() {
            expect(noticeIs(FoamyI18n.t("studio.result.locked.preview"), "warning"), "locked: " + json(studio.notice))
            setMode("not-running")
            studio.previewFull()
            waitFor(function() { return !studio.sources.previewing && studio.notice.kind !== "busy" }, "the preview", function() {
              expect(noticeIs(FoamyI18n.t("studio.result.not-running"), "error"), "not running: " + json(studio.notice))
              studio.sources.applyPreview(124, "", "")
              expect(noticeIs(FoamyI18n.t("studio.result.not-responding"), "warning"), "timed out: " + json(studio.notice))
              studio.sources.applyPreview(127, "", "bash: omarchy-shell: No such file or directory")
              expect(noticeIs(FoamyI18n.t("studio.result.no-omarchy-shell"), "error"), "missing: " + json(studio.notice))
              next()
            })
          })
        })
      } },
    { name: "quitting without changes", wait: 0, run: function(next) {
        reset()
        var quits = test.caughtQuits
        expect(studio.appKey(Qt.Key_Q, Qt.ControlModifier, "") && !studio.quitAsked, "Ctrl+Q doesn't ask")
        waitFor(function() { return test.caughtQuits === quits + 1 }, "the quit", next, 4000)
      } },
    { name: "quitting with changes asks", wait: 0, run: function(next) {
        reset()
        unappliedEdit(0.55)
        waitFor(settled, "the checker", function() {
          var quits = test.caughtQuits
          expect(studio.appKey(Qt.Key_Q, Qt.ControlModifier, "") && studio.quitAsked, "Ctrl+Q asks")
          expect(find(studio, "studioQuitDialog").visible && find(studio, "studioQuitApply").activeFocus, "Apply and quit has the keyboard")
          expect(test.caughtQuits === quits, "not yet")
          capture("studio-quit", next)
        })
      } },
    { name: "quit: cancel, and closing the window asks too", wait: 0, run: function(next) {
        expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && !studio.quitAsked, "Esc cancels")
        var quits = test.caughtQuits
        window.closed()
        expect(studio.quitAsked && test.caughtQuits === quits, "closing asks")
        find(studio, "studioQuitCancel").clicked()
        expect(!studio.quitAsked && window.visible, "cancelled; the window stays")
        waitFor(function() { return studio.sources.draftIdle && hasDraft() }, "the draft kept", next)
      } },
    { name: "quit: apply fails, nothing quits", wait: 0, run: function(next) {
        setMode("locked")
        var quits = test.caughtQuits
        studio.requestQuit()
        find(studio, "studioQuitApply").clicked()
        waitFor(function() { return !studio.sources.applying && !studio.quitAsked }, "the apply", function() {
          expect(noticeIs(FoamyI18n.t("studio.result.locked.apply"), "warning") && test.caughtQuits === quits && !studio.quitting,
            "the problem shows and the app stays: " + json(studio.notice))
          next()
        })
      } },
    { name: "quit: apply and quit", wait: 0, run: function(next) {
        setMode("ok")
        var quits = test.caughtQuits
        var sent = studio.draft
        studio.requestQuit()
        find(studio, "studioQuitApply").clicked()
        waitFor(function() { return test.caughtQuits === quits + 1 }, "the quit", function() {
          expect(Draft.same(studio.savedDraft, sent) && !hasDraft(), "applied, the draft deleted")
          next()
        })
      } },
    { name: "quit: discard deletes the draft", wait: 0, run: function(next) {
        reset()
        unappliedEdit(0.65)
        waitFor(function() { return settled() && studio.sources.draftIdle && hasDraft() }, "the draft", function() {
          var quits = test.caughtQuits
          studio.requestQuit()
          find(studio, "studioQuitDiscard").clicked()
          waitFor(function() { return test.caughtQuits === quits + 1 }, "the quit", function() {
            expect(!hasDraft(), "the draft is deleted")
            next()
          })
        })
      } },
    { name: "screens plugged in and out during a check", wait: 0, run: function(next) {
        reset()
        studio.commit({ preset: "foamy", layout: { status: { offset: { x: -0.4, y: 0.07 } } } })
        var all = studio.monitors
        var extra = { key: "screen:HDMI-A-9", name: "HDMI-A-9", label: "HDMI-A-9 · 1280 × 1024", reference: false, width: 1280, height: 1024 }
        // Mid-debounce: one screen gone, then a new one, then a check at once.
        studio.checker.sizes = all.slice(1)
        studio.checker.sizes = all.slice(1).concat([extra])
        studio.checker.check()
        studio.monitorKey = "screen:gone"
        expect(studio.monitor.key === all[0].key, "a gone screen falls back to the first: " + studio.monitor.key)
        waitFor(function() { return !studio.checker.pending }, "the check", function() {
          var keys = studio.checker.sizes.map(function(s) { return s.key })
          var problems = studio.checker.problems
          expect(problems.length > 0 && problems.every(function(p) { return keys.indexOf(p.key) !== -1 }), "problems only for screens there: " + json(problems))
          expect(problems.some(function(p) { return p.key === extra.key && p.width === 1280 }), "the new screen is checked at its size")
          studio.checker.sizes = Qt.binding(function() { return studio.monitors })
          studio.monitorKey = "reference:1920x1080"
          reset()
          next()
        })
      } }
  ]).concat([
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
  ])

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
