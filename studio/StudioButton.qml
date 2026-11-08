import QtQuick
import "kit"

// A form button in the foamy look (DESIGN.md "Buttons"): secondary (field
// fill and border) or primary (accent fill, one per form). `checked` marks
// a selected entry in a list of buttons. Enter or Space activates it; the
// focus ring always shows.
Rectangle {
  id: button

  property string text: ""
  property string detail: ""
  property bool primary: false
  property bool checked: false
  property int horizontalAlignment: Text.AlignHCenter
  signal clicked()

  implicitHeight: FoamyStyle.controlHeight
  implicitWidth: row.implicitWidth + 2 * FoamyStyle.controlPaddingX
  radius: FoamyStyle.radiusSmall
  color: primary ? FoamyPalette.accent
    : checked ? FoamyPalette.selectedFill
    : mouse.containsMouse && enabled ? FoamyPalette.hoverFill : FoamyPalette.fieldFill
  border.width: activeFocus ? 2 : primary ? 0 : FoamyStyle.borderWidth
  border.color: activeFocus || checked ? FoamyPalette.accent : FoamyPalette.border
  opacity: enabled ? 1 : FoamyStyle.disabledOpacity
  activeFocusOnTab: enabled

  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.description: detail
  Accessible.checkable: checked
  Accessible.checked: checked
  Accessible.onPressAction: if (enabled) clicked()
  Keys.onReturnPressed: if (enabled) clicked()
  Keys.onEnterPressed: if (enabled) clicked()
  Keys.onSpacePressed: if (enabled) clicked()

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    x: button.horizontalAlignment === Text.AlignHCenter ? (button.width - width) / 2 : FoamyStyle.controlPaddingX
    width: button.horizontalAlignment === Text.AlignHCenter ? implicitWidth : button.width - 2 * FoamyStyle.controlPaddingX
    spacing: FoamyStyle.gap

    Text {
      id: label
      width: button.horizontalAlignment === Text.AlignHCenter || !button.detail ? implicitWidth
        : Math.min(implicitWidth, row.width - detailLabel.implicitWidth - row.spacing)
      text: button.text
      elide: Text.ElideRight
      color: button.primary ? FoamyPalette.onAccent : FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      font.weight: button.primary ? Font.DemiBold : Font.Normal
    }

    Text {
      id: detailLabel
      visible: button.detail !== ""
      width: button.horizontalAlignment === Text.AlignHCenter ? implicitWidth : row.width - label.width - row.spacing
      text: button.detail
      elide: Text.ElideRight
      horizontalAlignment: button.horizontalAlignment === Text.AlignHCenter ? Text.AlignLeft : Text.AlignRight
      color: button.primary ? FoamyPalette.onAccent : FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: button.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      button.forceActiveFocus(Qt.MouseFocusReason)
      button.clicked()
    }
  }
}
