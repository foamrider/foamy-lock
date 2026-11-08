pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit"
import "Layout.js" as LockLayout
import "Draft.js" as Draft

// The inspector for the selected module (mockup A, right pane): whether it
// shows, its style (drawn tiles), size, opacity and glass, its zone,
// offset (grid steps, pixels at the screen shown) and screens. Every
// change is one Draft edit committed through the window (`app`), so
// undo and redo cover them; a slider drag shows live (app.preview) and
// commits once on release.
FocusScope {
  id: inspector

  // The StudioWindow: draft, look, selected, monitor, canvas, commit(),
  // preview(), lockSettings and the label helpers.
  property var app: null

  readonly property string name: app ? app.selected : ""
  readonly property var look: app ? app.look : LockLayout.defaults()
  readonly property var item: look.elements[name] || null
  readonly property var limits: name === "password" ? LockLayout.PASSWORD_LIMITS : LockLayout.LIMITS
  readonly property int screenWidth: app ? app.monitor.width : 1920
  readonly property int screenHeight: app ? app.monitor.height : 1080
  readonly property var offsetPx: item ? Draft.offsetPixels(Draft.elementValue(item, "offset"), screenWidth, screenHeight) : ({ x: 0, y: 0 })
  readonly property alias flickable: flick
  // What each element takes (its own keys' values and defaults).
  readonly property var options: LockLayout.elementLimits()
  readonly property alias checklist: itemChecklist

  Accessible.role: Accessible.Pane
  Accessible.name: FoamyI18n.t("studio.inspector")

  function commit(next) { app.commit(next) }
  function preview(next) { app.preview(next) }
  function px(value) { return FoamyI18n.t("studio.px", FoamyI18n.number(value, 0)) }

  // Keep the control with the keyboard in view.
  function reveal(target) {
    if (!target || !visible) return
    var inside = false
    for (let p = target; p; p = p.parent) if (p === column) inside = true
    if (!inside) return
    var top = target.mapToItem(column, 0, 0).y
    if (top < flick.contentY) flick.contentY = Math.max(0, top - FoamyStyle.gap)
    else if (top + target.height > flick.contentY + flick.height)
      flick.contentY = Math.min(flick.contentHeight - flick.height, top + target.height - flick.height + FoamyStyle.gap)
  }

  Connections {
    target: inspector.Window.window
    function onActiveFocusItemChanged() { inspector.reveal(inspector.Window.activeFocusItem) }
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: flick.width
      spacing: FoamyStyle.gap
      visible: inspector.item !== null

      RowLayout {
        width: parent.width
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: inspector.app ? inspector.app.moduleLabel(inspector.name) : ""
          horizontalAlignment: Text.AlignLeft
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
          elide: Text.ElideRight
          Accessible.role: Accessible.Heading
          Accessible.name: text
        }
        StudioToggle {
          id: shownToggle
          objectName: "studioShown"
          focus: true
          text: FoamyI18n.t("studio.shown")
          visible: inspector.name !== "password"
          // Shown can always go off; on only when it can show.
          enabled: checked || !inspector.app || inspector.app.canShow(inspector.name)
          opacity: enabled ? 1 : FoamyStyle.disabledOpacity
          checked: inspector.item ? !inspector.item.hidden : false
          onToggled: if (enabled) inspector.commit(Draft.setHidden(inspector.app.draft, inspector.name, !inspector.item.hidden))
        }
      }

      PaneNote {
        objectName: "studioModuleNote"
        text: inspector.name === "password" ? FoamyI18n.t("studio.passwordAlways")
          : inspector.name === "weather" && inspector.app && !inspector.app.weatherAvailable ? FoamyI18n.t("studio.needsWeather.hint")
          : inspector.name === "account" && inspector.app && !inspector.app.lockSettings.showUserInfo ? FoamyI18n.t("studio.settingHidesAccount")
          : inspector.name === "media" && inspector.app && !inspector.app.lockSettings.showMedia ? FoamyI18n.t("studio.settingHidesMedia")
          : inspector.item && inspector.item.hidden ? FoamyI18n.t("studio.hiddenHint")
          : ""
      }

      SectionLabel {
        text: FoamyI18n.t("studio.style")
        topPadding: FoamyStyle.gapSmall
      }
      StyleTiles {
        objectName: "studioStyles"
        width: parent.width
        element: inspector.name
        title: FoamyI18n.t("studio.style")
        options: LockLayout.STYLES[inspector.name] || []
        value: inspector.item ? inspector.item.style : ""
        labelFor: function(style) { return FoamyI18n.t("studio.style." + style) }
        onPicked: function(style) { inspector.commit(Draft.setStyle(inspector.app.draft, inspector.name, style)) }
      }

      // The element's own keys (Layout.elementLimits()[name].options).
      SectionLabel {
        visible: inspector.name === "password" || inspector.name === "status" || inspector.name === "weather"
        text: FoamyI18n.t(inspector.name === "password" ? "studio.field" : "studio.shows")
        topPadding: FoamyStyle.gap
      }

      // password.reveal, for every field style; absent, the style's own
      // default (the pill and dots: while typing).
      RowLayout {
        width: parent.width
        visible: inspector.name === "password"
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: FoamyI18n.t("studio.reveal")
          horizontalAlignment: Text.AlignLeft
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
          wrapMode: Text.Wrap
        }
        Segmented {
          objectName: "studioReveal"
          name: FoamyI18n.t("studio.reveal")
          options: inspector.options.password.options.reveal.values.map(function(v) { return { value: v, label: FoamyI18n.t("studio.reveal." + v) } })
          value: Draft.optionOf(inspector.look, "password", "reveal")
          onPicked: function(value) { inspector.commit(Draft.setOption(inspector.app.draft, "password", "reveal", value)) }
        }
      }
      PaneNote {
        objectName: "studioRevealNote"
        visible: inspector.name === "password"
        text: FoamyI18n.t("studio.reveal.hint")
      }

      // status.items: an ordered checklist.
      ItemChecklist {
        id: itemChecklist
        objectName: "studioItems"
        width: parent.width
        visible: inspector.name === "status"
        app: inspector.app
        title: FoamyI18n.t("studio.shows")
      }
      PaneNote {
        width: parent.width
        visible: inspector.name === "status"
        text: FoamyI18n.t("studio.items.hint")
      }

      // weather.details and weather.location (off unless chosen: anyone
      // can read a lock screen).
      RowLayout {
        width: parent.width
        visible: inspector.name === "weather"
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: FoamyI18n.t("studio.details")
          horizontalAlignment: Text.AlignLeft
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
          wrapMode: Text.Wrap
        }
        // The card always shows the full report.
        Segmented {
          objectName: "studioDetails"
          name: FoamyI18n.t("studio.details")
          enabled: !inspector.item || inspector.item.style !== "card"
          opacity: enabled ? 1 : FoamyStyle.disabledOpacity
          options: inspector.options.weather.options.details.values.map(function(v) { return { value: v, label: FoamyI18n.t("studio.details." + v) } })
          value: Draft.optionOf(inspector.look, "weather", "details")
          onPicked: function(value) { inspector.commit(Draft.setOption(inspector.app.draft, "weather", "details", value)) }
        }
      }
      PaneNote {
        objectName: "studioDetailsNote"
        visible: inspector.name === "weather" && inspector.item !== null && inspector.item.style === "card"
        text: FoamyI18n.t("studio.details.card")
      }
      StudioToggle {
        objectName: "studioLocation"
        width: parent.width
        visible: inspector.name === "weather"
        text: FoamyI18n.t("studio.location")
        checked: Draft.optionOf(inspector.look, "weather", "location") === true
        onToggled: inspector.commit(Draft.setOption(inspector.app.draft, "weather", "location", !checked))
      }
      PaneNote {
        objectName: "studioLocationNote"
        visible: inspector.name === "weather"
        text: FoamyI18n.t("studio.location.note")
      }
      PaneNote {
        objectName: "studioWeatherSample"
        visible: inspector.name === "weather"
        text: FoamyI18n.t("studio.weather.sample")
      }

      SectionLabel {
        text: FoamyI18n.t("studio.adjust")
        topPadding: FoamyStyle.gap
      }
      StudioSlider {
        objectName: "studioSize"
        width: parent.width
        label: FoamyI18n.t("studio.size")
        from: inspector.limits.scale.min
        to: inspector.limits.scale.max
        stepSize: inspector.limits.scale.step
        value: inspector.item ? Draft.elementValue(inspector.item, "scale") : 1
        valueText: FoamyI18n.t("studio.percent", Math.round(shown * 100))
        onMoved: function(v) { inspector.preview(Draft.setScale(inspector.app.draft, inspector.name, v)) }
        onCommitted: function(v) { inspector.commit(Draft.setScale(inspector.app.draft, inspector.name, v)) }
      }
      StudioSlider {
        objectName: "studioOpacity"
        width: parent.width
        label: FoamyI18n.t("studio.opacity")
        from: inspector.limits.opacity.min
        to: inspector.limits.opacity.max
        stepSize: 0.05
        value: inspector.item ? Draft.elementValue(inspector.item, "opacity") : 1
        valueText: FoamyI18n.t("studio.percent", Math.round(shown * 100))
        onMoved: function(v) { inspector.preview(Draft.setOpacity(inspector.app.draft, inspector.name, v)) }
        onCommitted: function(v) { inspector.commit(Draft.setOpacity(inspector.app.draft, inspector.name, v)) }
      }
      // Only the styles that draw a glass surface take one.
      StudioSlider {
        objectName: "studioGlass"
        width: parent.width
        visible: Draft.hasGlass(inspector.look, inspector.name)
        label: FoamyI18n.t("studio.glass")
        from: inspector.limits.glass.min
        to: inspector.limits.glass.max
        stepSize: 0.05
        value: Draft.glassOf(inspector.look, inspector.name)
        valueText: FoamyI18n.t("studio.percent", Math.round(shown * 100))
        onMoved: function(v) { inspector.preview(Draft.setGlass(inspector.app.draft, inspector.name, v)) }
        onCommitted: function(v) { inspector.commit(Draft.setGlass(inspector.app.draft, inspector.name, v)) }
      }
      PaneNote {
        width: parent.width
        visible: Draft.hasGlass(inspector.look, inspector.name)
        text: inspector.item && inspector.item.glass !== undefined ? FoamyI18n.t("studio.glassOwn") : FoamyI18n.t("studio.glassLook")
      }

      SectionLabel {
        text: FoamyI18n.t("studio.placement")
        topPadding: FoamyStyle.gap
      }
      RowLayout {
        width: parent.width
        spacing: FoamyStyle.gapLarge

        ZonePicker {
          objectName: "studioZones"
          Layout.alignment: Qt.AlignTop
          cellWidth: 22
          cellHeight: 16
          name: FoamyI18n.t("studio.zone")
          zone: inspector.item ? inspector.item.zone : ""
          allowed: Draft.zonesFor(inspector.name)
          onPicked: function(zone) { inspector.commit(Draft.setZone(inspector.app.draft, inspector.name, zone)) }
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: FoamyStyle.gapSmall
          StepField {
            objectName: "studioOffsetX"
            label: FoamyI18n.t("studio.x")
            name: FoamyI18n.t("studio.offsetX")
            value: Draft.pixelsToSteps(inspector.offsetPx.x, inspector.screenHeight)
            detail: inspector.px(inspector.offsetPx.x)
            onCommitted: function(steps) {
              inspector.commit(inspector.app.canvas.offsetTo(inspector.name,
                { x: Draft.stepsToPixels(steps, inspector.screenHeight), y: inspector.offsetPx.y }))
            }
          }
          StepField {
            objectName: "studioOffsetY"
            label: FoamyI18n.t("studio.y")
            name: FoamyI18n.t("studio.offsetY")
            value: Draft.pixelsToSteps(inspector.offsetPx.y, inspector.screenHeight)
            detail: inspector.px(inspector.offsetPx.y)
            onCommitted: function(steps) {
              inspector.commit(inspector.app.canvas.offsetTo(inspector.name,
                { x: inspector.offsetPx.x, y: Draft.stepsToPixels(steps, inspector.screenHeight) }))
            }
          }
        }
      }
      PaneNote {
        text: inspector.item ? FoamyI18n.t("studio.zoneValue", inspector.app.zoneLabel(inspector.item.zone))
          + " · " + FoamyI18n.t("studio.gridStep", FoamyI18n.number(Draft.gridStep(inspector.screenHeight), 1)) : ""
      }

      RowLayout {
        width: parent.width
        visible: LockLayout.SCREENS_ELEMENTS.indexOf(inspector.name) !== -1
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: FoamyI18n.t("studio.screens")
          horizontalAlignment: Text.AlignLeft
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
        }
        Segmented {
          objectName: "studioScreens"
          name: FoamyI18n.t("studio.screens")
          options: LockLayout.SCREENS.map(function(s) { return { value: s, label: FoamyI18n.t("studio.screens." + s) } })
          value: inspector.item ? Draft.elementValue(inspector.item, "screens") : "all"
          onPicked: function(value) { inspector.commit(Draft.setScreens(inspector.app.draft, inspector.name, value)) }
        }
      }
      PaneNote {
        visible: LockLayout.SCREENS_ELEMENTS.indexOf(inspector.name) !== -1
        text: FoamyI18n.t("studio.screensHint")
      }

      Item { width: 1; height: FoamyStyle.gap }
    }
  }

  // The status's items as an ordered checklist (Draft.statusRows): the
  // items shown first, in their order, then the others. A click or Space
  // switches one; the last one shown stays. The items shown reorder by
  // their grip (the canvas follows the drag; one undo step on release) or
  // by Alt+Up and Alt+Down; Up, Down, Home and End move the cursor.
  component ItemChecklist: FocusScope {
    id: checklist

    property var app: null
    property string title: ""
    readonly property var rows: app ? Draft.statusRows(app.look) : []
    readonly property int shownCount: rows.filter(function(row) { return row.on }).length
    readonly property real rowHeight: FoamyStyle.rowHeight
    // The row with the keyboard while the list has it.
    property int cursor: -1
    // A drag in progress: the row's index, where it would go, and how far
    // the pointer has moved (pixels).
    property int dragFrom: -1
    property int dragTo: -1
    property real dragOffset: 0

    implicitHeight: rows.length * rowHeight
    activeFocusOnTab: true
    onActiveFocusChanged: if (activeFocus && cursor < 0) cursor = 0

    Accessible.role: Accessible.List
    Accessible.name: title
    Accessible.description: FoamyI18n.t("studio.items.keys")

    function label(name) { return FoamyI18n.t("studio.item." + name) }

    function commitIfChanged(next) {
      if (!Draft.same(next, app.draft)) app.commit(next)
      else app.preview(app.draft)
    }

    // Switch the item in row `index`.
    function toggle(index) {
      var row = rows[index]
      if (!row) return
      commitIfChanged(Draft.toggleItem(app.draft, row.name, !row.on))
    }

    // Move the item in row `index` by `step` among the items shown; the
    // cursor goes with it.
    function move(index, step) {
      var row = rows[index]
      var to = index + step
      if (!row || !row.on || to < 0 || to >= shownCount) return
      commitIfChanged(Draft.moveItem(app.draft, row.name, to))
      cursor = to
    }

    // Keys on the list; true when handled.
    function keyPressed(key, modifiers) {
      var alt = (modifiers & Qt.AltModifier) !== 0
      if (modifiers & Qt.ControlModifier) return false
      var at = Math.max(0, cursor)
      switch (key) {
      case Qt.Key_Up:
        if (alt) move(at, -1)
        else cursor = Math.max(0, at - 1)
        break
      case Qt.Key_Down:
        if (alt) move(at, 1)
        else cursor = Math.min(rows.length - 1, at + 1)
        break
      case Qt.Key_Home: cursor = 0; break
      case Qt.Key_End: cursor = rows.length - 1; break
      case Qt.Key_Space:
      case Qt.Key_Return:
      case Qt.Key_Enter: toggle(at); break
      default: return false
      }
      return true
    }
    Keys.onPressed: function(event) { if (checklist.keyPressed(event.key, event.modifiers)) event.accepted = true }

    // The drag (the grip's handler, and a test hook): rows in view pixels.
    function dragStart(index) {
      if (!rows[index] || !rows[index].on) return false
      dragFrom = index
      dragTo = index
      dragOffset = 0
      cursor = index
      return true
    }
    function dragMove(offset) {
      if (dragFrom < 0) return
      dragOffset = Math.max(-dragFrom * rowHeight, Math.min((shownCount - 1 - dragFrom) * rowHeight, offset))
      var to = Math.max(0, Math.min(shownCount - 1, Math.round(dragFrom + dragOffset / rowHeight)))
      if (to === dragTo) return
      dragTo = to
      app.preview(Draft.moveItem(app.draft, rows[dragFrom].name, to))
    }
    function dragEnd() {
      if (dragFrom < 0) return
      var from = dragFrom, to = dragTo
      dragFrom = -1
      dragTo = -1
      dragOffset = 0
      commitIfChanged(Draft.moveItem(app.draft, rows[from].name, to))
      cursor = to
    }

    // Where row `index` sits while a drag moves another past it.
    function rowY(index) {
      if (index === dragFrom) return dragFrom * rowHeight + dragOffset
      var at = index
      if (dragFrom >= 0 && dragFrom < index && index <= dragTo) at--
      else if (dragFrom >= 0 && dragTo <= index && index < dragFrom) at++
      return at * rowHeight
    }

    Repeater {
      model: checklist.rows

      Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool cursorHere: checklist.activeFocus && checklist.cursor === index
        readonly property bool last: modelData.on && checklist.shownCount === 1
        objectName: "studioItem-" + modelData.name
        width: checklist.width
        height: checklist.rowHeight - 2
        y: checklist.rowY(index) + 1
        z: index === checklist.dragFrom ? 1 : 0
        radius: FoamyStyle.radiusSmall
        color: index === checklist.dragFrom ? FoamyPalette.selectedFill : rowMouse.containsMouse ? FoamyPalette.hoverFill : "transparent"
        border.width: cursorHere ? 2 : 0
        border.color: FoamyPalette.accent

        Accessible.role: Accessible.CheckBox
        Accessible.name: checklist.label(modelData.name)
        Accessible.checkable: true
        Accessible.checked: modelData.on
        Accessible.focused: cursorHere
        Accessible.description: last ? FoamyI18n.t("studio.items.last") : ""
        Accessible.onToggleAction: checklist.toggle(index)
        Accessible.onPressAction: checklist.toggle(index)

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            checklist.cursor = row.index
            checklist.forceActiveFocus(Qt.MouseFocusReason)
            checklist.toggle(row.index)
          }
        }

        // The grip, on the reading start: the items shown reorder by it.
        Item {
          id: grip
          objectName: "studioItemGrip"
          anchors.left: parent.left
          width: FoamyStyle.gap * 2 + 4
          height: parent.height
          visible: row.modelData.on && checklist.shownCount > 1
          Grid {
            anchors.centerIn: parent
            columns: 2
            spacing: 2
            Repeater {
              model: 6
              Rectangle { width: 2; height: 2; radius: 1; color: FoamyPalette.mutedText }
            }
          }
          HoverHandler { cursorShape: Qt.SizeVerCursor }
          DragHandler {
            target: null
            yAxis.enabled: true
            xAxis.enabled: false
            dragThreshold: 4
            onActiveChanged: {
              if (active) {
                checklist.forceActiveFocus(Qt.MouseFocusReason)
                checklist.dragStart(row.index)
              } else checklist.dragEnd()
            }
            onTranslationChanged: if (active) checklist.dragMove(translation.y)
          }
        }

        Row {
          anchors.left: grip.right
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: FoamyStyle.gap

          // The box: the accent with a check when shown.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: FoamyStyle.iconSize + 3
            height: width
            radius: Math.max(2, FoamyStyle.radiusSmall / 2)
            color: row.modelData.on ? FoamyPalette.accent : FoamyPalette.fieldFill
            border.width: row.modelData.on ? 0 : FoamyStyle.borderWidth
            border.color: FoamyPalette.border
            opacity: row.last ? FoamyStyle.disabledOpacity : 1
            FoamyIcon {
              anchors.centerIn: parent
              width: FoamyStyle.iconSize - 2
              height: width
              visible: row.modelData.on
              name: "check"
              color: FoamyPalette.onAccent
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: checklist.label(row.modelData.name)
            textFormat: Text.PlainText
            color: row.modelData.on ? FoamyPalette.text : FoamyPalette.secondaryText
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.body
          }
        }
      }
    }
  }
}
