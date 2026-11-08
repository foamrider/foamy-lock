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

  Accessible.role: Accessible.Pane
  Accessible.name: FoamyI18n.t("studio.inspector")

  function commit(next) { app.commit(next) }
  function preview(next) { app.preview(next) }
  function px(value) { return FoamyI18n.t("studio.px", FoamyI18n.number(value, 0)) }

  // Keep the control with the keyboard in view.
  function reveal(target) {
    if (!target || !visible) return
    var inside = false
    for (var p = target; p; p = p.parent) if (p === column) inside = true
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
          checked: inspector.item ? !inspector.item.hidden : false
          onToggled: inspector.commit(Draft.setHidden(inspector.app.draft, inspector.name, !inspector.item.hidden))
        }
      }

      PaneNote {
        text: inspector.name === "password" ? FoamyI18n.t("studio.passwordAlways")
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
      RowLayout {
        width: parent.width
        visible: Draft.hasGlass(inspector.look, inspector.name)
        PaneNote {
          Layout.fillWidth: true
          text: inspector.item && inspector.item.glass !== undefined ? FoamyI18n.t("studio.glassOwn") : FoamyI18n.t("studio.glassLook")
        }
        FoamyButton {
          objectName: "studioGlassReset"
          focusable: true
          visible: inspector.item !== null && inspector.item.glass !== undefined
          text: FoamyI18n.t("studio.glassReset")
          onClicked: inspector.commit(Draft.setGlass(inspector.app.draft, inspector.name, null))
        }
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
      FoamyButton {
        objectName: "studioResetPosition"
        focusable: true
        text: FoamyI18n.t("studio.resetPosition")
        enabled: inspector.item !== null && LockLayout.isOffset(inspector.item)
        onClicked: inspector.commit(Draft.resetOffset(inspector.app.draft, inspector.name))
      }

      RowLayout {
        width: parent.width
        visible: LockLayout.SCREENS_ELEMENTS.indexOf(inspector.name) !== -1
        Text {
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
}
