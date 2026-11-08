pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "kit"
import "Layout.js" as LockLayout
import "." as Studio
import "Draft.js" as Draft

// Lock Studio's window content (mockup A, "Canvas"): a header (preset,
// screen, undo and redo, preview, apply), the module library and scene on
// the reading start, the live canvas in the middle with its preview states,
// toggles, problems and presets, and the inspector on the reading end.
//
// It owns the draft: `history` (Draft.history) holds the entry being edited
// and its undo steps; every edit goes through commit(). Keys that work
// everywhere are in appKey(); the canvas handles its own (see Canvas).
FocusScope {
  id: studio

  // The window can be seen (drawn backgrounds stop otherwise).
  property bool awake: true
  signal quitRequested()

  property var history: Draft.history({ preset: LockLayout.DEFAULT_PRESET })
  readonly property var draft: history.present
  readonly property var look: Draft.lookOf(draft)
  property string selected: "clock"
  property string monitorKey: ""
  readonly property var monitors: monitorList(Quickshell.screens)
  readonly property var monitor: monitorFor(monitorKey)
  property string previewState: "idle"
  property bool showZones: true
  property bool snapping: true
  property bool shortcutsOpen: false
  readonly property bool rightToLeft: FoamyI18n.rightToLeft
  readonly property alias canvas: lockCanvas
  readonly property alias checker: lockChecker
  readonly property var problems: lockChecker.problems
  readonly property bool applyBlocked: problems.some(function(problem) { return !problem.reference })
  readonly property int changes: Draft.changeCount(draft)
  readonly property var panes: [library, canvasPane, inspector, header]

  LayoutMirroring.enabled: rightToLeft
  LayoutMirroring.childrenInherit: true

  Keys.onPressed: function(event) { if (studio.appKey(event.key, event.modifiers, event.text)) event.accepted = true }

  function commit(next) {
    history = Draft.push(history, next)
  }
  function undo() { history = Draft.undo(history) }
  function redo() { history = Draft.redo(history) }

  // The connected screens (logical size), then the reference sizes.
  function monitorList(screens) {
    var list = []
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (!(screen.width > 0 && screen.height > 0)) continue
      // A screen without a name (a virtual one) goes by its number.
      var name = screen.name || FoamyI18n.t("studio.monitor.unnamed", i + 1)
      list.push({ key: "screen:" + (screen.name || i), name: name, width: screen.width, height: screen.height, reference: false,
        label: FoamyI18n.t("studio.monitor.screen", [name, screen.width, screen.height]) })
    }
    var references = [[1280, 720], [1920, 1080]]
    for (var j = 0; j < references.length; j++) {
      var w = references[j][0], h = references[j][1]
      list.push({ key: "reference:" + w + "x" + h, name: "", width: w, height: h, reference: true,
        label: FoamyI18n.t("studio.monitor.reference", [w, h]) })
    }
    return list
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
      quitRequested()
      return true
    }
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
    if (ctrl) return false
    if (text === "?" || key === Qt.Key_Question) {
      shortcutsOpen = !shortcutsOpen
      return true
    }
    if (key === Qt.Key_BracketLeft || key === Qt.Key_BracketRight) {
      selected = Draft.neighbourModule(selected, key === Qt.Key_BracketLeft ? -1 : 1)
      return true
    }
    return false
  }

  Component.onCompleted: lockCanvas.forceActiveFocus()

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

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

          StudioButton {
            focus: true
            text: studio.presetLabel(studio.draft.preset)
            detail: studio.changes > 0 ? FoamyI18n.t("studio.edited") : ""
            Accessible.name: FoamyI18n.t("studio.preset", text)
            onClicked: presetStrip.forceActiveFocus(Qt.TabFocusReason)
          }

          Segmented {
            name: FoamyI18n.t("studio.monitor")
            options: studio.monitors.map(function(m) { return { value: m.key, label: m.label } })
            value: studio.monitor.key
            onPicked: function(value) { studio.monitorKey = value }
          }

          Item { Layout.fillWidth: true }

          StudioButton {
            text: FoamyI18n.t("studio.undo")
            enabled: Draft.canUndo(studio.history)
            onClicked: studio.undo()
          }
          StudioButton {
            text: FoamyI18n.t("studio.redo")
            enabled: Draft.canRedo(studio.history)
            onClicked: studio.redo()
          }
          Text {
            text: studio.changes > 0 ? FoamyI18n.tn("studio.changes", studio.changes) : FoamyI18n.t("studio.noChanges")
            color: FoamyPalette.mutedText
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.bodySmall
            Layout.leftMargin: FoamyStyle.gapSmall
            Layout.rightMargin: FoamyStyle.gapSmall
          }
          // Preview and Apply are wired to the lock in a later step.
          StudioButton {
            text: FoamyI18n.t("studio.preview")
            enabled: false
          }
          StudioButton {
            primary: true
            text: FoamyI18n.t("studio.apply")
            enabled: false
            detail: ""
            Accessible.description: studio.applyBlocked ? FoamyI18n.t("studio.applyBlocked") : ""
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
        Layout.preferredWidth: 224
        Layout.fillHeight: true
        color: FoamyPalette.menuFill

        FocusScope {
          id: library
          anchors.fill: parent
          anchors.margins: FoamyStyle.gapLarge
          Accessible.role: Accessible.List
          Accessible.name: FoamyI18n.t("studio.modules")

          Column {
            width: parent.width
            spacing: FoamyStyle.gapSmall

            SectionLabel { text: FoamyI18n.t("studio.modules") }

            Repeater {
              model: Draft.DISPLAY_ORDER
              StudioButton {
                required property var modelData
                required property int index
                readonly property var item: studio.look.elements[modelData]
                focus: index === 0
                width: parent.width
                height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
                horizontalAlignment: Text.AlignLeft
                text: studio.moduleLabel(modelData)
                detail: item.hidden && modelData !== "password" ? FoamyI18n.t("studio.hidden") : studio.zoneLabel(item.zone)
                checked: studio.selected === modelData
                Accessible.role: Accessible.ListItem
                onClicked: studio.selected = modelData
              }
            }

            SectionLabel {
              text: FoamyI18n.t("studio.scene")
              topPadding: FoamyStyle.sectionGap
            }

            // The scene pages come with the inspector.
            StudioButton {
              width: parent.width
              height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
              horizontalAlignment: Text.AlignLeft
              text: FoamyI18n.t("studio.background")
              detail: FoamyI18n.t("studio.source." + studio.look.background.source)
            }
            StudioButton {
              width: parent.width
              height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
              horizontalAlignment: Text.AlignLeft
              text: FoamyI18n.t("studio.glassDim")
              detail: studio.percent(studio.look.background.dim)
            }
          }
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
              name: FoamyI18n.t("studio.state")
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
              text: FoamyI18n.t("studio.zones")
              checked: studio.showZones
              onToggled: studio.showZones = !studio.showZones
            }
            StudioToggle {
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
            draft: studio.draft
            selected: studio.selected
            screenWidth: studio.monitor.width
            screenHeight: studio.monitor.height
            previewState: studio.previewState
            showZones: studio.showZones
            snapping: studio.snapping
            awake: studio.awake
            problemNames: studio.problemNamesFor(studio.monitor.key)
            selectionText: studio.selectionText(studio.selected)
            onEdited: function(next) { studio.commit(next) }
            onSelectRequested: function(name) { if (name) studio.selected = name }
          }

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: FoamyI18n.t("studio.shownAt", [studio.monitor.width, studio.monitor.height, Math.round(lockCanvas.zoom * 100)])
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
                  wrapMode: Text.Wrap
                  color: modelData.reference ? FoamyPalette.onSurface(FoamyPalette.warning) : FoamyPalette.onSurface(FoamyPalette.error)
                  font.family: FoamyStyle.fontFamily
                  font.pixelSize: FoamyStyle.font.bodySmall
                }
              }
              Text {
                visible: problemColumn.sorted.length > 3
                text: FoamyI18n.tn("studio.problem.more", problemColumn.sorted.length - 3)
                color: FoamyPalette.mutedText
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.bodySmall
              }
            }
          }

          // Presets (thumbnails from previews/presets).
          ListView {
            id: presetStrip
            Layout.fillWidth: true
            Layout.preferredHeight: 78
            orientation: ListView.Horizontal
            spacing: FoamyStyle.gap
            clip: true
            model: LockLayout.SELECTABLE_PRESETS
            activeFocusOnTab: true
            keyNavigationEnabled: true
            currentIndex: Math.max(0, LockLayout.SELECTABLE_PRESETS.indexOf(studio.draft.preset))
            Accessible.role: Accessible.List
            Accessible.name: FoamyI18n.t("studio.presets")
            Keys.onReturnPressed: studio.commit(Draft.setPreset(studio.draft, LockLayout.SELECTABLE_PRESETS[currentIndex]))
            Keys.onSpacePressed: studio.commit(Draft.setPreset(studio.draft, LockLayout.SELECTABLE_PRESETS[currentIndex]))

            delegate: Rectangle {
              id: presetTile
              required property var modelData
              required property int index
              readonly property bool chosen: studio.draft.preset === modelData
              width: 104
              height: 78
              radius: FoamyStyle.radiusSmall
              color: presetMouse.containsMouse ? FoamyPalette.hoverFill : "transparent"
              border.width: presetStrip.activeFocus && presetStrip.currentIndex === index ? 2 : chosen ? 2 : 0
              border.color: presetStrip.activeFocus && presetStrip.currentIndex === index ? FoamyPalette.text : FoamyPalette.accent
              Accessible.role: Accessible.ListItem
              Accessible.name: studio.presetLabel(modelData)
              Accessible.selected: chosen

              Image {
                x: 3
                y: 3
                width: parent.width - 6
                height: 54
                source: Qt.resolvedUrl("previews/presets/" + presetTile.modelData + ".png")
                sourceSize.width: 208
                sourceSize.height: 117
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
              Text {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: studio.presetLabel(presetTile.modelData)
                elide: Text.ElideRight
                color: presetTile.chosen ? FoamyPalette.text : FoamyPalette.secondaryText
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.caption
              }
              MouseArea {
                id: presetMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  presetStrip.currentIndex = presetTile.index
                  studio.commit(Draft.setPreset(studio.draft, presetTile.modelData))
                }
              }
            }
          }
        }
      }

      // The inspector (its controls come in a later step; this shows the
      // selection's values).
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
          id: inspector
          readonly property string name: studio.selected
          readonly property var item: studio.look.elements[name] || null
          anchors.fill: parent
          anchors.margins: FoamyStyle.gapLarge
          Accessible.role: Accessible.Pane
          Accessible.name: FoamyI18n.t("studio.inspector")

          Column {
            width: parent.width
            spacing: FoamyStyle.gap
            visible: inspector.item !== null

            RowLayout {
              width: parent.width
              Text {
                Layout.fillWidth: true
                text: studio.moduleLabel(inspector.name)
                color: FoamyPalette.text
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.heading
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                Accessible.role: Accessible.Heading
                Accessible.name: text
              }
              StudioToggle {
                focus: true
                text: FoamyI18n.t("studio.shown")
                visible: inspector.name !== "password"
                checked: inspector.item ? !inspector.item.hidden : false
                onToggled: studio.commit(Draft.setHidden(studio.draft, inspector.name, !inspector.item.hidden))
              }
            }

            Text {
              visible: inspector.name === "password"
              width: parent.width
              text: FoamyI18n.t("studio.passwordAlways")
              wrapMode: Text.Wrap
              color: FoamyPalette.mutedText
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.bodySmall
            }

            SectionLabel {
              text: FoamyI18n.t("studio.adjust")
              topPadding: FoamyStyle.gap
            }
            ValueRow { label: FoamyI18n.t("studio.style"); value: inspector.item ? studio.styleLabel(inspector.item.style) : "" }
            ValueRow {
              label: FoamyI18n.t("studio.size")
              value: inspector.item ? studio.percent(Draft.elementValue(inspector.item, "scale")) : ""
            }
            ValueRow {
              label: FoamyI18n.t("studio.opacity")
              value: inspector.item ? studio.percent(Draft.elementValue(inspector.item, "opacity")) : ""
            }

            SectionLabel {
              text: FoamyI18n.t("studio.placement")
              topPadding: FoamyStyle.gap
            }
            ValueRow { label: FoamyI18n.t("studio.zone"); value: inspector.item ? studio.zoneLabel(inspector.item.zone) : "" }
            ValueRow {
              readonly property var offset: inspector.item ? Draft.elementValue(inspector.item, "offset") : null
              label: FoamyI18n.t("studio.offset")
              value: offset ? FoamyI18n.t("studio.offsetValue", [Math.round(offset.x * studio.monitor.width),
                Math.round(offset.y * studio.monitor.height)]) : ""
            }
            ValueRow {
              visible: LockLayout.SCREENS_ELEMENTS.indexOf(inspector.name) !== -1
              label: FoamyI18n.t("studio.screens")
              value: inspector.item ? FoamyI18n.t("studio.screens." + Draft.elementValue(inspector.item, "screens")) : ""
            }
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
          text: FoamyI18n.t("studio.shortcuts")
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
          bottomPadding: FoamyStyle.gap
        }
        Repeater {
          model: ["move", "nudge", "zone", "scale", "hide", "select", "free", "axis", "undo", "redo", "panes", "help", "quit"]
          RowLayout {
            required property var modelData
            width: shortcutColumn.width
            Text {
              Layout.fillWidth: true
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

  component SectionLabel: Text {
    color: FoamyPalette.mutedText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.caption
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.6
    bottomPadding: FoamyStyle.gapTiny
    Accessible.role: Accessible.Heading
    Accessible.name: text
  }

  component ValueRow: RowLayout {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    Text {
      Layout.fillWidth: true
      text: parent.label
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
    }
    Text {
      text: parent.value
      color: FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      Accessible.role: Accessible.StaticText
      Accessible.name: parent.label + ": " + parent.value
    }
  }
}
