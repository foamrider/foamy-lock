pragma ComponentBehavior: Bound
import QtQuick
import "kit"
import "Layout.js" as Layout

// The header's preset menu: every selectable preset as a thumbnail
// (previews/presets/<name>.png) with its name, the current one marked. An
// overlay inside the window, dropped from the preset button (`anchorItem`)
// on the reading start; a press outside or Esc closes it.
//
// Keyboard: it takes the keys while open; the arrow keys move the cursor
// (mirrored right to left), Home and End jump, Enter or Space pick.
// picked(name) asks for the preset; closed() when it should go.
FocusScope {
  id: menu

  property Item anchorItem: null
  property string current: ""
  property int cursor: 0
  // The button's bottom-left corner in this item, taken when it opens.
  property point origin: Qt.point(0, 0)
  readonly property int columns: 4
  readonly property var presets: Layout.SELECTABLE_PRESETS

  signal picked(string name)
  signal closed()

  anchors.fill: parent
  visible: false
  z: 20

  function open() {
    cursor = Math.max(0, presets.indexOf(current))
    if (anchorItem) origin = anchorItem.mapToItem(menu, 0, anchorItem.height)
    visible = true
    forceActiveFocus(Qt.PopupFocusReason)
    ensureShown(cursor)
  }

  function close() {
    if (!visible) return
    visible = false
    closed()
  }

  function ensureShown(index) {
    var row = Math.floor(index / columns)
    var top = row * (tileHeight + grid.rowSpacing)
    if (top < list.contentY) list.contentY = top
    else if (top + tileHeight > list.contentY + list.height) list.contentY = top + tileHeight - list.height
  }

  function move(dx, dy) {
    var next = cursor
    if (dy !== 0) next = cursor + dy * columns
    else {
      let column = cursor % columns + dx * (LayoutMirroring.enabled ? -1 : 1)
      if (column >= 0 && column < columns) next = cursor - cursor % columns + column
    }
    if (next >= 0 && next < presets.length) {
      cursor = next
      ensureShown(next)
    }
  }

  readonly property real tileWidth: 116
  readonly property real tileHeight: 92

  // Keys while open; true when handled (every key but Tab, which stays put).
  function keyPressed(key) {
    switch (key) {
    case Qt.Key_Escape: close(); break
    case Qt.Key_Left: move(-1, 0); break
    case Qt.Key_Right: move(1, 0); break
    case Qt.Key_Up: move(0, -1); break
    case Qt.Key_Down: move(0, 1); break
    case Qt.Key_Home: cursor = 0; ensureShown(0); break
    case Qt.Key_End: cursor = presets.length - 1; ensureShown(cursor); break
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space: picked(presets[cursor]); break
    case Qt.Key_Tab:
    case Qt.Key_Backtab: break
    default: return false
    }
    return true
  }

  Keys.onPressed: function(event) { if (menu.keyPressed(event.key)) event.accepted = true }

  // A press outside closes it.
  MouseArea {
    anchors.fill: parent
    onPressed: menu.close()
  }

  Rectangle {
    id: card
    objectName: "studioPresetMenu"
    // Its start edge on the button's (mirrored right to left), kept inside.
    x: Math.max(FoamyStyle.gap, Math.min(menu.width - width - FoamyStyle.gap,
      menu.LayoutMirroring.enabled && menu.anchorItem ? menu.origin.x + menu.anchorItem.width - width : menu.origin.x))
    y: menu.origin.y + FoamyStyle.gapSmall
    width: menu.columns * menu.tileWidth + (menu.columns - 1) * grid.columnSpacing + 2 * FoamyStyle.gapLarge
    height: Math.min(menu.height - y - FoamyStyle.gapLarge, grid.implicitHeight + 2 * FoamyStyle.gapLarge + heading.height)
    radius: FoamyStyle.radius
    color: FoamyPalette.background
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.border
    Accessible.role: Accessible.PopupMenu
    Accessible.name: FoamyI18n.t("studio.presets")

    // Presses inside stay inside.
    MouseArea { anchors.fill: parent }

    Text {
      id: heading
      x: FoamyStyle.gapLarge
      y: FoamyStyle.gapLarge
      width: parent.width - 2 * FoamyStyle.gapLarge
      height: implicitHeight + FoamyStyle.gap
      horizontalAlignment: Text.AlignLeft
      text: FoamyI18n.tn("studio.presetCount", menu.presets.length)
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      font.weight: Font.DemiBold
      font.capitalization: Font.AllUppercase
      font.letterSpacing: 0.6
    }

    Flickable {
      id: list
      x: FoamyStyle.gapLarge
      y: heading.y + heading.height
      width: parent.width - 2 * FoamyStyle.gapLarge
      height: parent.height - y - FoamyStyle.gapLarge
      contentHeight: grid.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Grid {
        id: grid
        columns: menu.columns
        columnSpacing: FoamyStyle.gap
        rowSpacing: FoamyStyle.gap

        Repeater {
          model: menu.presets

          Rectangle {
            id: tile
            required property string modelData
            required property int index
            readonly property bool chosen: modelData === menu.current
            readonly property bool cursorHere: menu.cursor === index
            objectName: "studioPresetItem-" + modelData
            width: menu.tileWidth
            height: menu.tileHeight
            radius: FoamyStyle.radiusSmall
            color: chosen ? FoamyPalette.selectedFill : cursorHere ? FoamyPalette.hoverFill : "transparent"
            border.width: cursorHere ? 2 : chosen ? 1 : 0
            border.color: cursorHere ? FoamyPalette.text : FoamyPalette.accent
            Accessible.role: Accessible.MenuItem
            Accessible.name: label.text
            Accessible.checkable: true
            Accessible.checked: chosen
            Accessible.focused: cursorHere
            Accessible.onPressAction: menu.picked(modelData)

            Image {
              x: 4
              y: 4
              width: parent.width - 8
              height: Math.round(width * 9 / 16)
              source: menu.visible ? Qt.resolvedUrl("previews/presets/" + tile.modelData + ".png") : ""
              sourceSize.width: 224
              sourceSize.height: 126
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
            Text {
              id: label
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: FoamyI18n.t("studio.preset." + tile.modelData)
              elide: Text.ElideRight
              color: tile.chosen ? FoamyPalette.text : FoamyPalette.secondaryText
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.caption
              font.weight: tile.chosen ? Font.DemiBold : Font.Normal
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: menu.cursor = tile.index
              onClicked: menu.picked(tile.modelData)
            }
          }
        }
      }
    }
  }
}
