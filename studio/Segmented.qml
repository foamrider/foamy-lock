pragma ComponentBehavior: Bound
import QtQuick
import "kit"

// A segmented choice: `options` is [{ value, label }], `value` is bound by
// the caller and `picked(value)` asks for a change (it never assigns
// `value` itself). Left and Right move the choice (mirrored right-to-left).
// `caption` (optional) titles the group inside it, before the first segment.
Rectangle {
  id: control

  property var options: []
  property var value
  property string name: ""
  property string caption: ""
  signal picked(var value)

  implicitHeight: FoamyStyle.controlHeight
  implicitWidth: segments.implicitWidth + 4
  radius: FoamyStyle.radiusSmall
  color: FoamyPalette.fieldFill
  border.width: activeFocus ? 2 : FoamyStyle.borderWidth
  border.color: activeFocus ? FoamyPalette.accent : FoamyPalette.border
  activeFocusOnTab: options.length > 0

  Accessible.role: Accessible.PageTabList
  Accessible.name: name

  function indexOf(value) {
    for (var i = 0; i < options.length; i++) if (options[i].value === value) return i
    return -1
  }

  function step(direction) {
    if (options.length === 0) return
    var index = Math.max(0, indexOf(value))
    var next = Math.max(0, Math.min(options.length - 1, index + direction))
    if (next !== index) picked(options[next].value)
  }

  Keys.onLeftPressed: step(LayoutMirroring.enabled ? 1 : -1)
  Keys.onRightPressed: step(LayoutMirroring.enabled ? -1 : 1)

  Row {
    id: segments
    anchors.centerIn: parent
    spacing: 0

    Text {
      objectName: "segmentedCaption"
      visible: control.caption !== ""
      height: control.height - 4
      leftPadding: FoamyStyle.controlPaddingX
      rightPadding: FoamyStyle.gap
      verticalAlignment: Text.AlignVCenter
      text: control.caption
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      font.weight: Font.DemiBold
      font.capitalization: Font.AllUppercase
      font.letterSpacing: 0.6
    }

    Repeater {
      model: control.options

      Rectangle {
        id: segment
        required property var modelData
        readonly property bool selected: control.value === modelData.value
        height: control.height - 4
        width: segmentLabel.implicitWidth + 2 * FoamyStyle.controlPaddingX
        radius: Math.max(0, FoamyStyle.radiusSmall - 2)
        color: selected ? FoamyPalette.selectedFill : segmentMouse.containsMouse ? FoamyPalette.hoverFill : "transparent"

        Accessible.role: Accessible.PageTab
        Accessible.name: modelData.label
        Accessible.selected: selected
        Accessible.onPressAction: control.picked(modelData.value)

        Text {
          id: segmentLabel
          anchors.centerIn: parent
          text: segment.modelData.label
          color: segment.selected ? FoamyPalette.text : FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
          font.weight: segment.selected ? Font.DemiBold : Font.Normal
        }

        MouseArea {
          id: segmentMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            control.forceActiveFocus(Qt.MouseFocusReason)
            control.picked(segment.modelData.value)
          }
        }
      }
    }
  }
}
