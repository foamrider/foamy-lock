pragma ComponentBehavior: Bound
import QtQuick
import "kit"
import "Layout.js" as Layout

// The 3×3 zone picker: one cell per zone of the lock screen, the module's
// own filled in the accent. Zones the module can't take (the top row for
// the password field) are faded and skipped. Start and end mirror right
// to left (the Grid follows LayoutMirroring), as on the lock.
//
// Keyboard: Tab focuses it on the current zone; the arrow keys move the
// cursor, Enter or Space pick. `zone` is the caller's; picked(zone) asks.
FocusScope {
  id: picker

  property string zone: ""
  // The zones the module may use.
  property var allowed: Layout.ZONES
  property string name: ""
  property real cellWidth: 26
  property real cellHeight: 18
  property int cursor: -1

  signal picked(string zone)

  implicitWidth: grid.implicitWidth
  implicitHeight: grid.implicitHeight
  activeFocusOnTab: true
  onActiveFocusChanged: if (activeFocus) cursor = Math.max(0, Layout.ZONES.indexOf(zone))

  Accessible.role: Accessible.List
  Accessible.name: name

  function usable(zone) { return allowed.indexOf(zone) !== -1 }

  // Move by dx columns (on screen) and dy rows to the next usable cell.
  function step(dx, dy) {
    var from = cursor >= 0 ? cursor : Math.max(0, Layout.ZONES.indexOf(zone))
    var row = Math.floor(from / 3), column = from % 3
    var across = dx * (LayoutMirroring.enabled ? -1 : 1)
    for (var tries = 0; tries < 3; tries++) {
      row += dy
      column += across
      if (row < 0 || row > 2 || column < 0 || column > 2) return
      if (usable(Layout.ZONES[row * 3 + column])) {
        cursor = row * 3 + column
        return
      }
    }
  }

  Keys.onPressed: function(event) {
    switch (event.key) {
    case Qt.Key_Left: step(-1, 0); break
    case Qt.Key_Right: step(1, 0); break
    case Qt.Key_Up: step(0, -1); break
    case Qt.Key_Down: step(0, 1); break
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space:
      if (cursor >= 0 && usable(Layout.ZONES[cursor])) picked(Layout.ZONES[cursor])
      break
    default: return
    }
    event.accepted = true
  }

  Grid {
    id: grid
    columns: 3
    spacing: 3

    Repeater {
      model: Layout.ZONES

      Rectangle {
        id: cell
        required property string modelData
        required property int index
        readonly property bool current: picker.zone === modelData
        readonly property bool open: picker.usable(modelData)
        readonly property bool cursorHere: picker.activeFocus && picker.cursor === index
        objectName: "studioZone-" + modelData
        width: picker.cellWidth
        height: picker.cellHeight
        radius: Math.min(3, FoamyStyle.radiusSmall)
        opacity: open ? 1 : FoamyStyle.disabledOpacity
        color: current ? FoamyPalette.accent : mouse.containsMouse && open ? FoamyPalette.hoverFill : FoamyPalette.fieldFill
        border.width: cursorHere ? 2 : FoamyStyle.borderWidth
        border.color: cursorHere ? FoamyPalette.text : current ? FoamyPalette.accent : FoamyPalette.border

        Accessible.role: Accessible.RadioButton
        Accessible.name: FoamyI18n.t("studio.zone." + modelData)
        Accessible.checkable: true
        Accessible.checked: current
        Accessible.focused: cursorHere
        Accessible.onPressAction: if (open) picker.picked(modelData)

        MouseArea {
          id: mouse
          anchors.fill: parent
          hoverEnabled: true
          enabled: cell.open
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            picker.cursor = cell.index
            picker.forceActiveFocus(Qt.MouseFocusReason)
            picker.picked(cell.modelData)
          }
        }
      }
    }
  }
}
