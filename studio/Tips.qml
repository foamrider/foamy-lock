pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit"

// The tips card, pinned to the bottom edge of the library pane (the module
// list scrolls above it): one tip at a time, with small previous and next
// buttons under it (wrapping). Tips are words only; nothing here starts
// another app. The first tip is about the picture and name the lock screen
// shows, which come from the account (AccountsService and ~/.face, what
// Mugshot writes); without Mugshot installed it says how to install it.
// The tip seen last is kept in the app's state (LockSources.setTip), so
// the next start shows it again.
Rectangle {
  id: tips

  // LockSources: tip, setTip(), mugshotAvailable.
  property var sources: null
  // Only what isn't obvious from the app itself.
  readonly property var ids: ["mugshot", "drag", "keys"]
  readonly property string current: sources && ids.indexOf(sources.tip) !== -1 ? sources.tip : ids[0]
  readonly property int index: Math.max(0, ids.indexOf(current))
  readonly property string text: tipText(current)

  implicitHeight: column.implicitHeight + 2 * FoamyStyle.gapLarge
  color: FoamyPalette.menuFill

  Accessible.role: Accessible.Grouping
  Accessible.name: FoamyI18n.t("studio.tips")

  function tipText(id) {
    if (id === "mugshot" && !(sources && sources.mugshotAvailable)) return FoamyI18n.t("studio.tip.mugshotMissing")
    return FoamyI18n.t("studio.tip." + id)
  }

  // The tip `step` away from this one (wrapping), remembered.
  function go(step) {
    var count = ids.length
    if (sources) sources.setTip(ids[((index + step) % count + count) % count])
  }

  // A small ghost button: no surface until hovered, an accent ring with
  // the keyboard; Enter or Space presses it.
  component GhostButton: Rectangle {
    id: ghost
    property string icon: ""
    property string name: ""
    signal clicked()
    implicitWidth: FoamyStyle.actionSize
    implicitHeight: FoamyStyle.actionSize
    radius: FoamyStyle.radiusSmall
    color: ghostMouse.pressed ? FoamyPalette.selectedFill : ghostMouse.containsMouse ? FoamyPalette.hoverFill : "transparent"
    border.width: activeFocus ? 2 : 0
    border.color: FoamyPalette.accent
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: name
    Accessible.onPressAction: ghost.clicked()
    Keys.onReturnPressed: ghost.clicked()
    Keys.onEnterPressed: ghost.clicked()
    Keys.onSpacePressed: ghost.clicked()
    FoamyIcon {
      id: ghostIcon
      anchors.centerIn: parent
      width: FoamyStyle.iconSize
      height: width
      name: ghost.icon
      color: ghostMouse.containsMouse || ghost.activeFocus ? FoamyPalette.text : FoamyPalette.secondaryText
    }
    MouseArea {
      id: ghostMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ghost.clicked()
    }
  }

  // The hairline between it and the list.
  Rectangle {
    width: parent.width
    height: 1
    color: FoamyPalette.divider
  }

  Column {
    id: column
    x: FoamyStyle.gapLarge
    y: FoamyStyle.gapLarge
    width: parent.width - 2 * FoamyStyle.gapLarge
    spacing: FoamyStyle.gap

    RowLayout {
      width: parent.width
      spacing: FoamyStyle.gapSmall

      // Sized by the layout, not by its picture (whose size follows its own).
      FoamyIcon {
        name: "info"
        color: FoamyPalette.accent
        Layout.preferredWidth: FoamyStyle.iconSize
        Layout.preferredHeight: FoamyStyle.iconSize
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: FoamyI18n.t("studio.tip")
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.mutedText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.caption
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        elide: Text.ElideRight
        Accessible.role: Accessible.Heading
        Accessible.name: text
      }
      Text {
        objectName: "studioTipCount"
        textFormat: Text.PlainText
        text: FoamyI18n.t("studio.tip.count", [FoamyI18n.number(tips.index + 1, 0), FoamyI18n.number(tips.ids.length, 0)])
        color: FoamyPalette.mutedText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.caption
      }
    }

    // Every tip is laid out, the others transparent, so the card keeps the
    // height of the longest and the list above doesn't move when paging.
    Item {
      id: tipBox
      width: parent.width
      height: childrenRect.height

      Repeater {
        model: tips.ids
        Text {
          required property string modelData
          textFormat: Text.PlainText
          readonly property bool shown: modelData === tips.current
          objectName: shown ? "studioTipText" : ""
          width: tipBox.width
          opacity: shown ? 1 : 0
          text: tips.tipText(modelData)
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.Wrap
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.bodySmall
          Accessible.role: Accessible.StaticText
          Accessible.name: text
          Accessible.ignored: !shown
        }
      }
    }

    // Previous and next, under the tip.
    Row {
      id: paging
      spacing: FoamyStyle.gapSmall
      GhostButton {
        objectName: "studioTipPrevious"
        icon: "chevron-left"
        name: FoamyI18n.t("studio.tip.previous")
        onClicked: tips.go(-1)
      }
      GhostButton {
        objectName: "studioTipNext"
        icon: "chevron-right"
        name: FoamyI18n.t("studio.tip.next")
        onClicked: tips.go(1)
      }
    }
  }
}
