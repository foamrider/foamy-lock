pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit"
import "Layout.js" as LockLayout

// The preset menu: your own presets first ("Your presets", newest first),
// then every built-in preset ("Built-in"), each as a thumbnail
// (previews/presets/<name>.png; a user preset shows its built-in preset's)
// with its name, the current one marked. An overlay inside the window,
// dropped from the library's preset row (`anchorItem`) on the reading
// start; a press outside or Esc closes it.
//
// "Your presets" has "Save as new…" (the draft as a new preset, named
// first) and, on each preset, rename and delete (which asks first, in the
// window). Without user presets it says where they will show.
//
// Keyboard: it takes the keys while open; the arrow keys move the cursor
// through both sections (mirrored right to left), Home and End jump, Enter
// or Space pick, F2 renames and Delete deletes the user preset under the
// cursor. picked(name) asks for a built-in preset, pickedUser(id) for a
// user preset; closed() when it should go.
FocusScope {
  id: menu

  property Item anchorItem: null
  // The current preset: a built-in's name, or "user:<id>".
  property string current: ""
  property int cursor: 0
  // "Save as new…" can run.
  property bool canSave: true
  // The button's bottom-left corner in this item, taken when it opens.
  property point origin: Qt.point(0, 0)
  readonly property int columns: 4
  readonly property var presets: LockLayout.SELECTABLE_PRESETS
  // [{ id, name, look, effective }], newest first (LockSources.userPresets).
  property var userPresets: []
  readonly property int userCount: userPresets.length
  readonly property int userRows: Math.ceil(userCount / columns)
  readonly property int count: userCount + presets.length

  signal picked(string name)
  signal pickedUser(string id)
  signal renameRequested(string id)
  signal deleteRequested(string id)
  signal saveAsNewRequested()
  signal closed()

  anchors.fill: parent
  visible: false
  z: 20

  // The entry at `index`: { user: true, id, name, base } or { user: false, name }.
  function entryAt(index) {
    if (index < userCount) {
      var preset = userPresets[index]
      return { user: true, id: preset.id, name: preset.name, base: preset.effective ? preset.effective.preset : "foamy" }
    }
    return { user: false, name: presets[index - userCount] }
  }

  function keyOf(index) {
    var entry = entryAt(index)
    return entry.user ? "user:" + entry.id : entry.name
  }

  function indexOf(key) {
    for (var i = 0; i < count; i++) if (keyOf(i) === key) return i
    return -1
  }

  // Rows: the user section's, then the built-in section's (each starts a row).
  function rowOf(index) {
    return index < userCount ? Math.floor(index / columns) : userRows + Math.floor((index - userCount) / columns)
  }
  function columnOf(index) {
    return index < userCount ? index % columns : (index - userCount) % columns
  }
  // The entry in `row` at `column` (the row's last one when it is short),
  // or -1 past either end.
  function indexAt(row, column) {
    if (row < 0) return -1
    if (row < userRows) return Math.min(row * columns + column, userCount - 1)
    var first = userCount + (row - userRows) * columns
    if (first >= count) return -1
    return Math.min(first + column, count - 1)
  }

  function open() {
    cursor = Math.max(0, indexOf(current))
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

  function tileFor(index) {
    return index < userCount ? userRepeater.itemAt(index) : builtinRepeater.itemAt(index - userCount)
  }

  function ensureShown(index) {
    var tile = tileFor(index)
    if (!tile) return
    var top = tile.mapToItem(content, 0, 0).y
    // A section's first row keeps its heading in view.
    if (rowOf(index) === 0 || rowOf(index) === userRows) top = Math.max(0, top - FoamyStyle.controlHeight - FoamyStyle.gap)
    if (top < list.contentY) list.contentY = top
    else if (top + tileHeight > list.contentY + list.height) list.contentY = top + tileHeight - list.height
  }

  function move(dx, dy) {
    var next = -1
    if (dy !== 0) next = indexAt(rowOf(cursor) + dy, columnOf(cursor))
    else {
      let column = columnOf(cursor) + dx * (LayoutMirroring.enabled ? -1 : 1)
      var rowStart = cursor - columnOf(cursor)
      var rowEnd = Math.min(rowStart + columns, cursor < userCount ? userCount : count)
      if (column >= 0 && rowStart + column < rowEnd) next = rowStart + column
    }
    if (next >= 0 && next < count) {
      cursor = next
      ensureShown(next)
    }
  }

  function pick(index) {
    var entry = entryAt(index)
    if (entry.user) pickedUser(entry.id)
    else picked(entry.name)
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
    case Qt.Key_End: cursor = count - 1; ensureShown(cursor); break
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space: pick(cursor); break
    case Qt.Key_F2: if (cursor < userCount) renameRequested(entryAt(cursor).id); break
    case Qt.Key_Delete: if (cursor < userCount) deleteRequested(entryAt(cursor).id); break
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

  // A small icon action on a user preset's tile.
  component TileAction: Rectangle {
    id: action
    property string icon: ""
    property string name: ""
    signal clicked()
    width: 22
    height: 22
    radius: FoamyStyle.radiusSmall
    color: actionMouse.containsMouse ? FoamyPalette.hoverFill : FoamyPalette.background
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.border
    Accessible.role: Accessible.Button
    Accessible.name: name
    Accessible.onPressAction: action.clicked()
    FoamyIcon {
      anchors.centerIn: parent
      width: 14
      height: 14
      name: action.icon
      color: FoamyPalette.text
    }
    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }

  // One tile: a thumbnail and a name. The delegate says whether it is the
  // current preset and under the cursor, and handles hovered() and
  // activated(); `shown` (the menu is open) loads the thumbnail.
  component Tile: Rectangle {
    id: tile
    property string thumbnail: ""
    property string label: ""
    property string description: ""
    property bool chosen: false
    property bool cursorHere: false
    property bool shown: false
    default property alias actions: actionRow.data
    signal hovered()
    signal activated()
    width: 116
    height: 92
    radius: FoamyStyle.radiusSmall
    color: chosen ? FoamyPalette.selectedFill : cursorHere ? FoamyPalette.hoverFill : "transparent"
    border.width: cursorHere ? 2 : chosen ? 1 : 0
    border.color: cursorHere ? FoamyPalette.text : FoamyPalette.accent
    Accessible.role: Accessible.MenuItem
    Accessible.name: label
    Accessible.description: description
    Accessible.checkable: true
    Accessible.checked: chosen
    Accessible.focused: cursorHere
    Accessible.onPressAction: tile.activated()

    Image {
      x: 4
      y: 4
      width: parent.width - 8
      height: Math.round(width * 9 / 16)
      source: tile.shown && tile.thumbnail ? Qt.resolvedUrl("previews/presets/" + tile.thumbnail + ".png") : ""
      sourceSize.width: 224
      sourceSize.height: 126
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
    }
    Text {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 4
      x: 4
      width: parent.width - 8
      horizontalAlignment: Text.AlignHCenter
      text: tile.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: tile.chosen ? FoamyPalette.text : FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      font.weight: tile.chosen ? Font.DemiBold : Font.Normal
    }
    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: tile.hovered()
      onClicked: tile.activated()
    }
    // On the thumbnail's top end corner, above the tile's own MouseArea.
    Row {
      id: actionRow
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: 6
      spacing: 4
      visible: tileMouse.containsMouse || tile.cursorHere
    }
  }

  component Heading: Text {
    horizontalAlignment: Text.AlignLeft
    color: FoamyPalette.mutedText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.caption
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.6
    elide: Text.ElideRight
  }

  Rectangle {
    id: card
    objectName: "studioPresetMenu"
    // Its start edge on the button's (mirrored right to left), kept inside.
    x: Math.max(FoamyStyle.gap, Math.min(menu.width - width - FoamyStyle.gap,
      menu.LayoutMirroring.enabled && menu.anchorItem ? menu.origin.x + menu.anchorItem.width - width : menu.origin.x))
    y: menu.origin.y + FoamyStyle.gapSmall
    width: menu.columns * menu.tileWidth + (menu.columns - 1) * FoamyStyle.gap + 2 * FoamyStyle.gapLarge
    height: Math.min(menu.height - y - FoamyStyle.gapLarge, content.implicitHeight + 2 * FoamyStyle.gapLarge)
    radius: FoamyStyle.radius
    color: FoamyPalette.background
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.border
    Accessible.role: Accessible.PopupMenu
    Accessible.name: FoamyI18n.t("studio.presets")

    // Presses inside stay inside.
    MouseArea { anchors.fill: parent }

    Flickable {
      id: list
      x: FoamyStyle.gapLarge
      y: FoamyStyle.gapLarge
      width: parent.width - 2 * FoamyStyle.gapLarge
      height: parent.height - 2 * FoamyStyle.gapLarge
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: content
        width: list.width
        spacing: FoamyStyle.gap

        // Your presets.
        RowLayout {
          width: parent.width
          spacing: FoamyStyle.gap
          Heading {
            objectName: "studioPresetsMine"
            Layout.fillWidth: true
            text: FoamyI18n.t("studio.presets.mine")
          }
          FoamyButton {
            objectName: "studioPresetSaveNew"
            text: FoamyI18n.t("studio.presets.saveNew")
            iconName: "plus"
            enabled: menu.canSave
            onClicked: menu.saveAsNewRequested()
          }
        }
        Text {
          objectName: "studioPresetsEmpty"
          visible: menu.userCount === 0
          width: parent.width
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.Wrap
          text: FoamyI18n.t("studio.presets.empty")
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.bodySmall
        }
        Grid {
          visible: menu.userCount > 0
          columns: menu.columns
          columnSpacing: FoamyStyle.gap
          rowSpacing: FoamyStyle.gap

          Repeater {
            id: userRepeater
            model: menu.userPresets

            Tile {
              id: userTile
              required property var modelData
              required property int index
              objectName: "studioUserPreset-" + modelData.id
              chosen: "user:" + modelData.id === menu.current
              cursorHere: menu.cursor === index
              shown: menu.visible
              onHovered: menu.cursor = index
              onActivated: menu.pick(index)
              thumbnail: modelData.effective ? modelData.effective.preset : "foamy"
              label: modelData.name
              description: FoamyI18n.t("studio.presets.basedOn", FoamyI18n.t("studio.preset." + thumbnail))

              TileAction {
                objectName: "studioUserPresetRename-" + userTile.modelData.id
                icon: "pencil"
                name: FoamyI18n.t("studio.presets.rename", userTile.modelData.name)
                onClicked: menu.renameRequested(userTile.modelData.id)
              }
              TileAction {
                objectName: "studioUserPresetDelete-" + userTile.modelData.id
                icon: "trash"
                name: FoamyI18n.t("studio.presets.delete", userTile.modelData.name)
                onClicked: menu.deleteRequested(userTile.modelData.id)
              }
            }
          }
        }

        // Built-in.
        Heading {
          objectName: "studioPresetsBuiltin"
          width: parent.width
          topPadding: FoamyStyle.gapSmall
          text: FoamyI18n.t("studio.presets.builtin")
        }
        Grid {
          columns: menu.columns
          columnSpacing: FoamyStyle.gap
          rowSpacing: FoamyStyle.gap

          Repeater {
            id: builtinRepeater
            model: menu.presets

            Tile {
              required property string modelData
              required property int index
              objectName: "studioPresetItem-" + modelData
              chosen: modelData === menu.current
              cursorHere: menu.cursor === menu.userCount + index
              shown: menu.visible
              onHovered: menu.cursor = menu.userCount + index
              onActivated: menu.pick(menu.userCount + index)
              thumbnail: modelData
              label: FoamyI18n.t("studio.preset." + modelData)
            }
          }
        }
      }
    }
  }
}
