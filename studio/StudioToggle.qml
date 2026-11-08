import QtQuick
import "kit"

// A labelled switch: `checked` is bound by the caller, `toggled()` asks for
// the change. Space or Enter flips it.
Item {
  id: toggle

  property string text: ""
  property bool checked: false
  signal toggled()

  implicitHeight: FoamyStyle.controlHeight
  implicitWidth: row.implicitWidth
  activeFocusOnTab: true

  Accessible.role: Accessible.CheckBox
  Accessible.name: text
  Accessible.checkable: true
  Accessible.checked: checked
  Accessible.onPressAction: toggled()
  Accessible.onToggleAction: toggled()
  Keys.onSpacePressed: toggled()
  Keys.onReturnPressed: toggled()

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: FoamyStyle.gap

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: toggle.text
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
    }

    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: 30
      height: 17
      radius: FoamyStyle.pillRadius(height)
      color: toggle.checked ? FoamyPalette.accent : FoamyPalette.fieldFill
      border.width: toggle.activeFocus ? 2 : FoamyStyle.borderWidth
      border.color: toggle.activeFocus ? FoamyPalette.accent : FoamyPalette.border

      Rectangle {
        width: 13
        height: 13
        radius: FoamyStyle.pillRadius(height)
        anchors.verticalCenter: parent.verticalCenter
        // The knob follows the reading direction (mirrored with the layout).
        x: (toggle.checked !== toggle.LayoutMirroring.enabled) ? track.width - width - 2 : 2
        color: toggle.checked ? FoamyPalette.onAccent : FoamyPalette.mutedText
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      toggle.forceActiveFocus(Qt.MouseFocusReason)
      toggle.toggled()
    }
  }
}
