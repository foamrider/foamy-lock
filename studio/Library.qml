pragma ComponentBehavior: Bound
import QtQuick
import "kit"
import "Layout.js" as Layout
import "Draft.js" as Draft

// The library (mockup A, left pane): first the preset ("Preset: Foamy ▾",
// which opens the preset menu), then the modules, each with its zone or
// "Hidden", and the scene pages (background, glass and dim). The list
// scrolls (wheel, and the keyboard keeps the row it is on in view) when the
// pane is short; the window pins the tips card under it.
//
// Drag a module onto the canvas to show it (or move it) where it lands,
// with the canvas's snapping; drag a shown one from the canvas onto this
// pane to hide it (StudioWindow wires both through the canvas). The
// keyboard does the same: Up and Down walk the modules (and select them),
// Delete hides the module, Insert shows it.
FocusScope {
  id: library

  // The StudioWindow: draft, look, selected, page, commit() and the drag hooks.
  property var app: null
  // A module from the canvas is over this pane: dropping hides it.
  property bool dropTarget: false
  readonly property alias presetButton: presetButton
  readonly property alias flickable: list

  Accessible.role: Accessible.Pane
  Accessible.name: FoamyI18n.t("studio.library")

  function rowAt(index) { return modules.itemAt(index) }

  function focusModule(step) {
    var index = Draft.DISPLAY_ORDER.indexOf(app.selected)
    var next = Math.max(0, Math.min(Draft.DISPLAY_ORDER.length - 1, index + step))
    app.selectModule(Draft.DISPLAY_ORDER[next])
    rowAt(next).forceActiveFocus(Qt.TabFocusReason)
  }

  // A module shown or hidden from the keyboard: one step, only when it
  // changes something.
  function setHidden(hidden) {
    var next = Draft.setHidden(app.draft, app.selected, hidden)
    if (!Draft.same(next, app.draft)) app.commit(next)
  }

  // Keys on the library; true when handled.
  function keyPressed(key, modifiers) {
    if (modifiers & (Qt.ControlModifier | Qt.AltModifier)) return false
    switch (key) {
    case Qt.Key_Up: focusModule(-1); break
    case Qt.Key_Down: focusModule(1); break
    case Qt.Key_Delete: setHidden(true); break
    case Qt.Key_Insert: setHidden(false); break
    default: return false
    }
    return true
  }

  // Keep the row with the keyboard in view.
  function reveal(target) {
    if (!target || !visible) return
    var inside = false
    for (var p = target; p; p = p.parent) if (p === column) inside = true
    if (!inside) return
    var top = target.mapToItem(column, 0, 0).y
    if (top < list.contentY) list.contentY = Math.max(0, top - FoamyStyle.gapSmall)
    else if (top + target.height > list.contentY + list.height)
      list.contentY = Math.min(list.contentHeight - list.height, top + target.height - list.height + FoamyStyle.gapSmall)
  }

  Connections {
    target: library.Window.window
    function onActiveFocusItemChanged() { library.reveal(library.Window.activeFocusItem) }
  }

  Keys.onPressed: function(event) { if (library.keyPressed(event.key, event.modifiers)) event.accepted = true }

  // The preset: opens the preset menu (thumbnails; StudioWindow).
  StudioButton {
    id: presetButton
    objectName: "studioPresetButton"
    focus: true
    width: parent.width
    height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
    horizontalAlignment: Text.AlignLeft
    trailing: FoamyStyle.iconSize + FoamyStyle.gap
    text: FoamyI18n.t("studio.preset", library.app.basisLabel)
    detail: library.app.presetChanged ? FoamyI18n.t("studio.edited") : ""
    checked: library.app.presetMenu.visible
    Accessible.role: Accessible.ButtonMenu
    Accessible.name: text
    onClicked: library.app.togglePresetMenu()

    FoamyIcon {
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      name: "chevron-down"
      color: FoamyPalette.secondaryText
    }
  }

  // Not interactive (a drag on a row is a module drag, never a scroll):
  // the wheel scrolls it, and the keyboard keeps its row in view.
  Flickable {
    id: list
    anchors.top: presetButton.bottom
    anchors.topMargin: FoamyStyle.gapLarge
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    interactive: false
    boundsBehavior: Flickable.StopAtBounds

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) {
        var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 3 * FoamyStyle.rowHeight
        list.contentY = Math.max(0, Math.min(Math.max(0, list.contentHeight - list.height), list.contentY - delta))
      }
    }

    Column {
      id: column
      width: list.width
      spacing: FoamyStyle.gapSmall

      SectionLabel { text: FoamyI18n.t("studio.modules") }

      Column {
        id: moduleList
        width: parent.width
        spacing: FoamyStyle.gapSmall
        Accessible.role: Accessible.List
        Accessible.name: FoamyI18n.t("studio.modules")

        Repeater {
          id: modules
          model: Draft.DISPLAY_ORDER

          StudioButton {
            id: row
            required property var modelData
            required property int index
            readonly property var item: library.app.look.elements[modelData]
            readonly property bool hiddenNow: item.hidden && modelData !== "password"
            readonly property bool dragging: library.app.libraryDrag === modelData
            objectName: "studioLibrary-" + modelData
            width: parent.width
            height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
            horizontalAlignment: Text.AlignLeft
            leading: FoamyStyle.gap + 6
            text: library.app.moduleLabel(modelData)
            detail: hiddenNow ? FoamyI18n.t("studio.hidden") : library.app.zoneLabel(item.zone)
            checked: library.app.page === "module" && library.app.selected === modelData
            opacity: dragging ? 0.45 : hiddenNow ? 0.7 : 1
            Accessible.role: Accessible.ListItem
            Accessible.description: detail + " · " + FoamyI18n.t("studio.dragHint")
            onClicked: library.app.selectModule(modelData)

            // The grip: two columns of dots on the reading start.
            Grid {
              anchors.left: parent.left
              anchors.leftMargin: FoamyStyle.gap
              anchors.verticalCenter: parent.verticalCenter
              columns: 2
              spacing: 2
              Repeater {
                model: 6
                Rectangle { width: 2; height: 2; radius: 1; color: FoamyPalette.mutedText }
              }
            }

            DragHandler {
              target: null
              dragThreshold: 6
              onActiveChanged: {
                if (active) library.app.libraryDragStart(row.modelData)
                else library.app.libraryDragEnd()
              }
              onCentroidChanged: if (active) library.app.libraryDragMove(centroid.scenePosition, centroid.modifiers)
            }
          }
        }
      }

      SectionLabel {
        text: FoamyI18n.t("studio.scene")
        topPadding: FoamyStyle.sectionGap
      }

      StudioButton {
        objectName: "studioSceneBackground"
        width: parent.width
        height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
        horizontalAlignment: Text.AlignLeft
        text: FoamyI18n.t("studio.background")
        detail: FoamyI18n.t("studio.source." + library.app.look.background.source)
        checked: library.app.page === "background"
        Accessible.role: Accessible.PageTab
        onClicked: library.app.page = "background"
      }
      StudioButton {
        objectName: "studioSceneGlass"
        width: parent.width
        height: FoamyStyle.rowHeight + FoamyStyle.gapSmall
        horizontalAlignment: Text.AlignLeft
        text: FoamyI18n.t("studio.glassDim")
        detail: FoamyI18n.t("studio.percent", Math.round(library.app.look.background.dim * 100))
        checked: library.app.page === "glass"
        Accessible.role: Accessible.PageTab
        onClicked: library.app.page = "glass"
      }
    }
  }

  // A module dragged here from the canvas is hidden on drop.
  Rectangle {
    objectName: "studioHideTarget"
    anchors.fill: parent
    anchors.margins: -FoamyStyle.gapSmall
    visible: library.dropTarget
    radius: FoamyStyle.radiusSmall
    color: Qt.alpha(FoamyPalette.background, 0.82)
    border.width: 2
    border.color: FoamyPalette.accent

    Text {
      anchors.centerIn: parent
      width: parent.width - 2 * FoamyStyle.gapLarge
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: FoamyI18n.t("studio.dropToHide", library.app.moduleLabel(library.app.selected))
      color: FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      font.weight: Font.DemiBold
    }
  }
}
