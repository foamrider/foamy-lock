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
import "Model.js" as Model

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
    studio.selected = "clock"
    studio.resetAsked = false
    studio.pendingPreset = ""
    studio.libraryDrag = ""
    studio.nameAsked = ""
    studio.nameTarget = ""
    studio.deleteAsked = ""
    studio.applyAfterPreset = null
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
  // User presets: the fake's answer to savePreset, renamePreset and
  // deletePreset, the lock's entry the app reads, and waiting for a save.
  function setPresetMode(mode) { writeFile(fake + "/preset-mode", mode + "\n") }
  readonly property string shellJson: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  function writeEntry(extra) {
    var plugin = { id: "foamy.lock", timeFormat: "12h" }
    for (var key in extra) plugin[key] = extra[key]
    writeFile(shellJson, JSON.stringify({ version: 1, plugins: [plugin] }) + "\n")
  }
  function savingDone() {
    return !studio.sources.applying && !studio.sources.presetBusy && !studio.applyAfterPreset
      && studio.notice !== null && studio.notice.kind !== "busy"
  }
  function nameField() { return find(studio, "studioPresetName") }
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
      // Changes on a built-in preset ask for a name first; these cases apply as is.
      expect(studio.nameAsked === "new" && find(studio, "studioNameDialog").visible, "Apply asks for a name")
      find(studio, "studioNamePlain").clicked()
      expect(studio.nameAsked === "" && studio.notice && studio.notice.kind === "busy" && !studio.canApply, "applying shows and holds Apply")
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
  // Runs a bash line (the fake Mugshot is written and made executable here).
  Process {
    id: shellLine
    property string line: ""
    command: ["bash", "-c", line]
  }
  Process {
    id: whichShell
    command: ["bash", "-c", "command -v omarchy-shell"]
    stdout: StdioCollector { id: whichOutput; waitForEnd: true }
  }

  FileView { id: status; path: "/proc/self/status"; printErrors: false; blockLoading: true }
  FileView { id: ipcDone; path: test.path("ipc-done"); printErrors: false; blockLoading: true }

  // --- user presets (R2-2), against the fake: each step a body ---------------
  function userPresetSteps() {
    return [
    { name: "user presets: read from shell.json, a bad one skipped", wait: 0, run: function(next) {
        reset()
        setMode("ok")
        setPresetMode("ok")
        writeEntry({ userPresets: [{ id: "calm", name: "Calm <b>x</b>", look: { preset: "zen", background: { dim: 0.6 } } },
          { id: "Bad Id", name: "x", look: {} }] })
        waitFor(function() { return studio.sources.userPresets.length === 1 && studio.sources.userPresetsInvalid === 1 }, "the presets read", function() {
          studio.presetMenu.open()
          var mine = find(studio.presetMenu, "studioPresetsMine"), builtin = find(studio.presetMenu, "studioPresetsBuiltin")
          var tile = find(studio.presetMenu, "studioUserPreset-calm")
          expect(tile && tile.visible && tile.label === "Calm <b>x</b>", "the user preset is listed")
          expect(mine.mapToItem(null, 0, 0).y < tile.mapToItem(null, 0, 0).y
            && tile.mapToItem(null, 0, 0).y < builtin.mapToItem(null, 0, 0).y, "Your presets first, then Built-in")
          expect(mine.text === FoamyI18n.t("studio.presets.mine") && builtin.text === FoamyI18n.t("studio.presets.builtin"), "the headings")
          expect(!find(studio.presetMenu, "studioPresetsEmpty").visible, "no empty note")
          expect(studio.presetMenu.cursor === 1, "open on the current built-in preset, after the user one: " + studio.presetMenu.cursor)
          studio.presetMenu.keyPressed(Qt.Key_Up)
          expect(studio.presetMenu.cursor === 0, "Up reaches Your presets: " + studio.presetMenu.cursor)
          studio.presetMenu.keyPressed(Qt.Key_Down)
          expect(studio.presetMenu.cursor === 1, "Down goes back to Built-in")
          studio.presetMenu.keyPressed(Qt.Key_Home)
          capture("studio-user-presets", function() {
            studio.presetMenu.keyPressed(Qt.Key_Return)
            expect(!studio.presetMenu.visible, "picked and closed")
            expectDraft('{"preset":"zen","background":{"dim":0.6},"userPreset":"calm"}')
            var row = find(studio.library, "studioPresetButton")
            expect(row.text === FoamyI18n.t("studio.preset", "Calm <b>x</b>") && row.detail === "", "the row names it: " + row.text)
            expect(studio.linkedPreset && studio.linkedPreset.id === "calm" && !studio.presetChanged, "based on it, unchanged")
            studio.undo()
            expectDraft('{"preset":"foamy"}')
            next()
          })
        })
      } },
    { name: "user presets: Apply on a built-in preset with changes asks for a name", wait: 0, run: function(next) {
        reset()
        studio.commit({ preset: "corner", background: { dim: 0.5 } })
        waitFor(settled, "the checker", function() {
          var before = fakeCalls()
          studio.apply()
          var field = nameField()
          var expected = FoamyI18n.t("studio.presetName.default", studio.presetLabel("corner"))
          expect(studio.nameAsked === "new" && find(studio, "studioNameDialog").visible && studio.questionOpen, "the name question")
          expect(field.field.text === expected, "prefilled: " + field.field.text + " vs " + expected)
          expect(field.field.inputActiveFocus, "the name field has the keyboard")
          expect(find(studio, "studioNamePlain").visible, "Apply without saving a preset is offered")
          field.field.text = "   "
          expect(studio.nameProblem !== "" && !find(studio, "studioNameSave").enabled, "an empty name can't be saved")
          field.field.text = expected
          capture("studio-preset-name", function() {
            expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && studio.nameAsked === "", "Esc cancels")
            expectDraft('{"preset":"corner","background":{"dim":0.5}}')
            expect(fakeCalls() === before && studio.unapplied, "nothing sent, the draft kept")
            studio.apply()
            nameField().field.text = "  Mine ✓ نمط  "
            find(studio, "studioNameSave").clicked()
            waitFor(savingDone, "the save and apply", function() {
              expect(fakeCalls() - before === 2, (fakeCalls() - before) + " calls")
              var save = fakeCall(fakeCalls() - 1), apply = fakeCall(fakeCalls())
              var item = JSON.parse(save[2])
              expect(save[0] === "foamy.lock" && save[1] === "savePreset" && save.length === 3, "savePreset first: " + json(save))
              expect(item.name === "Mine ✓ نمط" && Layout.userPresetIdError(item.id) === ""
                && JSON.stringify(item.look) === '{"preset":"corner","background":{"dim":0.5}}', "the item: " + save[2])
              expect(apply[1] === "saveLook" && JSON.parse(apply[2]).userPreset === item.id
                && JSON.stringify(JSON.parse(apply[2])) === JSON.stringify({ preset: "corner", background: { dim: 0.5 }, userPreset: item.id }),
                "then saveLook with the link: " + apply[2])
              expect(noticeIs(FoamyI18n.t("studio.applied"), "ok"), "applied: " + json(studio.notice))
              expect(studio.linkedPreset && studio.linkedPreset.id === item.id && studio.userPresets[0].id === item.id, "the draft is based on it")
              expect(Draft.linkOf(studio.savedDraft) === item.id && !studio.unapplied, "the saved look has the link")
              test.saved.mine = item.id
              next()
            })
          })
        })
      } },
    { name: "user presets: Apply on a user preset with changes updates it", wait: 0, run: function(next) {
        studio.commit(Draft.setBackground(studio.draft, "dim", 0.65))
        expect(Draft.linkOf(studio.draft) === test.saved.mine && studio.presetChanged, "an edit keeps the link")
        expect(find(studio.library, "studioPresetButton").detail === FoamyI18n.t("studio.edited"), "edited shows")
        waitFor(settled, "the checker", function() {
          var before = fakeCalls()
          studio.apply()
          expect(studio.nameAsked === "", "no name asked")
          waitFor(savingDone, "the update and apply", function() {
            var save = fakeCall(fakeCalls() - 1)
            var item = JSON.parse(save[2])
            expect(fakeCalls() - before === 2 && item.id === test.saved.mine && item.name === "Mine ✓ نمط"
              && item.look.background.dim === 0.65, "the same preset, updated: " + save[2])
            expect(fakeCall(fakeCalls())[1] === "saveLook" && studio.userPresets[0].look.background.dim === 0.65, "then applied")
            next()
          })
        })
      } },
    { name: "user presets: a refused save stops before Apply", wait: 0, run: function(next) {
        var modes = ["full", "too-large", "write-failed"]
        var round = function(i) {
          if (i === modes.length) {
            setPresetMode("ok")
            next()
            return
          }
          setPresetMode(modes[i])
          studio.commit(Draft.setBackground(studio.draft, "dim", 0.7 + i / 100))
          var saved = studio.savedDraft
          waitFor(settled, "the checker", function() {
            var before = fakeCalls()
            studio.apply()
            waitFor(savingDone, modes[i], function() {
              expect(fakeCalls() - before === 1 && fakeCall(fakeCalls())[1] === "savePreset", modes[i] + ": only savePreset")
              expect(noticeIs(FoamyI18n.t("studio.result." + modes[i]), "error"), modes[i] + ": " + json(studio.notice))
              expect(Draft.same(studio.savedDraft, saved) && studio.unapplied && studio.canApply, modes[i] + ": nothing saved")
              round(i + 1)
            })
          })
        }
        round(0)
      } },
    { name: "user presets: Save as new", wait: 0, run: function(next) {
        studio.presetMenu.open()
        find(studio.presetMenu, "studioPresetSaveNew").clicked()
        expect(studio.nameAsked === "copy" && !studio.presetMenu.visible && !find(studio, "studioNamePlain").visible, "the name question, no plain apply")
        expect(nameField().field.text === FoamyI18n.t("studio.presetName.default", "Mine ✓ نمط"), "prefilled: " + nameField().field.text)
        nameField().field.text = "Second"
        var before = fakeCalls()
        // Enter in the field saves.
        nameField().field.accepted()
        waitFor(savingDone, "the save and apply", function() {
          var item = JSON.parse(fakeCall(fakeCalls() - 1)[2])
          expect(fakeCalls() - before === 2 && item.id !== test.saved.mine && item.name === "Second", "a new preset: " + json(item))
          expect(studio.userPresets.length === 3 && studio.userPresets[0].id === item.id && studio.linkedPreset.id === item.id, "first, and the draft is based on it")
          test.saved.second = item.id
          next()
        })
      } },
    { name: "user presets: rename", wait: 0, run: function(next) {
        studio.presetMenu.open()
        find(studio.presetMenu, "studioUserPresetRename-" + test.saved.second).clicked()
        expect(studio.nameAsked === "rename" && nameField().field.text === "Second", "rename asks, with the name")
        expect(find(studio, "studioNameSave").text === FoamyI18n.t("studio.presetName.rename"), "the button says rename")
        nameField().field.text = "Zweite"
        var before = fakeCalls()
        find(studio, "studioNameSave").clicked()
        waitFor(savingDone, "the rename", function() {
          var call = fakeCall(fakeCalls())
          expect(fakeCalls() - before === 1 && json(call) === json(["foamy.lock", "renamePreset", test.saved.second, "Zweite"]), "renamePreset: " + json(call))
          expect(noticeIs(FoamyI18n.t("studio.presets.done.rename"), "ok"), "renamed: " + json(studio.notice))
          expect(studio.userPresets[0].name === "Zweite" && find(studio.library, "studioPresetButton").text === FoamyI18n.t("studio.preset", "Zweite"), "the new name shows")
          // F2 on the menu's cursor, and Esc.
          studio.presetMenu.open()
          studio.presetMenu.keyPressed(Qt.Key_Home)
          studio.presetMenu.keyPressed(Qt.Key_F2)
          expect(studio.nameAsked === "rename" && studio.nameTarget === test.saved.second, "F2 renames")
          studio.answerName("cancel")
          expect(fakeCalls() === before + 1, "nothing sent")
          next()
        })
      } },
    { name: "user presets: delete asks first", wait: 0, run: function(next) {
        studio.presetMenu.open()
        find(studio.presetMenu, "studioUserPresetDelete-" + test.saved.second).clicked()
        var dialog = find(studio, "studioDeleteDialog")
        expect(studio.deleteAsked === test.saved.second && dialog.visible && find(studio, "studioDeleteCancel").activeFocus, "the question, Cancel first")
        expect(dialog.title === FoamyI18n.t("studio.presets.deleteTitle", "Zweite"), "names it: " + dialog.title)
        var before = fakeCalls()
        expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && studio.deleteAsked === "" && fakeCalls() === before, "Esc keeps it")
        studio.presetMenu.open()
        studio.presetMenu.keyPressed(Qt.Key_Home)
        studio.presetMenu.keyPressed(Qt.Key_Delete)
        expect(studio.deleteAsked === test.saved.second, "Delete asks too")
        find(studio, "studioDeleteConfirm").clicked()
        waitFor(savingDone, "the delete", function() {
          expect(json(fakeCall(fakeCalls())) === json(["foamy.lock", "deletePreset", test.saved.second]), "deletePreset")
          expect(studio.userPresets.length === 2 && !Layout.findUserPreset(studio.userPresets, test.saved.second), "gone from the list")
          expect(studio.linkedPreset === null && studio.basisLabel === studio.presetLabel("corner"), "the draft keeps its look, without the link")
          next()
        })
      } },
    { name: "user presets: picking one with changes, and Reset to it", wait: 0, run: function(next) {
        reset()
        studio.commit({ preset: "foamy", background: { dim: 0.5 } })
        studio.requestPreset("user:calm")
        expect(studio.pendingPreset === "user:calm" && !find(studio, "studioPresetKeep").visible
          && find(studio, "studioPresetReplace").activeFocus, "only replace: " + studio.pendingPreset)
        studio.answerPreset(false)
        expectDraft('{"preset":"zen","background":{"dim":0.6},"userPreset":"calm"}')
        studio.commit(Draft.setBackground(studio.draft, "blur", 0.5))
        studio.requestReset()
        var preset = find(studio, "studioResetPreset")
        expect(preset.enabled && preset.text === FoamyI18n.t("studio.reset.preset", "Calm <b>x</b>"), "Reset offers the user preset: " + preset.text)
        studio.answerReset("preset")
        expectDraft('{"preset":"zen","background":{"dim":0.6},"userPreset":"calm"}')
        // A built-in preset drops the link.
        studio.requestPreset("dock")
        expectDraft('{"preset":"dock"}')
        next()
      } },
    { name: "user presets: back to the plain entry", wait: 0, run: function(next) {
        reset()
        writeFile(shellJson, JSON.stringify({ version: 1, plugins: [{ id: "foamy.lock", timeFormat: "12h" }] }) + "\n")
        waitFor(function() { return studio.sources.userPresets.length === 0 && studio.sources.userPresetsInvalid === 0 }, "no presets", function() {
          studio.presetMenu.open()
          expect(find(studio.presetMenu, "studioPresetsEmpty").visible && studio.presetMenu.cursor === 0, "the empty note")
          studio.presetMenu.close()
          next()
        })
      } }
    ]
  }

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
          // The calendar and the weather start hidden in every preset.
          var shown = name !== "calendar" && name !== "weather"
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
    { name: "samples: never the user's own, the checker's the widest", wait: 0, run: function(next) {
        reset()
        // No PipeWire, Bluetooth or Hyprland connection of the view's own:
        // sample readings, and a made-up place.
        expect(view.liveSources === false && view.hasVolume && view.hasBluetooth && view.bluetoothEnabled
          && view.keyboardLayout === FoamyI18n.t("studio.sample.keyboard"), "sample status readings")
        expect(view.weather && view.weather.location === FoamyI18n.t("studio.sample.place")
          && view.weather.condition === FoamyI18n.t("studio.sample.condition") && Model.weatherFresh(view.weather, Date.now()),
          "sample weather: " + json(view.weather))
        studio.commit({ preset: "foamy", layout: { status: { items: Layout.STATUS_ITEMS },
          weather: { hidden: false, details: "full", location: true } } })
        expect(view.elementRects.weather !== undefined && find(view, "weatherLocation").text === FoamyI18n.t("studio.sample.place"),
          "the weather shows on the canvas, at the sample place")
        for (var i = 0; i < 5; i++) {
          var part = find(view, Layout.STATUS_ITEMS[i] + "Status")
          if (Layout.STATUS_ITEMS[i] !== "battery") expect(part && part.visible, Layout.STATUS_ITEMS[i] + " shows")
        }
        // A hidden view (the probe) measures what the canvas draws.
        for (var n = 0; n < 2; n++) {
          var name = ["status", "weather"][n]
          var zone = studio.look.elements[name].zone
          var anchors = canvas.measureAnchors(name), drawn = view.drawnRect(name), anchor = null
          for (var a = 0; a < anchors.length; a++) if (anchors[a].zone === zone) anchor = anchors[a]
          expect(near(anchor.x, drawn.x, 0.5) && near(anchor.width, drawn.width, 0.5) && near(anchor.height, drawn.height, 0.5),
            name + ": the probe " + json(anchor) + " vs the canvas " + json(drawn))
        }
        // The checker's views: the widest samples, every status item read.
        var checked = 0
        for (var c = 0; c < studio.checker.children.length; c++) {
          var check = studio.checker.children[c]
          if (check.widest === undefined) continue
          checked++
          expect(check.widest && check.weather.condition === FoamyI18n.t("studio.sample.conditionLong")
            && check.weather.location.length === 80 && check.weather.temperature === -150, "widest weather: " + json(check.weather))
          expect(check.systemUptime > 0 && check.memoryTotal > 0 && check.systemLoad !== "" && check.volumePercent === 100
            && check.keyboardLayout === FoamyI18n.t("studio.sample.keyboardLong"), "widest readings")
          var weatherWidth = check.elementRects.weather ? check.elementRects.weather.width : 0
          if (check.width === 1920) expect(weatherWidth > view.elementRects.weather.width, "wider than the canvas's: " + weatherWidth)
        }
        expect(checked === studio.checker.viewCount && checked >= 2, "checker views " + checked)
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
        // No per-part reset (round 4): undo brings the look's glass back.
        expect(find(studio.inspector, "studioGlassReset") === null && find(studio.inspector, "studioResetPosition") === null
          && find(studio.inspector, "studioItemsReset") === null, "no per-part reset buttons")
        studio.undo()
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
        studio.undo()
        studio.undo()
        expectDraft('{"preset":"foamy","layout":{"media":{"zone":"bottom-end"}}}')
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
        expect(undos === 4, "undo steps " + undos)
        expectDraft('{"preset":"foamy"}')
        next()
      } },
    { name: "inspector: every style has a drawing", wait: 0, run: function(next) {
        reset()
        for (var name in Layout.STYLES) {
          studio.selectModule(name)
          var tiles = find(studio.inspector, "studioStyles")
          expect(tiles.options.length === Layout.STYLES[name].length, name + " tiles")
          for (var i = 0; i < Layout.STYLES[name].length; i++) {
            var style = Layout.STYLES[name][i]
            var tile = find(tiles, "studioTile-" + style)
            var art = tile ? tile.children[0] : null
            expect(art && art.known === true && art.styleName === style, name + ":" + style + " has its own drawing")
            expect(tile.Accessible.name === FoamyI18n.t("studio.style." + style), name + ":" + style + " named " + tile.Accessible.name)
          }
        }
        studio.selectModule("date")
        capture("studio-date-styles", function() {
          studio.selectModule("calendar")
          capture("studio-calendar-styles", function() {
            studio.selectModule("weather")
            // The tiles' icons are images: let them load.
            var shown = Date.now()
            waitFor(function() { return Date.now() - shown > 400 }, "the icons", function() { capture("studio-weather-styles", next) })
          })
        })
      } },
    // Cover art: the lock screen's setting through the lock's setCoverArt
    // (the fake omarchy-shell records it; the setting comes back through
    // shell.json), and the look's own media.artwork.
    { name: "inspector: the media's cover", wait: 0, run: function(next) {
        reset()
        studio.selectModule("media")
        var cover = find(studio.inspector, "studioCoverArt"), note = find(studio.inspector, "studioCoverArtNote")
        expect(cover.visible && cover.value === "player" && cover.options.length === 3
          && cover.options.map(function(o) { return o.value }).join() === "off,player,spotify"
          && cover.options[2].label === FoamyI18n.t("studio.coverArt.spotify"), "the cover art choice: " + json(cover.options) + " " + cover.value)
        expect(note.text === FoamyI18n.t("studio.coverArt.note.player") + " " + FoamyI18n.t("studio.coverArt.setting"), "the note: " + note.text)
        var calls = fakeCalls()
        cover.changed("spotify")
        expect(studio.notice && studio.notice.kind === "busy", "saving")
        waitFor(savingDone, "setCoverArt", function() {
          expect(fakeCalls() === calls + 1 && fakeCall(calls + 1).join(" ") === "foamy.lock setCoverArt spotify", "the call: " + fakeCall(calls + 1))
          expect(studio.notice.kind === "ok" && studio.notice.text === FoamyI18n.t("studio.coverArt.saved"), "saved: " + json(studio.notice))
          expect(Draft.same(studio.draft, { preset: "foamy" }) && !Draft.canUndo(studio.history), "a setting, not the look")
          // The lock writes shell.json; the app reads it back.
          writeEntry({ artworkHosts: ["i.scdn.co"] })
          waitFor(function() { return cover.value === "spotify" }, "spotify read back", function() {
            expect(note.text.indexOf("i.scdn.co") !== -1, "the privacy note: " + note.text)
            writeEntry({ artworkHosts: ["images.example.com"] })
            waitFor(function() { return cover.value === "custom" }, "custom hosts", function() {
              expect(cover.options.length === 4 && cover.options[3].label === FoamyI18n.t("studio.coverArt.custom"), "custom listed")
              calls = fakeCalls()
              cover.changed("custom")
              expect(fakeCalls() === calls && !studio.sources.coverArtBusy, "custom writes nothing")
              writeFile(fake + "/cover-mode", "locked\n")
              cover.changed("off")
              waitFor(savingDone, "setCoverArt locked", function() {
                expect(fakeCall(calls + 1).join(" ") === "foamy.lock setCoverArt off", "the call: " + fakeCall(calls + 1))
                expect(studio.notice.kind === "warning" && studio.notice.text === FoamyI18n.t("studio.result.locked.apply"), "locked: " + json(studio.notice))
                writeFile(fake + "/cover-mode", "function-not-found\n")
                cover.changed("off")
                waitFor(savingDone, "an older lock", function() {
                  expect(studio.notice.kind === "error" && studio.notice.text === FoamyI18n.t("studio.coverArt.older"), "older: " + json(studio.notice))
                  writeFile(fake + "/cover-mode", "ok\n")
                  writeEntry({})
                  waitFor(function() { return cover.value === "player" }, "back to the player", function() {
                    // The look's own switch.
                    var art = find(studio.inspector, "studioArtwork")
                    expect(art.visible && art.enabled && art.checked, "the cover shows in the card")
                    art.toggled()
                    expectDraft('{"preset":"foamy","layout":{"media":{"artwork":false}}}')
                    expect(view.elementItem("media").artwork === false, "the canvas drops the cover")
                    art.toggled()
                    expectDraft('{"preset":"foamy"}')
                    find(studio.inspector, "studioStyles").picked("minimal")
                    expect(!art.enabled && find(studio.inspector, "studioArtworkNote").text
                      === FoamyI18n.t("studio.artwork.noCover", FoamyI18n.t("studio.style.minimal")), "minimal has no cover")
                    find(studio.inspector, "studioStyles").picked("disc")
                    expect(art.enabled, "the disc has one")
                    capture("studio-media", next)
                  })
                })
              })
            })
          })
        })
      } },
    { name: "inspector: the password field's reveal", wait: 0, run: function(next) {
        reset()
        studio.selectModule("password")
        var reveal = find(studio.inspector, "studioReveal"), note = find(studio.inspector, "studioRevealNote")
        // Foamy's pill: its own default is "while typing" (its drawing
        // before round 4), and every style takes the choice.
        expect(reveal.visible && reveal.enabled && reveal.options.length === 2 && reveal.value === "typing", "the reveal choice: " + json(reveal.options) + " " + reveal.value)
        expect(reveal.options[1].label === FoamyI18n.t("studio.reveal.typing"), "labelled: " + reveal.options[1].label)
        expect(note.text === FoamyI18n.t("studio.reveal.hint"), "the note: " + note.text)
        var field = view.elementItem("password")
        expect(!field.surfaceShown, "the pill idle: only the hint")
        reveal.picked("always")
        expectDraft('{"preset":"foamy","layout":{"password":{"reveal":"always"}}}')
        expect(field.surfaceShown, "the pill shown while empty")
        reveal.picked("typing")
        expectDraft('{"preset":"foamy"}')
        find(studio.inspector, "studioStyles").picked("box")
        expect(reveal.enabled && reveal.value === "always", "the box: always, its own")
        reveal.picked("typing")
        expectDraft('{"preset":"foamy","layout":{"password":{"style":"box","reveal":"typing"}}}')
        expect(field.surfaceIdleHidden === true, "idle on the canvas: the surface hides")
        studio.previewState = "typing"
        expect(field.surfaceIdleHidden === false, "typing: it shows")
        studio.previewState = "idle"
        reveal.picked("always")
        expectDraft('{"preset":"foamy","layout":{"password":{"style":"box"}}}')
        reveal.picked("typing")
        // A new style keeps an explicit value, until it is that style's own.
        find(studio.inspector, "studioStyles").picked("card")
        expectDraft('{"preset":"foamy","layout":{"password":{"style":"card","reveal":"typing"}}}')
        find(studio.inspector, "studioStyles").picked("dots")
        expect(reveal.enabled && reveal.value === "typing", "the dots: while typing")
        expectDraft('{"preset":"foamy","layout":{"password":{"style":"dots"}}}')
        reveal.picked("always")
        expect(find(field, "dotsTrack").visible, "the dots' track while empty")
        expect(!find(studio.inspector, "studioItems").visible && !find(studio.inspector, "studioDetails").visible, "only the field's own keys")
        var undos = 0
        while (Draft.canUndo(studio.history)) { studio.undo(); undos++ }
        expect(undos === 9, "undo steps " + undos)
        next()
      } },
    { name: "inspector: the status items", wait: 0, run: function(next) {
        reset()
        studio.selectModule("status")
        var list = find(studio.inspector, "studioItems")
        expect(list.visible && list === studio.inspector.checklist, "the checklist")
        var names = function() { return list.rows.map(function(r) { return r.name + (r.on ? "+" : "-") }).join() }
        // From the style's own contents (elementLimits' defaults).
        expect(names() === Layout.elementLimits().status.options.items.defaults.text.map(function(n) { return n + "+" })
          .concat(["volume-", "bluetooth-", "keyboard-", "uptime-", "load-", "memory-"]).join(), "rows " + names())
        var row = find(list, "studioItem-keyboard")
        expect(row && row.Accessible.role === Accessible.CheckBox && row.Accessible.name === FoamyI18n.t("studio.item.keyboard")
          && !row.Accessible.checked, "a named check box")
        list.toggle(4)
        expectDraft('{"preset":"foamy","layout":{"status":{"items":["network","battery","keyboard"]}}}')
        expect(find(view, "keyboardStatus").visible, "the layout shows on the canvas")
        // The keyboard: Up and Down walk, Alt moves, Space switches.
        list.forceActiveFocus(Qt.TabFocusReason)
        list.cursor = 2
        expect(list.keyPressed(Qt.Key_Up, Qt.AltModifier) && list.cursor === 1, "Alt+Up moves it")
        expectDraft('{"preset":"foamy","layout":{"status":{"items":["network","keyboard","battery"]}}}')
        list.keyPressed(Qt.Key_Up, Qt.AltModifier)
        list.keyPressed(Qt.Key_Up, Qt.AltModifier)
        expect(list.cursor === 0, "it stops at the top")
        expectDraft('{"preset":"foamy","layout":{"status":{"items":["keyboard","network","battery"]}}}')
        list.keyPressed(Qt.Key_End, Qt.NoModifier)
        expect(list.cursor === 7, "End")
        list.keyPressed(Qt.Key_Space, Qt.NoModifier)
        expect(Draft.same(studio.look.elements.status.items, ["keyboard", "network", "battery", "memory"]), "Space switches memory on")
        list.keyPressed(Qt.Key_Down, Qt.AltModifier)
        expect(Draft.same(studio.look.elements.status.items, ["keyboard", "network", "battery", "memory"]), "the last one shown can't go lower")
        // The grip: the canvas follows the drag, one step on release.
        var steps = studio.history.past.length
        expect(list.dragStart(3) && find(find(list, "studioItem-memory"), "studioItemGrip").visible, "dragging memory by its grip")
        list.dragMove(-2.4 * list.rowHeight)
        expect(list.dragTo === 1 && view.look.elements.status.items[1] === "memory" && studio.look.elements.status.items[3] === "memory",
          "the canvas shows it moved: " + json(view.look.elements.status.items))
        list.dragMove(-9 * list.rowHeight)
        expect(list.dragTo === 0, "held to the items shown: " + list.dragTo)
        list.dragEnd()
        expectDraft('{"preset":"foamy","layout":{"status":{"items":["memory","keyboard","network","battery"]}}}')
        expect(studio.history.past.length === steps + 1 && studio.previewDraft === null && list.cursor === 0, "one undo step")
        expect(!list.dragStart(6), "an item not shown has no place to drag")
        capture("studio-items", function() {
          // Never empty.
          for (var i = 0; i < 4; i++) list.toggle(0)
          expectDraft('{"preset":"foamy","layout":{"status":{"items":["battery"]}}}')
          expect(find(list, "studioItem-battery").last && !find(find(list, "studioItem-battery"), "studioItemGrip").visible, "the last item stays")
          studio.commit(Draft.clearItems(studio.draft))
          expectDraft('{"preset":"foamy"}')
          // A new style starts from its own contents.
          list.toggle(4)
          find(studio.inspector, "studioStyles").picked("pill")
          expectDraft('{"preset":"foamy","layout":{"status":{"style":"pill"}}}')
          find(studio.inspector, "studioStyles").picked("system")
          expect(names().indexOf("uptime+,memory+,load+,battery+,network-") === 0, "the panel's own rows: " + names())
          next()
        })
      } },
    { name: "inspector: the weather's details and place", wait: 0, run: function(next) {
        reset()
        studio.selectModule("weather")
        var details = find(studio.inspector, "studioDetails"), place = find(studio.inspector, "studioLocation")
        expect(details.visible && details.value === "temperature" && place.visible && !place.checked, "temperature only, no place")
        expect(find(studio.inspector, "studioLocationNote").text === FoamyI18n.t("studio.location.note")
          && find(studio.inspector, "studioWeatherSample").text === FoamyI18n.t("studio.weather.sample"), "the privacy notes")
        find(studio.inspector, "studioShown").toggled()
        details.picked("full")
        place.toggled()
        expectDraft('{"preset":"foamy","layout":{"weather":{"hidden":false,"details":"full","location":true}}}')
        expect(find(view, "weatherCondition").text.indexOf(FoamyI18n.t("studio.sample.condition")) !== -1
          && find(view, "weatherLocation").text === FoamyI18n.t("studio.sample.place"), "the sample on the canvas")
        studio.inspector.flickable.contentY = studio.inspector.flickable.contentHeight
        capture("studio-weather", function() {
          place.toggled()
          details.picked("temperature")
          expectDraft('{"preset":"foamy","layout":{"weather":{"hidden":false}}}')
          next()
        })
      } },
    { name: "weather: available from the lock's catalog", wait: 0, run: function(next) {
        reset()
        waitFor(function() { return !studio.sources.catalogChecking && studio.sources.weatherTarget === true }, "the catalog", function() {
          expect(Number(readFile(fake + "/catalog-count").trim()) >= 1, "asked through the fake omarchy-shell")
          var row = find(studio.library, "studioLibrary-weather")
          expect(studio.weatherAvailable && row.enabled && row.detail === FoamyI18n.t("studio.hidden"), "the weather row: " + row.detail)
          // The lock says Foamy Weather isn't there.
          writeFile(fake + "/catalog", '{"version":3,"weather":{"target":false,"state":"unavailable"}}\n')
          studio.sources.checkCatalog()
          waitFor(function() { return !studio.sources.catalogChecking && studio.sources.weatherTarget === false }, "the catalog again", function() {
            expect(!studio.weatherAvailable && !row.enabled && row.detail === FoamyI18n.t("studio.needsWeather")
              && row.Accessible.description.indexOf(FoamyI18n.t("studio.needsWeather")) === 0, "disabled: " + row.detail)
            // Nothing shows it: a drag, Insert, the Shown switch; the keys skip it.
            studio.libraryDragStart("weather")
            expect(studio.libraryDrag === "" && studio.selected === "clock", "no drag from a disabled row")
            studio.selectModule("status")
            studio.library.keyPressed(Qt.Key_Down, Qt.NoModifier)
            expect(studio.selected === "status", "Down stays on the last usable row: " + studio.selected)
            studio.appKey(Qt.Key_BracketRight, Qt.NoModifier, "]")
            expect(studio.selected === "clock", "] skips the weather: " + studio.selected)
            studio.appKey(Qt.Key_BracketLeft, Qt.NoModifier, "[")
            expect(studio.selected === "status", "[ skips it too: " + studio.selected)
            studio.selectModule("weather")
            var shown = find(studio.inspector, "studioShown")
            expect(!shown.enabled && find(studio.inspector, "studioModuleNote").text === FoamyI18n.t("studio.needsWeather.hint"), "the inspector says why")
            shown.toggled()
            studio.library.keyPressed(Qt.Key_Insert, Qt.NoModifier)
            expectDraft('{"preset":"foamy"}')
            capture("studio-needs-weather", function() {
              // A weather already shown can still be selected and hidden.
              studio.commit({ preset: "foamy", layout: { weather: { hidden: false } } })
              expect(row.enabled && row.detail === FoamyI18n.t("studio.needsWeather") && shown.enabled, "a shown weather stays usable")
              shown.toggled()
              expectDraft('{"preset":"foamy"}')
              expect(!shown.enabled && !row.enabled, "and once hidden, can't come back")
              // Only a version 3 catalog that says yes or no counts.
              var sources = studio.sources
              sources.applyCatalog(0, '{"version":2,"elements":[]}')
              sources.applyCatalog(0, 'not json')
              sources.applyCatalog(1, '{"version":3,"weather":{"target":true}}')
              sources.applyCatalog(0, '{"version":3,"weather":{"target":"yes"}}')
              expect(sources.weatherTarget === false, "an older or failed answer keeps what is known")
              writeFile(fake + "/catalog", "fail\n")
              sources.checkCatalog()
              waitFor(function() { return !sources.catalogChecking }, "a lock that doesn't answer", function() {
                expect(sources.weatherTarget === false, "still known")
                writeFile(fake + "/catalog", '{"version":3,"weather":{"target":true,"state":"pending"}}\n')
                sources.checkCatalog()
                waitFor(function() { return !sources.catalogChecking && sources.weatherTarget === true }, "the catalog back", function() {
                  expect(row.enabled, "usable again")
                  next()
                })
              })
            })
          })
        })
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
        // After the hidden weather, which waits in top-start.
        expectDraft('{"preset":"foamy","layout":{"calendar":{"zone":"top-start","order":1,"hidden":false}}}')
        expect(canvas.gesture === null && studio.libraryDrag === "", "the drag is over")
        // Dropped off the canvas: nothing changes.
        studio.libraryDragStart("calendar")
        studio.libraryDragMove(viewToScene(900, 500), Qt.NoModifier)
        studio.libraryDragMove(scenePoint(studio.library, 40, 40), Qt.NoModifier)
        expect(canvas.gesture === null, "left the canvas")
        studio.libraryDragEnd()
        expectDraft('{"preset":"foamy","layout":{"calendar":{"zone":"top-start","order":1,"hidden":false}}}')
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
    { name: "presets: the sidebar's first row opens the menu", wait: 0, run: function(next) {
        reset()
        expect(find(studio, "studioPresetStrip") === null, "no presets strip")
        var row = find(studio.library, "studioPresetButton")
        expect(row && row.visible && row.Accessible.role === Accessible.ButtonMenu, "the preset row")
        expect(row.text === FoamyI18n.t("studio.preset", FoamyI18n.t("studio.preset.foamy")) && row.detail === "", "row text: " + row.text + " / " + row.detail)
        // The first row of the library, above the modules.
        var rowTop = row.mapToItem(studio.library, 0, 0).y
        var clockTop = find(studio.library, "studioLibrary-clock").mapToItem(studio.library, 0, 0).y
        expect(rowTop === 0 && clockTop > rowTop + row.height, "the first row: " + rowTop + ", modules from " + clockTop)
        row.clicked()
        expect(studio.presetMenu.visible && studio.presetMenu.activeFocus, "the row opens the menu")
        var card = find(studio.presetMenu, "studioPresetMenu")
        var rowBottom = row.mapToItem(studio.presetMenu, 0, row.height).y
        expect(card.y >= rowBottom && card.y <= rowBottom + FoamyStyle.gap, "the menu drops from the row: " + card.y + " vs " + rowBottom)
        expect(studio.presetMenu.keyPressed(Qt.Key_Escape) && !studio.presetMenu.visible && row.activeFocus, "Esc closes it, back on the row")
        studio.commit({ preset: "foamy", layout: { clock: { scale: 1.2 } } })
        expect(row.detail === FoamyI18n.t("studio.edited"), "edited shows: " + row.detail)
        row.clicked()
        expect(studio.presetMenu.visible, "open again")
        row.clicked()
        expect(!studio.presetMenu.visible, "the row closes it too")
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
        // Esc on the question puts the keyboard back on the sidebar's preset row.
        studio.requestPreset("island")
        expect(studio.pendingPreset === "island", "it asks again")
        studio.cancelPreset()
        expect(studio.library.presetButton.activeFocus, "the preset row has the keyboard after the question")
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
        // The picker runs under a generous timeout (the helper's own limit
        // is 30 minutes); a helper it had to stop is a failed chooser.
        var pickProcess = null
        for (var p = 0; p < studio.sources.data.length; p++) if (studio.sources.data[p].objectName === "studioPickProcess") pickProcess = studio.sources.data[p]
        expect(pickProcess && pickProcess.command[0] === "timeout" && pickProcess.command.indexOf("1830s") === 2
          && pickProcess.command.indexOf("pick-picture") > 3, "pick-picture under timeout: " + (pickProcess ? JSON.stringify(pickProcess.command) : "missing"))
        studio.sources.applyPick(124, "")
        expect(find(page, "studioPictureProblem").text === FoamyI18n.t("studio.pick.PORTAL_FAILED"), "timed out: " + find(page, "studioPictureProblem").text)
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
    { name: "a file name that looks like markup is shown as text", wait: 0, run: function(next) {
        // As rich text, this name would make Qt decode the PNG in the
        // studio's process and lay it out 900 pixels tall.
        var png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        var name = "/nonexistent/foamy-lock-studio/<img src='data:image/png;base64," + png + "' width='900' height='900'><b>x</b>.png"
        studio.sources.applyPick(0, JSON.stringify({ ok: true, path: name }))
        var shown = find(studio.scenePage, "studioPicturePath")
        expect(shown && shown.text === name, "the name as it is: " + (shown ? shown.text : "missing"))
        expect(shown.textFormat === Text.PlainText && shown.implicitHeight < 60 && shown.lineCount === 1,
          "plain text, one line: " + shown.textFormat + " " + shown.implicitHeight)
        studio.notice = { kind: "warning", text: name }
        var status = find(studio, "studioStatus")
        expect(status.textFormat === Text.PlainText && status.text === name && status.implicitHeight < 120,
          "the status line too: " + status.implicitHeight)
        studio.notice = null
        // Every Text in the window and the lock view on its canvas.
        var rich = []
        var count = 0
        function walk(item) {
          if (!item) return
          // Qt Quick Controls' own placeholder inside the kit's text field
          // shows the field's placeholderText, which Studio never sets from
          // data (it has none today); the lint covers the plugin's own Text.
          if (item.textFormat !== undefined && item.elide !== undefined && String(item).indexOf("QQuickPlaceholderText") !== 0) {
            count++
            if (item.textFormat !== Text.PlainText) {
              var chain = []
              for (var up = item; up && chain.length < 6; up = up.parent) chain.push(String(up).replace(/\(0x[0-9a-f]+\)/, "") + (up.objectName ? "#" + up.objectName : ""))
              rich.push(chain.join(" < ") + ": " + String(item.text).slice(0, 40))
            }
          }
          var children = item.children || []
          for (var i = 0; i < children.length; i++) walk(children[i])
        }
        walk(studio.contentItem || studio)
        walk(view)
        expect(count > 50 && rich.length === 0, count + " Text items, not plain: " + JSON.stringify(rich))
        next()
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
    { name: "a video wallpaper shows its still frame", wait: 0, run: function(next) {
        reset()
        var sources = studio.sources
        var video = test.out + "/missing-wallpaper.mp4"
        // The helper's sandboxed video-probe runs for real (never Omarchy's
        // poster.sh); a video it can't read leaves the theme colour.
        sources.applyWallpaper(0, JSON.stringify({ ok: true, path: video, signature: "1:2:3" }))
        expect(sources.wallpaperIsVideo && sources.wallpaperPath === "" && view.backgroundPath === "", "until the frame is made, the theme colour")
        waitFor(function() { return !sources.posterBusy }, "video-probe", function() {
          expect(sources.wallpaperError === "video" && sources.wallpaperPath === "", "no frame: " + sources.wallpaperError)
          // A frame for another wallpaper is never shown.
          var poster = sources.videoDirectory + "ef".repeat(32) + ".png"
          var reply = JSON.stringify({ ok: true, poster: poster, clip: null })
          sources.applyPoster(0, reply, "/elsewhere.mp4", "1:2:3")
          waitFor(function() { return !sources.posterBusy }, "video-probe again", function() {
            expect(sources.wallpaperPath === "", "a stale frame: " + sources.wallpaperPath)
            // Only a poster in the lock's video cache, from a reply that is ok.
            sources.applyPoster(0, JSON.stringify({ ok: true, poster: test.picture }), video, "1:2:3")
            expect(sources.wallpaperPath === "" && sources.wallpaperError === "video", "a poster elsewhere: " + sources.wallpaperPath)
            sources.applyPoster(1, reply, video, "1:2:3")
            expect(sources.wallpaperPath === "", "a failed probe: " + sources.wallpaperPath)
            sources.applyPoster(0, reply, video, "1:2:3")
            expect(sources.wallpaperError === "" && sources.wallpaperPath === poster && view.backgroundPath === poster,
              "the still frame shows: " + sources.wallpaperPath)
            // Back to the picture wallpaper.
            sources.refreshWallpaper()
            waitFor(function() { return sources.wallpaperPath.indexOf("wallpaper.png") !== -1 && !sources.wallpaperIsVideo },
              "the wallpaper back", next)
          })
        })
      } },
    // A video background: the fake helper answers video-probe and
    // video-convert (fake/foamy-lock-helper; no ffmpeg, no user's video).
    { name: "a video: the card from the probe", wait: 0, run: function(next) {
        reset()
        var sources = studio.sources
        sources.videoHelper = fake + "/foamy-lock-helper"
        writeFile(fake + "/video-mode", "ok\n")
        writeFile(fake + "/convert-mode", "ok\n")
        find(studio.library, "studioSceneBackground").clicked()
        var page = studio.scenePage
        expect(!find(page, "studioVideoCard").visible, "no card without a video")
        expect(find(page, "studioChoosePicture").text === FoamyI18n.t("studio.picture.chooseButton"), "the chooser offers videos")
        test.saved.video = "/home/you/Videos/waves.mp4"
        sources.applyPick(0, JSON.stringify({ ok: true, path: test.saved.video }))
        expectDraft(JSON.stringify({ preset: "foamy", background: { source: "picture", path: test.saved.video } }))
        expect(find(page, "studioVideoCard").visible, "the card shows for a video")
        expect(find(page, "studioPictureProblem").text === "", "a video is no picture problem")
        waitFor(function() { return sources.videoProbe !== null && sources.videoProbeKey === sources.clipKey }, "the probe", function() {
          var request = JSON.parse(readFile(fake + "/video-requests").trim().split("\n").pop().replace(/^video-probe /, ""))
          expect(request.path === test.saved.video && request.width === sources.videoSize[0] && request.height === sources.videoSize[1],
            "probed at the screen's native size: " + json(request))
          expect(page.cardState === "convertible", "convertible: " + page.cardState)
          var facts = [FoamyI18n.t("studio.video.minutes", [4, 12]), FoamyI18n.t("studio.video.size", [3840, 2160]), "HEVC",
            FoamyI18n.t("studio.video.megabytes", FoamyI18n.number(412, 0))].join(" · ")
          expect(find(page, "studioVideoFacts").text === facts && facts.indexOf("%") === -1, "facts: " + find(page, "studioVideoFacts").text)
          var size = sources.videoSize
          expect(find(page, "studioVideoPlan").text === FoamyI18n.t("studio.video.planCut", [60, size[0], size[1], FoamyI18n.number(30, 0)]),
            "what happens: " + find(page, "studioVideoPlan").text)
          expect(find(page, "studioVideoEstimate").text.indexOf(FoamyI18n.t("studio.video.estimate", FoamyI18n.t("studio.video.seconds", 15))) === 0,
            "the estimate: " + find(page, "studioVideoEstimate").text)
          var convert = find(page, "studioVideoConvert")
          expect(convert.visible && convert.enabled && !find(page, "studioVideoCancel").visible, "Convert, nothing running")
          expect(!find(page, "studioMotion").enabled && find(page, "studioMotionNote").text === FoamyI18n.t("studio.motion.needsClip"),
            "no Play before a clip")
          expect(!find(page, "studioPauseOnBattery").visible, "pause on battery only with Play")
          // The canvas shows the poster, unblurred so far (as the lock does).
          expect(view.backgroundPath === sources.videoProbe.poster && !view.backgroundPrepared && find(page, "studioVideoPoster").status !== Image.Error,
            "the poster on the canvas: " + view.backgroundPath)
          expect(sources.pictureError === "" && studio.scenePage.pictureStatus() === "", "no picture job for a video")
          capture("studio-video", next)
        })
      } },
    { name: "a video: converting, with progress and Cancel", wait: 0, run: function(next) {
        var sources = studio.sources
        var page = studio.scenePage
        writeFile(fake + "/convert-mode", "slow\n")
        find(page, "studioVideoConvert").clicked()
        expect(page.cardState === "converting" && find(page, "studioVideoCancel").visible && !find(page, "studioVideoConvert").visible,
          "converting: Cancel instead of Convert")
        waitFor(function() { return sources.convertProgress !== null && sources.convertProgress.frames === 450 }, "progress", function() {
          var track = find(page, "studioVideoProgress")
          var fill = find(page, "studioVideoProgressFill")
          expect(track.visible && near(fill.width, track.width / 4), "a quarter done: " + fill.width + " of " + track.width)
          expect(find(page, "studioVideoProgressText").text === FoamyI18n.t("studio.video.converting", [FoamyI18n.number(450, 0), FoamyI18n.number(1800, 0)]),
            "frames done: " + find(page, "studioVideoProgressText").text)
          // A second request while one runs is turned away by the app.
          expect(!sources.convertVideo(), "one conversion at a time")
          capture("studio-video-converting", function() {
            find(page, "studioVideoCancel").clicked()
            waitFor(function() { return !sources.converting }, "the cancel", function() {
              expect(sources.convertError === "cancelled" && find(page, "studioVideoProblem").text === FoamyI18n.t("studio.video.cancelled"),
                "cancelled: " + sources.convertError)
              expect(page.cardState === "convertible" && sources.clip === "", "nothing kept")
              next()
            })
          })
        })
      } },
    { name: "a video: converted, then Play and Pause on battery", wait: 0, run: function(next) {
        var sources = studio.sources
        var page = studio.scenePage
        writeFile(fake + "/convert-mode", "ok\n")
        find(page, "studioVideoConvert").clicked()
        waitFor(function() { return page.cardState === "ready" }, "the clip", function() {
          var mb = FoamyI18n.t("studio.video.megabytes", FoamyI18n.number(72, 0))
          expect(find(page, "studioVideoReady").text === FoamyI18n.t("studio.video.ready", mb), "ready: " + find(page, "studioVideoReady").text)
          expect(sources.clip.indexOf(sources.videoDirectory) === 0, "the clip in the lock's cache: " + sources.clip)
          var motion = find(page, "studioMotion")
          expect(motion.enabled && find(page, "studioMotionNote").text === FoamyI18n.t("studio.motion.hint"), "Play can be chosen now")
          motion.picked("play")
          expectDraft(JSON.stringify({ preset: "foamy", background: { source: "picture", path: test.saved.video, motion: "play" } }))
          var battery = find(page, "studioPauseOnBattery")
          expect(battery.visible && battery.checked, "pause on battery, on by default")
          battery.toggled()
          expectDraft(JSON.stringify({ preset: "foamy", background: { source: "picture", path: test.saved.video, motion: "play", pauseOnBattery: false } }))
          battery.toggled()
          expectDraft(JSON.stringify({ preset: "foamy", background: { source: "picture", path: test.saved.video, motion: "play" } }))
          // The probe after the conversion found the clip too.
          waitFor(function() { return sources.videoProbe !== null && sources.videoProbe.clip === sources.clip }, "the probe finds the clip", function() {
            capture("studio-video-ready", function() {
              motion.picked("still")
              expectDraft(JSON.stringify({ preset: "foamy", background: { source: "picture", path: test.saved.video } }))
              next()
            })
          })
        })
      } },
    { name: "a video: limits and errors disable Convert with the reason", wait: 0, run: function(next) {
        var sources = studio.sources
        var page = studio.scenePage
        var probeOf = function(mode, path, then) {
          writeFile(fake + "/video-mode", mode + "\n")
          sources.applyPick(0, JSON.stringify({ ok: true, path: path }))
          waitFor(function() { return sources.videoProbe !== null && sources.videoProbeKey === sources.clipKey }, mode, then)
        }
        probeOf("codec", "/home/you/Videos/studio.mov", function() {
          var convert = find(page, "studioVideoConvert")
          expect(page.cardState === "limit" && convert.visible && !convert.enabled, "Convert disabled for a limit")
          expect(find(page, "studioVideoProblem").text === FoamyI18n.t("studio.video.limit.unsupported-codec", "PRORES"),
            "the codec: " + find(page, "studioVideoProblem").text)
          expect(find(page, "studioVideoPlan").text === "" && !find(page, "studioVideoEstimate").visible, "no plan or estimate over a limit")
          probeOf("large", "/home/you/Videos/huge.mkv", function() {
            expect(find(page, "studioVideoProblem").text === FoamyI18n.t("studio.video.limit.input-too-large"), "too large")
            expect(find(page, "studioVideoFacts").text === FoamyI18n.t("studio.video.megabytes", FoamyI18n.number(3000, 0)),
              "only the size: " + find(page, "studioVideoFacts").text)
            expect(!find(page, "studioVideoConvert").enabled, "Convert disabled")
            probeOf("broken", "/home/you/Videos/broken.webm", function() {
              expect(page.cardState === "problem" && find(page, "studioVideoProblem").text === FoamyI18n.t("studio.video.problem.decode-failed"),
                "a broken video: " + find(page, "studioVideoProblem").text)
              expect(!find(page, "studioVideoConvert").enabled && view.backgroundPath === "", "nothing to convert, the theme colour")
              probeOf("ok", "/home/you/Videos/again.mp4", function() {
                writeFile(fake + "/convert-mode", "fail\n")
                find(page, "studioVideoConvert").clicked()
                waitFor(function() { return !sources.converting }, "the failed conversion", function() {
                  expect(find(page, "studioVideoProblem").text === FoamyI18n.t("studio.video.failed.output-too-large"),
                    "a failed conversion: " + find(page, "studioVideoProblem").text)
                  expect(page.cardState === "convertible", "Convert again")
                  next()
                })
              })
            })
          })
        })
      } },
    { name: "a video Omarchy wallpaper gets the same card", wait: 0, run: function(next) {
        reset()
        var sources = studio.sources
        writeFile(fake + "/video-mode", "ok\n")
        find(studio.library, "studioSceneBackground").clicked()
        var page = studio.scenePage
        find(page, "studioSource-omarchy").clicked()
        var video = test.out + "/wallpaper-loop.webm"
        sources.applyWallpaper(0, JSON.stringify({ ok: true, path: video, signature: "4:5:6" }))
        expect(sources.clipSource === video && find(page, "studioVideoCard").visible, "the card for the wallpaper")
        waitFor(function() { return sources.videoProbe !== null && sources.videoProbeKey === sources.clipKey && !sources.posterBusy }, "its probe", function() {
          expect(page.cardState === "convertible" && find(page, "studioVideoConvert").enabled, "it can be converted")
          // Its still is the same probe's poster (the stand-in helper's, never poster.sh).
          expect(sources.wallpaperError === "" && sources.wallpaperPath === sources.videoProbe.poster && sources.wallpaperPath !== "",
            "the wallpaper's still from video-probe: " + sources.wallpaperPath)
          var probes = readFile(fake + "/video-requests").trim().split("\n").filter(function(line) { return line.indexOf(video) !== -1 })
          expect(probes.length >= 2 && probes.every(function(line) { return line.indexOf("video-probe ") === 0 }), "probed: " + json(probes))
          sources.refreshWallpaper()
          waitFor(function() { return sources.wallpaperPath.indexOf("wallpaper.png") !== -1 && !sources.wallpaperIsVideo }, "the wallpaper back", function() {
            expect(!find(page, "studioVideoCard").visible, "no card for a picture wallpaper")
            sources.videoHelper = ""
            next()
          })
        })
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
        var wanted = ["studioPresetButton", "studioPreview", "studioHelp", "studioLibrary-clock", "studioSceneBackground", "studioZonesSwitch",
          "studioSnapSwitch", "studioStates", "studioTipPrevious", "studioTipNext"]
        for (var w = 0; w < wanted.length; w++) expect(names.indexOf(wanted[w]) !== -1, "Tab reaches " + wanted[w] + ": " + json(names))
        expect(stops.indexOf(find(studio, "studioMonitor").triggerItem) !== -1, "Tab reaches the screen dropdown")
        // Disabled buttons are skipped (nothing to apply, undo or reset).
        expect(names.indexOf("studioApply") === -1 && names.indexOf("studioUndo") === -1 && names.indexOf("studioReset") === -1,
          "disabled buttons are skipped")
        ok(stops.length + " tab stops, all named")
        next()
      } },
    { name: "header: icon buttons with names and tooltips", wait: 0, run: function(next) {
        reset()
        var buttons = [
          { id: "studioUndo", name: "studio.undo", keys: "studio.key.undo.keys", icon: "undo-2" },
          { id: "studioRedo", name: "studio.redo", keys: "studio.key.redo.keys", icon: "undo-2", flipped: true },
          { id: "studioReset", name: "studio.reset", icon: "undo-dot" },
          { id: "studioPreview", name: "studio.preview", icon: "eye" },
          { id: "studioHelp", name: "studio.help", keys: "studio.key.help.keys", icon: "circle-help" }
        ]
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i], button = find(studio, b.id)
          var name = FoamyI18n.t(b.name)
          expect(button && button.visible, b.id + " is there")
          expect(button.text === "" && button.width === FoamyStyle.controlHeight && button.height === FoamyStyle.controlHeight, b.id + " is icon-only")
          expect(button.icon === b.icon && button.flipped === (b.flipped === true), b.id + " icon " + button.icon)
          expect(button.Accessible.name === name && button.Accessible.role === Accessible.Button, b.id + " name " + button.Accessible.name)
          var tip = b.keys ? FoamyI18n.t("studio.withKeys", [name, FoamyI18n.t(b.keys)]) : name
          expect(button.tooltipText === tip, b.id + " tooltip " + button.tooltipText)
        }
        var apply = find(studio, "studioApply")
        expect(apply.text === FoamyI18n.t("studio.apply") && apply.kind === "primary" && apply.Accessible.name === apply.text, "Apply stays a labelled primary button")
        // Help opens and closes the shortcuts.
        find(studio, "studioHelp").clicked()
        expect(studio.shortcutsOpen, "help opens the shortcuts")
        find(studio, "studioHelp").clicked()
        expect(!studio.shortcutsOpen, "and closes them")
        // Undo and redo follow the history.
        expect(!find(studio, "studioUndo").enabled && !find(studio, "studioRedo").enabled && !find(studio, "studioReset").enabled, "nothing to undo or reset")
        studio.commit({ preset: "zen" })
        expect(find(studio, "studioUndo").enabled && find(studio, "studioReset").enabled, "an edit enables undo and reset")
        find(studio, "studioUndo").clicked()
        expectDraft('{"preset":"foamy"}')
        expect(find(studio, "studioRedo").enabled, "redo")
        find(studio, "studioRedo").clicked()
        expectDraft('{"preset":"zen"}')
        next()
      } },
    { name: "reset: the question", wait: 0, run: function(next) {
        reset()
        // Saved: zen, dimmed. The draft: corner with a bigger clock.
        studio.savedDraft = { preset: "zen", background: { dim: 0.55 } }
        studio.commit({ preset: "corner", layout: { clock: { scale: 1.2 } } })
        expect(studio.canReset && studio.unapplied && studio.changes > 0, "reset is possible")
        find(studio, "studioReset").clicked()
        var dialog = find(studio, "studioResetDialog")
        expect(studio.resetAsked && dialog.visible && studio.questionOpen, "the question shows")
        expect(dialog.title === FoamyI18n.t("studio.reset.title") && dialog.body === FoamyI18n.t("studio.reset.body", FoamyI18n.t("studio.preset.corner")), "its words")
        expect(find(studio, "studioResetPreset").text === FoamyI18n.t("studio.reset.preset", FoamyI18n.t("studio.preset.corner")), "the preset's choice names it")
        expect(find(studio, "studioResetSaved").activeFocus, "Last saved look has the keyboard")
        expect(!studio.appKey(Qt.Key_Z, Qt.ControlModifier, ""), "keys behind it do nothing")
        capture("studio-reset", next)
      } },
    { name: "reset: last saved look, preset, undo and Esc", wait: 0, run: function(next) {
        find(studio, "studioResetSaved").clicked()
        expect(!studio.resetAsked, "answered")
        expectDraft('{"preset":"zen","background":{"dim":0.55}}')
        expect(!studio.unapplied, "the lock's look again")
        studio.undo()
        expectDraft('{"preset":"corner","layout":{"clock":{"scale":1.2}}}')
        studio.requestReset()
        find(studio, "studioResetPreset").clicked()
        expectDraft('{"preset":"corner"}')
        studio.undo()
        expectDraft('{"preset":"corner","layout":{"clock":{"scale":1.2}}}')
        studio.requestReset()
        expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && !studio.resetAsked, "Esc cancels")
        find(studio, "studioResetCancel").clicked()
        expectDraft('{"preset":"corner","layout":{"clock":{"scale":1.2}}}')
        // The preset without changes, but not the saved look: only that choice.
        studio.commit({ preset: "corner" })
        studio.requestReset()
        expect(!find(studio, "studioResetPreset").enabled && find(studio, "studioResetSaved").enabled, "only the saved look")
        studio.answerReset("cancel")
        // The saved look with changes on its preset: only the preset.
        studio.savedDraft = { preset: "corner", layout: { clock: { scale: 1.2 } } }
        studio.commit({ preset: "corner", layout: { clock: { scale: 1.2 } } })
        studio.requestReset()
        expect(find(studio, "studioResetPreset").enabled && !find(studio, "studioResetSaved").enabled && find(studio, "studioResetPreset").activeFocus,
          "only the preset, with the keyboard")
        studio.answerReset("cancel")
        // Neither: nothing to reset.
        studio.savedDraft = { preset: "corner" }
        studio.commit({ preset: "corner" })
        expect(!studio.canReset && !find(studio, "studioReset").enabled, "nothing to reset")
        studio.requestReset()
        expect(!studio.resetAsked, "and no question")
        next()
      } },
    { name: "screens: the dropdown with native sizes", wait: 0, run: function(next) {
        reset()
        var picker = find(studio, "studioMonitor")
        var labels = picker.options.map(function(o) { return o.label })
        expect(json(picker.options.map(function(o) { return o.value })) === json(studio.monitors.map(function(m) { return m.key })), "every size is an entry")
        expect(labels[labels.length - 2] === FoamyI18n.t("studio.monitor.reference", [1280, 720])
          && labels[labels.length - 1] === FoamyI18n.t("studio.monitor.reference", [1920, 1080]), "the reference sizes last: " + json(labels))
        expect(picker.value === "reference:1920x1080" && picker.currentLabel() === FoamyI18n.t("studio.monitor.reference", [1920, 1080]), "shows the screen shown")
        // A scaled screen (DP-2 at 125 %): the native pixels from Hyprland, the logical size for the canvas.
        var fake = studio.monitorList([{ name: "DP-2", width: 2752, height: 1152 }, { name: "HDMI-A-1", width: 1920, height: 1080 }, { name: "", width: 800, height: 600 }],
          { "DP-2": { width: 3440, height: 1440, scale: 1.25, transform: 0 }, "HDMI-A-1": { width: 1920, height: 1080, scale: 1, transform: 0 } })
        expect(fake[0].label === FoamyI18n.t("studio.monitor.screenScaled", ["DP-2", 3440, 1440, 125]) && fake[0].width === 2752 && fake[0].height === 1152,
          "the scaled screen: " + json(fake[0]))
        expect(fake[1].label === FoamyI18n.t("studio.monitor.screen", ["HDMI-A-1", 1920, 1080]), "an unscaled one: " + fake[1].label)
        expect(fake[2].label === FoamyI18n.t("studio.monitor.screen", [FoamyI18n.t("studio.monitor.unnamed", 3), 800, 600]), "an unnamed one: " + fake[2].label)
        if (FoamyI18n.t("studio.monitor.screenScaled") === "%1 · %2 × %3 · %4 %")
          expect(fake[0].label === "DP-2 · 3440 × 1440 · 125 %", "in words: " + fake[0].label)
        // Outside Hyprland the connected screens show their logical size.
        expect(json(studio.sources.nativeMonitors) === "{}", "no Hyprland here: " + json(studio.sources.nativeMonitors))
        var first = studio.monitors[0]
        expect(!first.reference && first.nativeWidth === first.width, "logical without Hyprland: " + json(first))
        // Picking an entry shows that size (at its logical size).
        picker.select("reference:1280x720")
        expect(studio.monitorKey === "reference:1280x720" && canvas.screenWidth === 1280 && canvas.screenHeight === 720, "picked " + studio.monitorKey)
        picker.select(first.key)
        expect(canvas.screenWidth === first.width && canvas.screenHeight === first.height, "a screen at its logical size")
        picker.select("reference:1920x1080")
        expect(canvas.screenWidth === 1920, "back to 1920")
        next()
      } },
    { name: "the preview states' caption", wait: 0, run: function(next) {
        var states = find(studio, "studioStates")
        var caption = find(states, "segmentedCaption")
        expect(states.caption === FoamyI18n.t("studio.state.caption") && caption && caption.visible && caption.text === states.caption, "the caption")
        // Inside the group, before the first state (on the reading start).
        var at = caption.mapToItem(states, 0, 0)
        expect(at.x >= 0 && at.x + caption.width <= states.width && at.y >= 0 && at.y + caption.height <= states.height, "inside the group: " + json(at))
        var idle = null
        var row = caption.parent
        for (var i = 0; i < row.children.length; i++) if (row.children[i].modelData && row.children[i].modelData.value === "idle") idle = row.children[i]
        var idleAt = idle.mapToItem(states, 0, 0).x
        expect(rtl ? at.x > idleAt : at.x < idleAt, "before Idle: " + at.x + " vs " + idleAt)
        next()
      } },
    { name: "deselect: beside the lock and Esc", wait: 0, run: function(next) {
        reset()
        studio.selectModule("media")
        var r = canvas.stageRect
        // The letterbox: above the image when it is wider than the canvas, else beside it.
        var outside = r.y > 4 ? Qt.point(r.x + r.width / 2, r.y / 2) : Qt.point(r.x / 2, r.y + r.height / 2)
        expect(r.y > 4 || r.x > 4, "a letterbox around the image: " + json(r))
        expect(!canvas.tapOutside(r.x + r.width / 2, r.y + r.height / 2) && studio.selected === "media", "a tap on the image doesn't deselect")
        expect(canvas.tapOutside(outside.x, outside.y), "a tap beside it does")
        expect(studio.selected === "" && studio.page === "module", "nothing selected")
        expect(!studio.inspector.visible && studio.scenePage.visible && studio.scenePage.page === "look", "the look as a whole")
        expect(find(studio.scenePage, "studioScenePageTitle").text === FoamyI18n.t("studio.look"), "titled")
        expect(find(studio.scenePage, "studioSceneBackgroundSection").visible && find(studio.scenePage, "studioSceneGlassSection").visible
          && find(studio.scenePage, "studioDim").visible && find(studio.scenePage, "studioSource-omarchy").visible, "background, glass and dim")
        expect(find(canvas, "studioSelection").visible === false, "no selection drawn")
        // Edits from the look's page are one step each, as on the scene pages.
        find(studio.scenePage, "studioDim").committed(0.5)
        expectDraft('{"preset":"foamy","background":{"dim":0.5}}')
        // Keys with nothing selected change nothing.
        var before = Draft.stable(studio.draft)
        expect(!canvas.keyPressed(Qt.Key_Left, Qt.NoModifier) && !canvas.keyPressed(Qt.Key_Delete, Qt.NoModifier), "the canvas ignores them")
        studio.library.keyPressed(Qt.Key_Delete, Qt.NoModifier)
        expect(Draft.stable(studio.draft) === before && studio.history.past.length === 1, "and the library makes no step")
        capture("studio-look", next)
      } },
    { name: "deselect: Esc", wait: 0, run: function(next) {
        find(studio.library, "studioLibrary-status").clicked()
        expect(studio.selected === "status" && studio.inspector.visible, "a click selects again")
        expect(studio.appKey(Qt.Key_Escape, Qt.NoModifier, "") && studio.selected === "" && studio.scenePage.page === "look", "Esc deselects")
        expect(!studio.appKey(Qt.Key_Escape, Qt.NoModifier, ""), "Esc with nothing selected is left alone")
        // A scene page is still chosen from the library.
        find(studio.library, "studioSceneGlass").clicked()
        expect(studio.scenePage.page === "glass" && !find(studio.scenePage, "studioSceneBackgroundSection").visible, "the glass page")
        canvas.selectRequested("clock")
        expect(studio.selected === "clock" && studio.inspector.visible, "selecting on the canvas")
        next()
      } },
    { name: "tips: pinned to the sidebar's bottom edge", wait: 0, run: function(next) {
        reset()
        var tips = find(studio, "studioTips")
        var pane = tips.parent
        var bottom = tips.mapToItem(null, 0, tips.height).y, paneBottom = pane.mapToItem(null, 0, pane.height).y
        expect(near(bottom, paneBottom, 0.5) && near(tips.width, pane.width, 0.5), "the card's bottom edge is the pane's: " + bottom + " vs " + paneBottom)
        var list = studio.library.flickable
        var listBottom = list.mapToItem(null, 0, list.height).y, tipsTop = tips.mapToItem(null, 0, 0).y
        expect(listBottom <= tipsTop && list.clip, "the list ends above it: " + listBottom + " vs " + tipsTop)
        // Short: the list scrolls, the card stays.
        var shortHeight = Math.max(80, list.contentHeight / 2)
        studio.library.anchors.bottom = undefined
        studio.library.height = shortHeight + list.y
        var lastScene = find(studio.library, "studioSceneGlass")
        lastScene.forceActiveFocus(Qt.TabFocusReason)
        expect(list.contentY > 0 && near(tips.mapToItem(null, 0, tips.height).y, paneBottom, 0.5), "scrolled to the focused row: " + list.contentY)
        find(studio.library, "studioLibrary-clock").forceActiveFocus(Qt.TabFocusReason)
        var clockRow = find(studio.library, "studioLibrary-clock")
        expect(clockRow.mapToItem(list, 0, 0).y >= 0, "and back to the first module: " + list.contentY)
        studio.library.anchors.bottom = tips.top
        canvas.forceActiveFocus()
        next()
      } },
    { name: "tips: one at a time, previous and next, remembered", wait: 0, run: function(next) {
        var tips = find(studio, "studioTips")
        var sources = studio.sources
        // No state file yet: the first tip, Mugshot.
        expect(sources.stateKnown && tips.current === "mugshot" && tips.index === 0, "the first tip: " + tips.current)
        var count = find(tips, "studioTipCount")
        expect(count.text === FoamyI18n.t("studio.tip.count", [FoamyI18n.number(1, 0), FoamyI18n.number(tips.ids.length, 0)]), "count " + count.text)
        var height = tips.height
        find(tips, "studioTipNext").clicked()
        expect(tips.current === "library" && find(tips, "studioTipText").text === FoamyI18n.t("studio.tip.library"), "next: " + tips.current)
        expect(tips.height === height, "the card keeps its height")
        // Previous and next sit under the tip, small and without a surface.
        var previous = find(tips, "studioTipPrevious"), text = find(tips, "studioTipText")
        expect(previous.mapToItem(null, 0, 0).y >= text.mapToItem(null, 0, text.height).y && previous.height === FoamyStyle.actionSize
          && previous.color.a === 0, "ghost buttons under the text")
        find(tips, "studioTipPrevious").clicked()
        find(tips, "studioTipPrevious").clicked()
        expect(tips.current === tips.ids[tips.ids.length - 1], "previous wraps to the last: " + tips.current)
        find(tips, "studioTipNext").clicked()
        find(tips, "studioTipNext").clicked()
        find(tips, "studioTipNext").clicked()
        expect(tips.current === "drag", "next wraps to the start: " + tips.current)
        for (var i = 0; i < tips.ids.length; i++) expect(tips.tipText(tips.ids[i]) !== "" && tips.tipText(tips.ids[i]).indexOf("studio.") !== 0, "words for " + tips.ids[i])
        // The keyboard layout tip came with the status items (R2-3).
        expect(tips.ids.indexOf("keyboard") !== -1 && tips.tipText("keyboard") === FoamyI18n.t("studio.tip.keyboard"), "the keyboard layout tip")
        waitFor(function() { return readFile(sources.statePath).indexOf('"tip":"drag"') !== -1 }, "the state file", function() {
          expect(JSON.parse(readFile(sources.statePath)).version === 1, "versioned")
          // Read back on the next start (the file's text, as loaded).
          sources.applyState('{"version":1,"tip":"keys"}')
          expect(tips.current === "keys", "a remembered tip: " + tips.current)
          sources.applyState('{"version":1,"tip":"../nope"}')
          sources.applyState('not json')
          expect(tips.current === "keys", "a bad state file changes nothing")
          sources.applyState('{"version":1,"tip":"gone"}')
          expect(tips.current === "mugshot", "an unknown tip shows the first")
          capture("studio-tips", next)
        })
      } },
    { name: "tips: Mugshot, absent and present", wait: 0, run: function(next) {
        var tips = find(studio, "studioTips")
        var sources = studio.sources
        var fakeMugshot = test.out + "/bin/mugshot"
        waitFor(function() { return !sources.mugshotChecking }, "the first check", function() {
          // Never the real one here.
          sources.mugshotPath = test.out + "/no-such-mugshot"
          sources.checkMugshot()
          waitFor(function() { return !sources.mugshotChecking }, "the check", function() {
            expect(!sources.mugshotAvailable && find(tips, "studioTipAction") === null && sources.openMugshot === undefined, "no button, nothing to start")
            expect(find(tips, "studioTipText").text === FoamyI18n.t("studio.tip.mugshotMissing"), "the tip says how to install it")
            shellLine.line = "mkdir -p \"$1\" && printf '%s\\n' '#!/bin/bash' 'echo ran > \"$0.ran\"' > \"$2\" && chmod 755 \"$2\""
            shellLine.command = ["bash", "-c", shellLine.line, "fake-mugshot", test.out + "/bin", fakeMugshot]
            shellLine.running = true
            waitFor(function() { return !shellLine.running && readFile(fakeMugshot).indexOf("ran") !== -1 }, "the fake Mugshot", function() {
              sources.mugshotPath = fakeMugshot
              sources.checkMugshot()
              waitFor(function() { return !sources.mugshotChecking }, "the check", function() {
                expect(sources.mugshotAvailable && find(tips, "studioTipText").text === FoamyI18n.t("studio.tip.mugshot"), "installed: the tip names it")
                expect(find(tips, "studioTipAction") === null && readFile(fakeMugshot + ".ran") === "", "words only: nothing to press, nothing started")
                sources.mugshotPath = test.out + "/no-such-mugshot"
                sources.checkMugshot()
                waitFor(function() { return !sources.mugshotChecking }, "the check", next)
              })
            })
          })
        })
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
        expect(status && status.text === "", "nothing to say while the lock screen has the look: " + (status ? status.text : "none"))
        // The canvas moves only while the window can be seen and has the keyboard.
        expect(view.displayAwake === (studio.awake && studio.Window.active), "displayAwake follows the window")
        studio.commit({ preset: "zen" })
        expect(studio.unapplied && status.text === FoamyI18n.t("studio.unsaved") && status.kind === "warning", "an edit warns: " + status.text + " " + status.kind)
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
  ]).concat(userPresetSteps()).concat([
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
