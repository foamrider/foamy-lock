pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "kit"
import "Layout.js" as LockLayout
import "." as Studio
import "Draft.js" as Draft

// Lock Studio's window content (mockup A, "Canvas"): a header (the screen
// shown, undo, redo and reset, the status, preview, help and Apply), the
// library (the preset, modules and scene, with the tips card pinned under
// it) on the reading start, the live canvas in the middle with its preview
// states, switches and problems, and the inspector (a scene page, or the
// look as a whole when nothing is selected) on the reading end.
//
// It owns the draft: `history` (Draft.history) holds the entry being edited
// and its undo steps; every edit goes through commit(). A slider drag shows
// through preview() and commits once. Picking a preset with changes asks
// first (keep them on the new preset, or replace them); either is one
// undo step. Reset (the header) asks whether to go back to the saved look
// or to the preset without changes; either is one undo step too. Keys that
// work everywhere are in appKey(); the canvas, the library and the
// controls handle their own.
//
// Saving (LockSources runs the helper's `studio` subcommands):
// - **On open** the draft on disk is read. One whose look differs from the
//   lock's saved look (shell.json, read as the lock reads it) asks first:
//   continue editing it, or start from the saved look (the draft is
//   deleted). A draft that can't be read is set aside and reported once.
// - **While editing** the draft (its look and undo steps) is written 800 ms
//   after the last edit.
// - **Apply** sends the look to the lock (`studio apply`); the header says
//   how it went. After a save the look is the new saved one and the draft is
//   deleted; anything else keeps both.
// - **Preview full screen** shows the look on the lock's own preview.
// - **Quitting** (Ctrl+Q, or closing the window) with changes the lock
//   doesn't have asks: Apply and quit, Discard (deletes the draft), or
//   Cancel. A pending draft write finishes first.
FocusScope {
  id: studio

  // The window can be seen: the canvas loads its background only then.
  property bool awake: true
  // Drawn backgrounds move and the "system" status reads /proc only while
  // the window also has the keyboard. Quickshell has no signal for another
  // client's session lock, but the lock always takes the keyboard, so this
  // turns them off while the session is locked (and while the lock's
  // preview shows).
  readonly property bool moving: awake && Window.active
  // Everything is saved (or discarded): the app may end now.
  signal quitConfirmed()

  property var history: Draft.history({ preset: LockLayout.DEFAULT_PRESET })
  readonly property var draft: history.present
  readonly property var look: Draft.lookOf(draft)
  // A slider's value while it is dragged (shown, not yet committed).
  property var previewDraft: null
  property string selected: "clock"
  // The inspector pane: "module" (the selection), "background" or "glass".
  property string page: "module"
  property string monitorKey: ""
  readonly property var monitors: monitorList(Quickshell.screens, lockSources.nativeMonitors)
  readonly property var monitor: monitorFor(monitorKey)
  property string previewState: "idle"
  property bool showZones: true
  property bool snapping: true
  property bool shortcutsOpen: false
  // The reset question shows.
  property bool resetAsked: false
  // A module dragged from the library ("" otherwise), and where the
  // pointer is in the window.
  property string libraryDrag: ""
  property point libraryDragPoint: Qt.point(0, 0)
  // The preset waiting for "Keep changes" or "Replace" ("" otherwise).
  property string pendingPreset: ""
  readonly property var keptPreset: pendingPreset ? Draft.presetKeeping(draft, pendingPreset) : null
  readonly property bool rightToLeft: FoamyI18n.rightToLeft
  readonly property alias canvas: lockCanvas
  readonly property alias checker: lockChecker
  readonly property alias sources: lockSources
  readonly property alias library: library
  readonly property alias inspector: inspectorPage
  readonly property alias scenePage: scenePage
  readonly property alias presetMenu: presetMenu
  readonly property var lockSettings: lockSources.settings
  readonly property var problems: lockChecker.problems
  readonly property bool applyBlocked: problems.some(function(problem) { return !problem.reference })
  readonly property int changes: Draft.changeCount(draft)
  readonly property var panes: [library, canvasPane, inspectorPane, header]

  // --- saving state ----------------------------------------------------------
  // The lock's saved look (a sparse entry): from shell.json, and the applied
  // look after an Apply.
  property var savedDraft: ({ preset: LockLayout.DEFAULT_PRESET })
  // "loading" until the draft on disk and shell.json are read, "ask" while
  // the restore question shows, then "ready" (only then is the draft
  // written).
  property string session: "loading"
  property var draftReport: null
  // The draft found on disk while "ask" shows it.
  property var restoreReport: null
  readonly property bool unapplied: !Draft.sameLook(draft, savedDraft)
  // The header's message: { kind: "busy" | "ok" | "info" | "warning" |
  // "error", text }, or null. An edit clears it.
  property var notice: null
  property bool quitAsked: false
  property bool quitAfterApply: false
  property bool quitting: false
  readonly property bool canApply: session === "ready" && unapplied && !applyBlocked && !lockChecker.pending
    && !lockSources.applying && !quitting
  readonly property bool canPreview: session === "ready" && !lockSources.previewing && !quitting
  // Reset can go back to the saved look, or to the preset without changes.
  readonly property bool canReset: session === "ready" && !quitting && (unapplied || changes > 0)
  readonly property bool questionOpen: pendingPreset !== "" || session === "ask" || quitAsked || resetAsked

  LayoutMirroring.enabled: rightToLeft
  LayoutMirroring.childrenInherit: true

  Keys.onPressed: function(event) { if (studio.appKey(event.key, event.modifiers, event.text)) event.accepted = true }

  function commit(next) {
    previewDraft = null
    history = Draft.push(history, next)
  }

  // Any change to the draft or its history (edits, undo, redo, presets):
  // written to disk a moment later; the header's last message is out of date.
  onHistoryChanged: {
    if (session !== "ready") return
    notice = null
    if (!quitting) draftTimer.restart()
  }

  // --- the draft on disk ---------------------------------------------------------

  // Both the draft and the saved look are known: start, or ask.
  function startSession() {
    if (session !== "loading" || !draftReport || !lockSources.configKnown) return
    var report = draftReport
    if (report.status === "loaded" && !Draft.sameLook(report.history.present, savedDraft)) {
      // Shown behind the question, as "Continue editing" keeps it.
      history = report.history
      restoreReport = report
      session = "ask"
      restoreContinue.forceActiveFocus(Qt.PopupFocusReason)
      return
    }
    // The same look as the lock's keeps its undo steps; nothing to ask.
    history = report.status === "loaded" ? report.history : Draft.history(savedDraft)
    session = "ready"
    if (report.status === "corrupt") notice = { kind: "warning", text: FoamyI18n.t("studio.draft.corrupt") }
    else if (report.status === "failed") notice = { kind: "warning", text: FoamyI18n.t("studio.draft.loadFailed", codeText(report.code)) }
  }

  // The answer: keep editing the draft, or start from the saved look.
  function answerRestore(keep) {
    if (session !== "ask") return
    if (!keep) {
      history = Draft.history(savedDraft)
      lockSources.clearDraft()
    }
    restoreReport = null
    session = "ready"
    lockCanvas.forceActiveFocus(Qt.OtherFocusReason)
  }

  function writeDraft() {
    draftTimer.stop()
    if (session !== "ready") return
    // Nothing to keep: the lock's look, with no steps to undo.
    if (!unapplied && !Draft.canUndo(history)) return
    lockSources.saveDraft(history)
  }

  function codeText(code) {
    return code === "helper-unavailable" ? FoamyI18n.t("studio.helperUnavailable") : code
  }

  function savedAtText(savedAt) {
    var at = new Date(savedAt)
    return isNaN(at.getTime()) ? "" : Qt.locale(FoamyI18n.formatLocale).toString(at, Locale.ShortFormat)
  }

  // --- Apply and Preview -----------------------------------------------------------

  function apply() {
    if (!canApply) return
    writeDraft()
    if (lockSources.applyLook(draft)) notice = { kind: "busy", text: FoamyI18n.t("studio.applying") }
  }

  function previewFull() {
    if (!canPreview) return
    if (lockSources.previewLook(draft)) notice = { kind: "busy", text: FoamyI18n.t("studio.previewing") }
  }

  // One result in words. `action` is "apply" or "preview".
  function resultText(report, action) {
    switch (report.result) {
    case "ok": return FoamyI18n.t(action === "apply" ? "studio.applied" : "studio.previewShown")
    case "unchanged": return FoamyI18n.t("studio.applied")
    case "invalid": return FoamyI18n.t("studio.result.invalid", report.reason)
    case "locked": return FoamyI18n.t("studio.result.locked." + action)
    case "not-responding":
      return FoamyI18n.t(action === "apply" && !report.confirmed ? "studio.result.not-responding.apply" : "studio.result.not-responding")
    case "helper-unavailable": return FoamyI18n.t("studio.helperUnavailable")
    case "error": return FoamyI18n.t("studio.result.error", report.code)
    case "invalid-json": case "unsupported": case "no-entry": case "unexpected": case "not-ready": case "not-running":
    case "target-not-found": case "function-not-found": case "no-omarchy-shell": case "failed":
      return FoamyI18n.t("studio.result." + report.result)
    }
    return FoamyI18n.t("studio.result.unexpected")
  }

  function resultKind(report) {
    if (report.saved || report.result === "ok") return "ok"
    if (report.result === "not-responding" || report.result === "not-ready" || report.result === "locked") return "warning"
    return "error"
  }

  // --- quitting ----------------------------------------------------------------------

  // Ctrl+Q or the window closed: ask when the lock doesn't have the look.
  function requestQuit() {
    if (quitting) return
    if (session === "ready" && unapplied) {
      quitAsked = true
      quitApply.enabled ? quitApply.forceActiveFocus(Qt.PopupFocusReason) : quitCancel.forceActiveFocus(Qt.PopupFocusReason)
      return
    }
    finishQuit()
  }

  // "apply", "discard" or "cancel".
  function answerQuit(answer) {
    if (answer === "cancel") {
      quitAsked = false
      quitAfterApply = false
      lockCanvas.forceActiveFocus(Qt.OtherFocusReason)
    } else if (answer === "apply") {
      if (!canApply) return
      quitAfterApply = true
      apply()
    } else if (answer === "discard") {
      quitAsked = false
      draftTimer.stop()
      lockSources.clearDraft()
      finishQuit()
    }
  }

  // Quit once the draft file is written (or deleted); at most 3 s.
  function finishQuit() {
    if (quitting) return
    if (draftTimer.running) writeDraft()
    quitting = true
    quitAsked = false
    if (lockSources.draftIdle) endNow()
    else quitDeadline.start()
  }

  // Once.
  property bool quitDone: false
  function endNow() {
    if (quitDone) return
    quitDone = true
    quitDeadline.stop()
    quitConfirmed()
  }

  Timer {
    id: draftTimer
    interval: 800
    onTriggered: studio.writeDraft()
  }

  Timer {
    id: quitDeadline
    interval: 3000
    onTriggered: studio.endNow()
  }

  // shell.json can take a moment, or never answer: don't wait forever.
  Timer {
    interval: 3000
    running: studio.session === "loading"
    onTriggered: {
      lockSources.configKnown = true
      if (!studio.draftReport) studio.draftReport = { status: "failed", code: "FAILED" }
      studio.startSession()
    }
  }

  Connections {
    target: lockSources
    function onConfigEntryChanged() {
      var saved = Draft.savedEntry(lockSources.configEntry)
      if (saved && !Draft.same(saved, studio.savedDraft)) studio.savedDraft = saved
    }
    function onConfigKnownChanged() { studio.startSession() }
    function onDraftDone(op, result) {
      if (op === "draft-load") {
        if (studio.session === "loading" && !studio.draftReport) {
          studio.draftReport = result
          studio.startSession()
        }
      } else if (result && !studio.quitting) {
        studio.notice = { kind: "warning", text: FoamyI18n.t(op === "draft-save" ? "studio.draft.saveFailed" : "studio.draft.clearFailed", studio.codeText(result)) }
      }
      if (studio.quitting && lockSources.draftIdle) studio.endNow()
    }
    function onApplied(report, entry) {
      var finish = studio.quitAfterApply
      studio.quitAfterApply = false
      studio.quitAsked = false
      if (report.saved && entry) {
        studio.savedDraft = Draft.entry(Draft.lookOf(entry))
        // Edits made while it was applying stay in the draft.
        if (Draft.sameLook(studio.draft, entry)) {
          draftTimer.stop()
          lockSources.clearDraft()
        } else studio.writeDraft()
      }
      studio.notice = { kind: studio.resultKind(report), text: studio.resultText(report, "apply") }
      if (report.saved && finish) studio.finishQuit()
    }
    function onPreviewed(report) {
      studio.notice = { kind: studio.resultKind(report), text: studio.resultText(report, "preview") }
    }
  }
  function preview(next) { previewDraft = Draft.same(next, draft) ? null : next }
  function undo() {
    previewDraft = null
    history = Draft.undo(history)
  }
  function redo() {
    previewDraft = null
    history = Draft.redo(history)
  }

  function selectModule(name) {
    if (!name) return
    selected = name
    page = "module"
  }

  // Nothing selected: the inspector shows the look as a whole.
  function deselect() {
    selected = ""
    page = "module"
  }

  function togglePresetMenu() {
    if (presetMenu.visible) presetMenu.close()
    else presetMenu.open()
  }

  // --- reset ----------------------------------------------------------------------

  function requestReset() {
    if (!canReset || questionOpen) return
    resetAsked = true
    resetSaved.enabled ? resetSaved.forceActiveFocus(Qt.PopupFocusReason) : resetPreset.forceActiveFocus(Qt.PopupFocusReason)
  }

  // "saved" (the look the lock has), "preset" (the draft's preset without
  // changes) or "cancel". Either choice is one undo step.
  function answerReset(answer) {
    if (!resetAsked) return
    resetAsked = false
    if (answer === "saved" && unapplied) commit(Draft.entry(Draft.lookOf(savedDraft)))
    else if (answer === "preset" && changes > 0) commit(Draft.setPreset(draft, draft.preset))
    canReset ? resetButton.forceActiveFocus(Qt.OtherFocusReason) : lockCanvas.forceActiveFocus(Qt.OtherFocusReason)
  }

  // A preset picked (menu): at once without changes, else ask.
  function requestPreset(name) {
    presetMenu.close()
    if (LockLayout.SELECTABLE_PRESETS.indexOf(name) === -1) return
    if (changes === 0) {
      commit(Draft.setPreset(draft, name))
      return
    }
    pendingPreset = name
    keepButton.forceActiveFocus(Qt.PopupFocusReason)
  }

  // The answer: keep the changes on the new preset, or replace them.
  function answerPreset(keep) {
    var name = pendingPreset
    pendingPreset = ""
    if (!name) return
    var next = keep ? Draft.presetKeeping(draft, name) : Draft.setPreset(draft, name)
    if (next) commit(next)
    library.presetButton.forceActiveFocus(Qt.OtherFocusReason)
  }

  function cancelPreset() {
    pendingPreset = ""
    library.presetButton.forceActiveFocus(Qt.OtherFocusReason)
  }

  // --- dragging from the library onto the canvas ---------------------------

  function libraryDragStart(name) {
    selectModule(name)
    libraryDrag = name
  }

  // The pointer is at `scene` (window pixels): over the canvas the module
  // follows it with snapping; elsewhere the canvas shows nothing new.
  function libraryDragMove(scene, modifiers) {
    if (!libraryDrag) return
    libraryDragPoint = scene
    var p = lockCanvas.view.mapFromItem(null, scene.x, scene.y)
    var inside = p.x >= 0 && p.y >= 0 && p.x <= lockCanvas.screenWidth && p.y <= lockCanvas.screenHeight
    var g = lockCanvas.gesture
    if (inside && !(g && g.insert)) lockCanvas.beginInsert(libraryDrag, p)
    else if (inside) lockCanvas.moveInsert(p, modifiers)
    else if (g && g.insert) lockCanvas.cancelGesture()
  }

  // Released: over the canvas the module is shown (or moved) there.
  function libraryDragEnd() {
    var g = lockCanvas.gesture
    if (g && g.insert) lockCanvas.finishGesture()
    libraryDrag = ""
  }

  // The connected screens, labelled with their native size (and scale)
  // from Hyprland (`natives`, LockSources.nativeMonitors), then the
  // reference sizes. `width` and `height` stay logical: the canvas and
  // the checker lay out at the size the lock does.
  function monitorList(screens, natives) {
    var screenList = []
    for (var i = 0; i < screens.length; i++) screenList.push({ name: screens[i].name, width: screens[i].width, height: screens[i].height })
    return Draft.monitorEntries(screenList, natives || {}).map(function(m) {
      if (m.reference) {
        m.label = FoamyI18n.t("studio.monitor.reference", [m.width, m.height])
        return m
      }
      // A screen without a name (a virtual one) goes by its number.
      if (!m.name) m.name = FoamyI18n.t("studio.monitor.unnamed", m.index + 1)
      var percent = Draft.scalePercent(m.scale)
      m.label = percent ? FoamyI18n.t("studio.monitor.screenScaled", [m.name, m.nativeWidth, m.nativeHeight, percent])
        : FoamyI18n.t("studio.monitor.screen", [m.name, m.nativeWidth, m.nativeHeight])
      return m
    })
  }

  function monitorFor(key) {
    for (var i = 0; i < monitors.length; i++) if (monitors[i].key === key) return monitors[i]
    return monitors[0]
  }

  function moduleLabel(name) { return FoamyI18n.t("studio.module." + name) }
  function zoneLabel(zone) { return FoamyI18n.t("studio.zone." + zone) }
  function styleLabel(style) { return FoamyI18n.t("studio.style." + style) }
  function presetLabel(name) { return FoamyI18n.t("studio.preset." + name) }
  function percent(value) { return FoamyI18n.t("studio.percent", Math.round(value * 100)) }

  function selectionText(name) {
    var item = look.elements[name]
    if (!item) return ""
    return FoamyI18n.t("studio.tag", [moduleLabel(name), styleLabel(item.style), Math.round(Draft.elementValue(item, "scale") * 100)])
  }

  // One problem in words: what, and on which screen.
  function problemText(problem) {
    var where = problem.reference ? FoamyI18n.t("studio.problem.reference", problem.label) : problem.label
    var names = problem.names || []
    switch (problem.code) {
    case "password-overlap":
      return names.length > 1 ? FoamyI18n.t("studio.problem.password-overlap", [moduleLabel(names[1]), where])
        : FoamyI18n.t("studio.problem.password-covered", where)
    case "element-offscreen":
      return FoamyI18n.t("studio.problem.element-offscreen", [moduleLabel(names[0] || ""), where])
    case "element-overlap":
      return FoamyI18n.t("studio.problem.element-overlap", [moduleLabel(names[0] || ""), moduleLabel(names[1] || ""), where])
    case "password-offscreen":
    case "password-high":
    case "password-missing":
      return FoamyI18n.t("studio.problem." + problem.code, where)
    }
    return FoamyI18n.t("studio.problem.other", [problem.code, where])
  }

  // The modules to outline on the screen shown.
  function problemNamesFor(key) {
    for (var i = 0; i < problems.length; i++) if (problems[i].key === key) return problems[i].names
    return []
  }

  // F6 and Shift+F6: the pane after (or before) the one with the focus.
  function focusPane(step) {
    var current = 0
    for (var i = 0; i < panes.length; i++) if (panes[i].activeFocus) current = i
    var next = panes[((current + step) % panes.length + panes.length) % panes.length]
    next.forceActiveFocus(Qt.TabFocusReason)
  }

  // Keys anywhere in the window; true when handled.
  function appKey(key, modifiers, text) {
    var ctrl = (modifiers & Qt.ControlModifier) !== 0
    var shift = (modifiers & Qt.ShiftModifier) !== 0
    if (ctrl && key === Qt.Key_Q) {
      if (!quitAsked) requestQuit()
      return true
    }
    if (key === Qt.Key_Escape && quitAsked) {
      answerQuit("cancel")
      return true
    }
    // Esc keeps the draft: nothing is lost.
    if (key === Qt.Key_Escape && session === "ask") {
      answerRestore(true)
      return true
    }
    if (key === Qt.Key_Escape && pendingPreset) {
      cancelPreset()
      return true
    }
    if (key === Qt.Key_Escape && resetAsked) {
      answerReset("cancel")
      return true
    }
    // A question is open: only its own buttons and Esc.
    if (questionOpen) return false
    if (ctrl && key === Qt.Key_Z) {
      if (shift) redo()
      else undo()
      return true
    }
    if (ctrl && key === Qt.Key_Y) {
      redo()
      return true
    }
    if (key === Qt.Key_F6) {
      focusPane(shift ? -1 : 1)
      return true
    }
    if (key === Qt.Key_Escape && shortcutsOpen) {
      shortcutsOpen = false
      return true
    }
    // Esc with nothing else to close: the look as a whole.
    if (key === Qt.Key_Escape && selected !== "") {
      deselect()
      return true
    }
    if (ctrl) return false
    if (text === "?" || key === Qt.Key_Question) {
      shortcutsOpen = !shortcutsOpen
      return true
    }
    if (key === Qt.Key_BracketLeft || key === Qt.Key_BracketRight) {
      selectModule(Draft.neighbourModule(selected, key === Qt.Key_BracketLeft ? -1 : 1))
      return true
    }
    return false
  }

  Component.onCompleted: {
    lockCanvas.forceActiveFocus()
    lockSources.loadDraft()
  }

  // A chosen picture becomes the background in one step; a file the lock
  // can't use is reported.
  Connections {
    target: lockSources
    function onPicked(path) {
      var next = Draft.setPicture(studio.draft, path)
      if (Draft.same(next, studio.draft) && studio.look.background.path !== path) lockSources.pickError = "UNSUPPORTED"
      else studio.commit(next)
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0
    // A question is modal: nothing behind it takes the pointer or the keys.
    enabled: !studio.questionOpen

    // --- header -------------------------------------------------------------
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: 52
      color: FoamyPalette.menuFill

      FocusScope {
        id: header
        anchors.fill: parent
        Accessible.role: Accessible.ToolBar
        Accessible.name: FoamyI18n.t("studio.toolbar")

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: FoamyStyle.gapLarge
          anchors.rightMargin: FoamyStyle.gapLarge
          spacing: FoamyStyle.gap

          Text {
            text: FoamyI18n.t("studio.title")
            color: FoamyPalette.text
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.title
            font.weight: Font.DemiBold
            Layout.rightMargin: FoamyStyle.gap
            Accessible.role: Accessible.Heading
            Accessible.name: text
          }

          // The screen shown: its native size (and scale), then the
          // reference sizes. The canvas lays out at the logical size.
          FoamyDropdown {
            id: monitorPicker
            objectName: "studioMonitor"
            Layout.preferredWidth: 248
            label: FoamyI18n.t("studio.monitor")
            showLabel: false
            value: studio.monitor.key
            options: studio.monitors.map(function(m) { return { value: m.key, label: m.label } })
            onChanged: function(value) { studio.monitorKey = value }
            Component.onCompleted: triggerItem.focus = true
          }

          IconButton {
            objectName: "studioUndo"
            Layout.leftMargin: FoamyStyle.gap
            icon: "undo-2"
            name: FoamyI18n.t("studio.undo")
            keys: FoamyI18n.t("studio.key.undo.keys")
            enabled: Draft.canUndo(studio.history)
            onClicked: studio.undo()
          }
          IconButton {
            objectName: "studioRedo"
            icon: "undo-2"
            flipped: true
            name: FoamyI18n.t("studio.redo")
            keys: FoamyI18n.t("studio.key.redo.keys")
            enabled: Draft.canRedo(studio.history)
            onClicked: studio.redo()
          }
          // The kit has no rotate-ccw yet: undo-dot ("back to a mark").
          IconButton {
            id: resetButton
            objectName: "studioReset"
            icon: "undo-dot"
            name: FoamyI18n.t("studio.reset")
            enabled: studio.canReset
            onClicked: studio.requestReset()
          }

          // How the last Apply or Preview went, else whether the lock has
          // the look. Two lines at most; the full text is its name.
          Text {
            id: statusText
            objectName: "studioStatus"
            readonly property string kind: studio.notice ? studio.notice.kind : studio.unapplied ? "info" : "ok"
            Layout.fillWidth: true
            Layout.leftMargin: FoamyStyle.gap
            text: studio.notice ? studio.notice.text
              : studio.session !== "ready" ? ""
              : studio.unapplied ? FoamyI18n.t("studio.unapplied") : FoamyI18n.t("studio.matchesLock")
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: kind === "error" ? FoamyPalette.error : kind === "warning" ? FoamyPalette.warning
              : kind === "ok" && studio.notice ? FoamyPalette.success : FoamyPalette.mutedText
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.bodySmall
            font.weight: studio.notice && kind !== "busy" ? Font.DemiBold : Font.Normal
            Accessible.role: kind === "error" || kind === "warning" ? Accessible.AlertMessage : Accessible.StaticText
            Accessible.name: text
          }

          IconButton {
            id: previewButton
            objectName: "studioPreview"
            icon: "eye"
            name: FoamyI18n.t("studio.preview")
            enabled: studio.canPreview
            Accessible.description: FoamyI18n.t("studio.previewHint")
            onClicked: studio.previewFull()
          }
          IconButton {
            objectName: "studioHelp"
            icon: "circle-help"
            name: FoamyI18n.t("studio.help")
            keys: FoamyI18n.t("studio.key.help.keys")
            onClicked: studio.shortcutsOpen = !studio.shortcutsOpen
          }
          FoamyButton {
            id: applyButton
            objectName: "studioApply"
            Layout.leftMargin: FoamyStyle.gap
            kind: "primary"
            focusable: true
            text: lockSources.applying ? FoamyI18n.t("studio.applying") : FoamyI18n.t("studio.apply")
            enabled: studio.canApply
            Accessible.description: studio.applyBlocked ? FoamyI18n.t("studio.applyBlocked")
              : !studio.unapplied ? FoamyI18n.t("studio.matchesLock") : ""
            onClicked: studio.apply()
          }
        }
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: FoamyPalette.divider
      }
    }

    // --- body ---------------------------------------------------------------
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 0

      // The library: modules and scene.
      Rectangle {
        id: libraryPane
        Layout.preferredWidth: 224
        Layout.fillHeight: true
        color: FoamyPalette.menuFill

        Studio.Library {
          id: library
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: tips.top
          anchors.margins: FoamyStyle.gapLarge
          app: studio
          dropTarget: lockCanvas.hiding
        }

        // Pinned to the pane's bottom edge, whatever the list holds.
        Studio.Tips {
          id: tips
          objectName: "studioTips"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          sources: lockSources
        }

        Rectangle {
          anchors.right: parent.right
          width: 1
          height: parent.height
          color: FoamyPalette.divider
        }
      }

      // The canvas column.
      FocusScope {
        id: canvasPane
        Layout.fillWidth: true
        Layout.fillHeight: true

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: FoamyStyle.gapLarge
          spacing: FoamyStyle.gap

          RowLayout {
            id: toolbar
            Layout.fillWidth: true
            spacing: FoamyStyle.gap

            Segmented {
              objectName: "studioStates"
              name: FoamyI18n.t("studio.state")
              caption: FoamyI18n.t("studio.state.caption")
              options: [
                { value: "idle", label: FoamyI18n.t("studio.state.idle") },
                { value: "typing", label: FoamyI18n.t("studio.state.typing") },
                { value: "wrong", label: FoamyI18n.t("studio.state.wrong") },
                { value: "noMedia", label: FoamyI18n.t("studio.state.noMedia") }
              ]
              value: studio.previewState
              onPicked: function(value) { studio.previewState = value }
            }
            Item { Layout.fillWidth: true }
            StudioToggle {
              objectName: "studioZonesSwitch"
              text: FoamyI18n.t("studio.zones")
              checked: studio.showZones
              onToggled: studio.showZones = !studio.showZones
            }
            StudioToggle {
              objectName: "studioSnapSwitch"
              text: FoamyI18n.t("studio.snap")
              checked: studio.snapping
              onToggled: studio.snapping = !studio.snapping
              Layout.leftMargin: FoamyStyle.gapLarge
            }
          }

          Studio.Canvas {
            id: lockCanvas
            Layout.fillWidth: true
            Layout.fillHeight: true
            focus: true
            draft: studio.previewDraft || studio.draft
            selected: studio.selected
            screenWidth: studio.monitor.width
            screenHeight: studio.monitor.height
            previewState: studio.previewState
            showZones: studio.showZones
            snapping: studio.snapping
            awake: studio.awake
            moving: studio.moving
            problemNames: studio.problemNamesFor(studio.monitor.key)
            selectionText: studio.selectionText(studio.selected)
            backgroundPath: lockSources.backgroundPath
            backgroundPrepared: lockSources.backgroundPrepared
            backgroundVersion: lockSources.backgroundVersion
            lockSettings: studio.lockSettings
            hideArea: libraryPane
            onEdited: function(next) { studio.commit(next) }
            onSelectRequested: function(name) { studio.selectModule(name) }
            onDeselectRequested: studio.deselect()
          }

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: FoamyI18n.t("studio.shownAt", [studio.monitor.width, studio.monitor.height, Math.round(lockCanvas.zoom * 100)])
              horizontalAlignment: Text.AlignLeft
              color: FoamyPalette.mutedText
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              text: FoamyI18n.t("studio.hint")
              color: FoamyPalette.mutedText
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.bodySmall
            }
          }

          // Problems, worst first: a connected screen blocks Apply; a
          // reference size only warns.
          Rectangle {
            id: problemBar
            objectName: "studioProblems"
            Layout.fillWidth: true
            visible: studio.problems.length > 0
            implicitHeight: problemColumn.implicitHeight + 2 * FoamyStyle.gap
            radius: FoamyStyle.radiusSmall
            color: FoamyPalette.noteFill
            border.width: FoamyStyle.borderWidth
            border.color: studio.applyBlocked ? FoamyPalette.error : FoamyPalette.warning
            Accessible.role: Accessible.AlertMessage
            Accessible.name: problemColumn.summary

            Column {
              id: problemColumn
              readonly property var sorted: studio.problems.slice().sort(function(a, b) { return (a.reference ? 1 : 0) - (b.reference ? 1 : 0) })
              readonly property string summary: sorted.map(function(p) { return studio.problemText(p) }).join("\n")
              x: FoamyStyle.gapLarge
              y: FoamyStyle.gap
              width: parent.width - 2 * FoamyStyle.gapLarge
              spacing: FoamyStyle.gapSmall
              Repeater {
                model: problemColumn.sorted.slice(0, 3)
                Text {
                  required property var modelData
                  width: problemColumn.width
                  text: studio.problemText(modelData)
                  horizontalAlignment: Text.AlignLeft
                  wrapMode: Text.Wrap
                  color: modelData.reference ? FoamyPalette.onSurface(FoamyPalette.warning) : FoamyPalette.onSurface(FoamyPalette.error)
                  font.family: FoamyStyle.fontFamily
                  font.pixelSize: FoamyStyle.font.bodySmall
                }
              }
              Text {
                visible: problemColumn.sorted.length > 3
                width: problemColumn.width
                horizontalAlignment: Text.AlignLeft
                text: FoamyI18n.tn("studio.problem.more", problemColumn.sorted.length - 3)
                color: FoamyPalette.mutedText
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.bodySmall
              }
            }
          }
        }
      }

      // The inspector, or the scene page chosen in the library (or the
      // look as a whole when nothing is selected).
      Rectangle {
        Layout.preferredWidth: 276
        Layout.fillHeight: true
        color: FoamyPalette.menuFill

        Rectangle {
          anchors.left: parent.left
          width: 1
          height: parent.height
          color: FoamyPalette.divider
        }

        FocusScope {
          id: inspectorPane
          anchors.fill: parent
          anchors.margins: FoamyStyle.gapLarge

          Studio.Inspector {
            id: inspectorPage
            anchors.fill: parent
            visible: studio.page === "module" && studio.selected !== ""
            focus: visible
            app: studio
          }
          Studio.ScenePage {
            id: scenePage
            anchors.fill: parent
            visible: !inspectorPage.visible
            focus: visible
            app: studio
            page: studio.page === "glass" ? "glass" : studio.page === "background" ? "background" : "look"
          }
        }
      }
    }
  }

  // The checker views (never shown).
  Checker {
    id: lockChecker
    look: studio.look
    sizes: studio.monitors
    settings: studio.lockSettings
  }

  // The wallpaper, the lock's settings and the picture (never shown).
  LockSources {
    id: lockSources
    look: studio.look
    screenWidth: studio.monitor.width
    screenHeight: studio.monitor.height
    active: studio.awake
  }

  // The module being dragged from the library, until it is over the canvas.
  Rectangle {
    objectName: "studioDragGhost"
    visible: studio.libraryDrag !== "" && !(lockCanvas.gesture && lockCanvas.gesture.insert)
    x: studio.libraryDragPoint.x + 12
    y: studio.libraryDragPoint.y + 8
    z: 15
    width: ghostLabel.implicitWidth + 2 * FoamyStyle.gap
    height: ghostLabel.implicitHeight + FoamyStyle.gapSmall * 2
    radius: FoamyStyle.radiusSmall
    color: FoamyPalette.accent
    Text {
      id: ghostLabel
      anchors.centerIn: parent
      text: studio.libraryDrag ? studio.moduleLabel(studio.libraryDrag) : ""
      color: FoamyPalette.onAccent
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      font.weight: Font.DemiBold
    }
  }

  Studio.PresetMenu {
    id: presetMenu
    anchorItem: library.presetButton
    current: studio.draft.preset
    onPicked: function(name) { studio.requestPreset(name) }
    onClosed: library.presetButton.forceActiveFocus(Qt.OtherFocusReason)
  }

  // A question over the window: a title, a body and its buttons (declared
  // inside it, after a spacer, so they sit on the reading end). Clicking
  // outside the card dismisses it; Esc does too (appKey()).
  component Question: Rectangle {
    id: question
    property string title: ""
    property string body: ""
    default property alias buttons: buttonRow.data
    signal dismissed()

    anchors.fill: parent
    color: Qt.alpha(FoamyPalette.background, 0.72)
    z: 30

    MouseArea {
      anchors.fill: parent
      onClicked: question.dismissed()
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - 2 * FoamyStyle.padding, 460)
      height: questionColumn.implicitHeight + 2 * FoamyStyle.padding
      radius: FoamyStyle.radius
      color: FoamyPalette.background
      border.width: FoamyStyle.borderWidth
      border.color: FoamyPalette.border
      Accessible.role: Accessible.Dialog
      Accessible.name: question.title
      Accessible.description: question.body

      MouseArea { anchors.fill: parent }

      Column {
        id: questionColumn
        x: FoamyStyle.padding
        y: FoamyStyle.padding
        width: parent.width - 2 * FoamyStyle.padding
        spacing: FoamyStyle.gap

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignLeft
          text: question.title
          wrapMode: Text.Wrap
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
          Accessible.role: Accessible.Heading
          Accessible.name: text
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignLeft
          text: question.body
          wrapMode: Text.Wrap
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
        }
        RowLayout {
          id: buttonRow
          width: parent.width
          spacing: FoamyStyle.gap
          Item { Layout.fillWidth: true }
        }
      }
    }
  }

  // "Keep changes?" before a preset replaces the draft's changes.
  Question {
    id: presetDialog
    objectName: "studioPresetDialog"
    visible: studio.pendingPreset !== ""
    title: FoamyI18n.t("studio.presetAsk", studio.presetLabel(studio.pendingPreset || studio.draft.preset))
    body: FoamyI18n.tn("studio.presetAskBody", studio.changes, [studio.changes, studio.presetLabel(studio.pendingPreset || studio.draft.preset)])
      + (studio.pendingPreset && !studio.keptPreset ? "\n" + FoamyI18n.t("studio.presetCantKeep") : "")
    onDismissed: studio.cancelPreset()

    FoamyButton {
      focusable: true
      objectName: "studioPresetCancel"
      text: FoamyI18n.t("studio.cancel")
      onClicked: studio.cancelPreset()
    }
    FoamyButton {
      focusable: true
      objectName: "studioPresetReplace"
      text: FoamyI18n.t("studio.presetReplace")
      onClicked: studio.answerPreset(false)
    }
    FoamyButton {
      id: keepButton
      focusable: true
      objectName: "studioPresetKeep"
      kind: "primary"
      enabled: studio.keptPreset !== null
      text: FoamyI18n.t("studio.presetKeep")
      onClicked: studio.answerPreset(true)
    }
  }

  // Reset: the saved look, or the preset without changes.
  Question {
    id: resetDialog
    objectName: "studioResetDialog"
    visible: studio.resetAsked
    title: FoamyI18n.t("studio.reset.title")
    body: FoamyI18n.t("studio.reset.body", studio.presetLabel(studio.draft.preset))
    onDismissed: studio.answerReset("cancel")

    FoamyButton {
      focusable: true
      objectName: "studioResetCancel"
      text: FoamyI18n.t("studio.cancel")
      onClicked: studio.answerReset("cancel")
    }
    FoamyButton {
      id: resetPreset
      focusable: true
      objectName: "studioResetPreset"
      text: FoamyI18n.t("studio.reset.preset", studio.presetLabel(studio.draft.preset))
      enabled: studio.changes > 0
      Accessible.description: FoamyI18n.t("studio.reset.presetHint")
      onClicked: studio.answerReset("preset")
    }
    FoamyButton {
      id: resetSaved
      focusable: true
      objectName: "studioResetSaved"
      kind: "primary"
      text: FoamyI18n.t("studio.reset.saved")
      enabled: studio.unapplied
      Accessible.description: FoamyI18n.t("studio.reset.savedHint")
      onClicked: studio.answerReset("saved")
    }
  }

  // On open: a draft the lock doesn't have.
  Question {
    id: restoreDialog
    objectName: "studioRestoreDialog"
    visible: studio.session === "ask"
    title: FoamyI18n.t("studio.restore.title")
    body: studio.restoreReport && studio.savedAtText(studio.restoreReport.savedAt)
      ? FoamyI18n.t("studio.restore.bodyAt", studio.savedAtText(studio.restoreReport.savedAt)) : FoamyI18n.t("studio.restore.body")
    onDismissed: studio.answerRestore(true)

    FoamyButton {
      focusable: true
      objectName: "studioRestoreSaved"
      text: FoamyI18n.t("studio.restore.saved")
      Accessible.description: FoamyI18n.t("studio.restore.savedHint")
      onClicked: studio.answerRestore(false)
    }
    FoamyButton {
      id: restoreContinue
      focusable: true
      objectName: "studioRestoreContinue"
      kind: "primary"
      text: FoamyI18n.t("studio.restore.continue")
      onClicked: studio.answerRestore(true)
    }
  }

  // Quitting with changes the lock doesn't have.
  Question {
    id: quitDialog
    objectName: "studioQuitDialog"
    visible: studio.quitAsked
    title: FoamyI18n.t("studio.quit.title")
    body: FoamyI18n.t("studio.quit.body") + (studio.applyBlocked ? "\n" + FoamyI18n.t("studio.applyBlocked") : "")
    onDismissed: studio.answerQuit("cancel")

    FoamyButton {
      id: quitCancel
      focusable: true
      objectName: "studioQuitCancel"
      text: FoamyI18n.t("studio.cancel")
      onClicked: studio.answerQuit("cancel")
    }
    FoamyButton {
      focusable: true
      objectName: "studioQuitDiscard"
      text: FoamyI18n.t("studio.quit.discard")
      Accessible.description: FoamyI18n.t("studio.quit.discardHint")
      onClicked: studio.answerQuit("discard")
    }
    FoamyButton {
      id: quitApply
      focusable: true
      objectName: "studioQuitApply"
      kind: "primary"
      enabled: studio.canApply || studio.quitAfterApply
      text: studio.quitAfterApply ? FoamyI18n.t("studio.applying") : FoamyI18n.t("studio.quit.apply")
      onClicked: if (!studio.quitAfterApply) studio.answerQuit("apply")
    }
  }

  // "?" lists the shortcuts.
  Rectangle {
    id: shortcuts
    objectName: "studioShortcuts"
    anchors.fill: parent
    visible: studio.shortcutsOpen
    color: Qt.alpha(FoamyPalette.background, 0.72)
    z: 10

    MouseArea {
      anchors.fill: parent
      onClicked: studio.shortcutsOpen = false
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - 2 * FoamyStyle.padding, 460)
      height: shortcutColumn.implicitHeight + 2 * FoamyStyle.padding
      radius: FoamyStyle.radius
      color: FoamyPalette.background
      border.width: FoamyStyle.borderWidth
      border.color: FoamyPalette.border
      Accessible.role: Accessible.Dialog
      Accessible.name: FoamyI18n.t("studio.shortcuts")

      Column {
        id: shortcutColumn
        x: FoamyStyle.padding
        y: FoamyStyle.padding
        width: parent.width - 2 * FoamyStyle.padding
        spacing: FoamyStyle.gapSmall

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignLeft
          text: FoamyI18n.t("studio.shortcuts")
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
          bottomPadding: FoamyStyle.gap
        }
        Repeater {
          model: ["move", "nudge", "zone", "scale", "hide", "show", "select", "free", "axis", "undo", "redo", "panes", "help", "quit"]
          RowLayout {
            required property var modelData
            width: shortcutColumn.width
            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignLeft
              text: FoamyI18n.t("studio.key." + parent.modelData)
              color: FoamyPalette.secondaryText
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.body
            }
            Text {
              text: FoamyI18n.t("studio.key." + parent.modelData + ".keys")
              color: FoamyPalette.text
              font.family: FoamyStyle.monoFamily
              font.pixelSize: FoamyStyle.font.body
            }
          }
        }
      }
    }
  }
}
