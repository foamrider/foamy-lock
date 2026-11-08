import QtQuick
import "kit"

// A form button in the foamy look (DESIGN.md "Buttons"): secondary (field
// fill and border) or primary (accent fill, one per form). `checked` marks
// a selected entry in a list of buttons. Enter or Space activates it; the
// focus ring always shows (outside a primary button).
Rectangle {
  id: button

  property string text: ""
  property string detail: ""
  property bool primary: false
  property bool checked: false
  property int horizontalAlignment: Text.AlignHCenter
  // Room before the label on the reading start (a list row's grip).
  property real leading: 0
  signal clicked()

  implicitHeight: FoamyStyle.controlHeight
  implicitWidth: row.implicitWidth + 2 * FoamyStyle.controlPaddingX
  radius: FoamyStyle.radiusSmall
  color: primary ? FoamyPalette.accent
    : checked ? FoamyPalette.selectedFill
    : mouse.containsMouse && enabled ? FoamyPalette.hoverFill : FoamyPalette.fieldFill
  border.width: primary ? 0 : activeFocus ? 2 : FoamyStyle.borderWidth
  border.color: activeFocus || checked ? FoamyPalette.accent : FoamyPalette.border
  opacity: enabled ? 1 : FoamyStyle.disabledOpacity
  activeFocusOnTab: enabled

  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.description: detail
  // A list row or page chosen; a checkable one (a radio button) says
  // checked instead.
  Accessible.selected: checked && !Accessible.checkable
  Accessible.checked: checked
  Accessible.onPressAction: if (enabled) clicked()
  Keys.onReturnPressed: if (enabled) clicked()
  Keys.onEnterPressed: if (enabled) clicked()
  Keys.onSpacePressed: if (enabled) clicked()

  // The accent fill would hide a ring on it: a primary button's focus ring
  // sits just outside.
  Rectangle {
    visible: button.primary && button.activeFocus
    anchors.fill: parent
    anchors.margins: -3
    radius: button.radius + 3
    color: "transparent"
    border.width: 2
    border.color: FoamyPalette.accent
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    x: button.horizontalAlignment === Text.AlignHCenter ? (button.width - width) / 2
      : FoamyStyle.controlPaddingX + (button.LayoutMirroring.enabled ? 0 : button.leading)
    width: button.horizontalAlignment === Text.AlignHCenter ? implicitWidth : button.width - 2 * FoamyStyle.controlPaddingX - button.leading
    spacing: FoamyStyle.gap

    Text {
      id: label
      // The label never gives way to the value: the value elides first.
      width: button.horizontalAlignment === Text.AlignHCenter ? implicitWidth : Math.min(implicitWidth, row.width)
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
      width: button.horizontalAlignment === Text.AlignHCenter ? implicitWidth : Math.max(0, row.width - label.width - row.spacing)
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
