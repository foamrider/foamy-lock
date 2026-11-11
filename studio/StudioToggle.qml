import QtQuick
import qs.Commons
import qs.Commons as Commons
import "kit"

// A labelled switch: the label on the reading start, the switch on the
// end. Its shape is the shell's own (Ui/ToggleSwitch, which the kit's
// FoamyToggle uses): a knob thrown to the end when on, pill-shaped when
// Hyprland's corners are rounded, square when they're sharp; off, the
// theme's "normal" control fill and border. On, the track is the accent
// with the accent's own text colour for the knob: the theme's "selected"
// state is often a faint grey (Catppuccin's is the foreground at 18 %),
// too close to off for a switch that has no other sign of its state. The
// app's root has no `qs.Ui`, so it is drawn here from the Commons tokens.
//
// `checked` is bound by the caller, `toggled()` asks for the change. Space
// or Enter flips it; focus draws a ring around the switch.
Item {
  id: toggle

  property string text: ""
  property bool checked: false
  // The label on the reading start (false: the switch alone).
  property bool showLabel: true
  signal toggled

  readonly property bool mirrored: LayoutMirroring.enabled
  readonly property color foreground: FoamyPalette.text
  readonly property color accent: FoamyPalette.accent
  readonly property int trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.55))
  readonly property int trackWidth: Math.round(trackHeight * 1.9)
  readonly property int knobSize: Math.max(6, Math.round(trackHeight * 0.72))
  readonly property int knobInset: Math.max(1, Math.round((trackHeight - knobSize) / 2))
  readonly property var borderSpec: Commons.Border.controlSpec("normal", foreground, accent)
  readonly property alias switchItem: track

  implicitHeight: FoamyStyle.controlHeight
  implicitWidth: (showLabel ? label.implicitWidth + FoamyStyle.gap : 0) + trackWidth + 6
  activeFocusOnTab: true

  Accessible.role: Accessible.CheckBox
  Accessible.name: text
  Accessible.checkable: true
  Accessible.checked: checked
  Accessible.onPressAction: toggled()
  Accessible.onToggleAction: toggled()
  Keys.onSpacePressed: toggled()
  Keys.onReturnPressed: toggled()
  Keys.onEnterPressed: toggled()

  Text {
    id: label
    textFormat: Text.PlainText
    visible: toggle.showLabel
    anchors.left: parent.left
    anchors.right: ring.left
    anchors.rightMargin: FoamyStyle.gap
    anchors.verticalCenter: parent.verticalCenter
    text: toggle.text
    horizontalAlignment: Text.AlignLeft
    elide: Text.ElideRight
    color: FoamyPalette.secondaryText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
  }

  // Hover and focus: a ring outside the track, as the shell's cursor ring.
  Rectangle {
    id: ring
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: toggle.trackWidth + 6
    height: toggle.trackHeight + 6
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: "transparent"
    border.width: toggle.activeFocus ? 2 : mouse.containsMouse ? 1 : 0
    border.color: toggle.activeFocus ? toggle.accent : FoamyPalette.border

    Rectangle {
      id: track
      anchors.centerIn: parent
      width: toggle.trackWidth
      height: toggle.trackHeight
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: toggle.checked ? toggle.accent : Style.normalFillFor(toggle.foreground, toggle.accent)
      border.width: toggle.checked ? 0 : Commons.Border.uniformWidth(toggle.borderSpec)
      border.color: Commons.Border.color(toggle.borderSpec)

      Rectangle {
        objectName: "studioToggleKnob"
        width: toggle.knobSize
        height: toggle.knobSize
        radius: Style.cornerRadius > 0 ? height / 2 : 0
        anchors.verticalCenter: parent.verticalCenter
        // Thrown to the reading end when on (mirrored right to left).
        x: toggle.checked !== toggle.mirrored ? track.width - width - toggle.knobInset : toggle.knobInset
        color: toggle.checked ? FoamyPalette.onAccent : Qt.darker(toggle.foreground, 1.25)
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      toggle.forceActiveFocus(Qt.MouseFocusReason)
      toggle.toggled()
    }
  }
}
