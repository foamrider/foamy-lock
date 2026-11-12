pragma ComponentBehavior: Bound
import QtQuick
import "kit"

// A choice drawn as tiles: one per style of a module (StyleArt draws each),
// or per background decoration (`element: "decor"`). Ported from the retired
// foamy-lock-studio popup. `value` belongs to the caller; a choice only
// emits picked(value).
//
// Keyboard: Tab focuses the grid on the current choice; the arrow keys
// move the cursor (mirrored right to left), Home and End jump, Enter or
// Space choose. The pointer chooses on click; hover only highlights.
FocusScope {
  id: tiles

  property string element: ""
  property string value: ""
  property var options: []
  // The words for an option (the caller translates).
  property var labelFor: function (name) {
    return name
  }
  property string title: ""
  property int columns: 3
  // The cursor (a tile index) while the grid has the keyboard.
  property int cursor: -1

  readonly property real tileWidth: (width - grid.columnSpacing * (columns - 1)) / columns

  signal picked(string value)

  implicitHeight: grid.implicitHeight
  activeFocusOnTab: true
  onActiveFocusChanged: if (activeFocus && cursor < 0)
    cursor = Math.max(0, options.indexOf(value))
  onElementChanged: cursor = -1

  Accessible.role: Accessible.List
  Accessible.name: title

  function choose(index) {
    if (index >= 0 && index < options.length)
      picked(options[index])
  }

  // Move the cursor by dx columns (on screen) and dy rows.
  function step(dx, dy) {
    var from = cursor >= 0 ? cursor : Math.max(0, options.indexOf(value))
    var next = from
    if (dy !== 0)
      next = from + dy * columns
    else {
      let column = from % columns + dx * (LayoutMirroring.enabled ? -1 : 1)
      if (column >= 0 && column < columns)
        next = from - from % columns + column
    }
    if (next >= 0 && next < options.length)
      cursor = next
    else
      cursor = from
  }

  Keys.onPressed: function (event) {
    switch (event.key) {
    case Qt.Key_Left:
      step(-1, 0)
      break
    case Qt.Key_Right:
      step(1, 0)
      break
    case Qt.Key_Up:
      step(0, -1)
      break
    case Qt.Key_Down:
      step(0, 1)
      break
    case Qt.Key_Home:
      cursor = 0
      break
    case Qt.Key_End:
      cursor = options.length - 1
      break
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space:
      choose(cursor >= 0 ? cursor : options.indexOf(value))
      break
    default:
      return
    }
    event.accepted = true
  }

  Grid {
    id: grid
    width: parent.width
    columns: tiles.columns
    columnSpacing: FoamyStyle.gapSmall
    rowSpacing: FoamyStyle.gapSmall

    Repeater {
      model: tiles.options

      Rectangle {
        id: tile
        required property string modelData
        required property int index
        readonly property bool chosen: modelData === tiles.value
        readonly property bool cursorHere: tiles.activeFocus && tiles.cursor === index
        objectName: "studioTile-" + modelData
        width: tiles.tileWidth
        height: art.height + name.implicitHeight + FoamyStyle.gapSmall * 2 + FoamyStyle.gapTiny
        radius: FoamyStyle.radiusSmall
        color: chosen ? FoamyPalette.selectedFill : mouse.containsMouse ? FoamyPalette.hoverFill : FoamyPalette.fieldFill
        border.width: cursorHere ? 2 : FoamyStyle.borderWidth
        border.color: cursorHere ? FoamyPalette.text : chosen ? FoamyPalette.accent : FoamyPalette.border

        Accessible.role: Accessible.RadioButton
        Accessible.name: name.text
        Accessible.checkable: true
        Accessible.checked: chosen
        Accessible.focused: cursorHere
        Accessible.onPressAction: tiles.choose(index)

        StyleArt {
          id: art
          x: FoamyStyle.gapSmall
          y: FoamyStyle.gapSmall
          width: parent.width - FoamyStyle.gapSmall * 2
          height: Math.round(width / 2)
          element: tiles.element
          styleName: tile.modelData
          ink: tile.chosen ? FoamyPalette.accent : FoamyPalette.text
        }
        Text {
          id: name
          anchors.top: art.bottom
          anchors.topMargin: FoamyStyle.gapTiny
          x: FoamyStyle.gapTiny
          width: parent.width - FoamyStyle.gapTiny * 2
          text: tiles.labelFor(tile.modelData)
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          color: tile.chosen ? FoamyPalette.text : FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.caption
          font.weight: tile.chosen ? Font.DemiBold : Font.Normal
        }
        MouseArea {
          id: mouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            tiles.cursor = tile.index
            tiles.forceActiveFocus(Qt.MouseFocusReason)
            tiles.choose(tile.index)
          }
        }
      }
    }
  }
}
