import QtQuick
import qs.Commons
import "kit"

// A slider row: the label on the reading start, the track, and the value
// on the end. `value` is the caller's: dragging emits moved(value) as it
// goes (for a live preview) and committed(value) once on release, so a
// drag is one undo step; keys commit each step. Right to left, the track
// runs from the end (mirrored, as the layout is).
//
// Keys: Left/Right and Down/Up one step, Page Down/Up ten, Home/End the
// ends. The keyboard cursor rings the thumb and turns the track accent
// (DESIGN.md "Sliders"); there is no row fill.
FocusScope {
  id: slider

  property string label: ""
  property real value: 0
  property real from: 0
  property real to: 1
  property real stepSize: 0.05
  // The value in words (the caller formats it, e.g. "120 %").
  property string valueText: ""
  property real labelWidth: 64
  // The value shown while a drag is in progress (NaN otherwise).
  property real dragValue: NaN

  readonly property real shown: isNaN(dragValue) ? value : dragValue
  readonly property real fraction: to > from ? Math.max(0, Math.min(1, (shown - from) / (to - from))) : 0
  readonly property bool mirrored: LayoutMirroring.enabled

  signal moved(real value)
  signal committed(real value)

  implicitHeight: FoamyStyle.controlHeight
  activeFocusOnTab: enabled
  opacity: enabled ? 1 : FoamyStyle.disabledOpacity

  Accessible.role: Accessible.Slider
  Accessible.name: label
  Accessible.description: valueText
  Accessible.onIncreaseAction: slider.stepBy(1)
  Accessible.onDecreaseAction: slider.stepBy(-1)

  function clean(v) {
    var stepped = stepSize > 0 ? from + Math.round((v - from) / stepSize) * stepSize : v
    return Math.max(from, Math.min(to, Math.round(stepped * 1e6) / 1e6))
  }

  function stepBy(steps) {
    var next = clean(value + steps * stepSize)
    if (next !== value) committed(next)
  }

  // The value at x (pixels in the track).
  function valueAt(x) {
    var f = Math.max(0, Math.min(1, x / Math.max(1, track.width)))
    return clean(from + (mirrored ? 1 - f : f) * (to - from))
  }

  Keys.onPressed: function(event) {
    var forward = slider.mirrored ? -1 : 1
    switch (event.key) {
    case Qt.Key_Right: stepBy(forward); break
    case Qt.Key_Left: stepBy(-forward); break
    case Qt.Key_Up: stepBy(1); break
    case Qt.Key_Down: stepBy(-1); break
    case Qt.Key_PageUp: stepBy(10); break
    case Qt.Key_PageDown: stepBy(-10); break
    case Qt.Key_Home: if (value !== from) committed(from); break
    case Qt.Key_End: if (value !== to) committed(to); break
    default: return
    }
    event.accepted = true
  }

  Text {
    id: name
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: slider.labelWidth
    text: slider.label
    horizontalAlignment: Text.AlignLeft
    elide: Text.ElideRight
    color: FoamyPalette.secondaryText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
  }

  Text {
    id: readout
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(44)
    text: slider.valueText
    horizontalAlignment: Text.AlignRight
    color: FoamyPalette.text
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
  }

  Item {
    id: track
    anchors.left: name.right
    anchors.leftMargin: FoamyStyle.gap
    anchors.right: readout.left
    anchors.rightMargin: FoamyStyle.gap
    anchors.verticalCenter: parent.verticalCenter
    height: thumb.height

    Rectangle {
      id: groove
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 4
      radius: FoamyStyle.rounded ? 2 : 0
      color: FoamyPalette.fieldFill
      border.width: FoamyStyle.borderWidth
      border.color: FoamyPalette.border

      Rectangle {
        // Filled from the reading start (mirrored with the layout).
        anchors.left: parent.left
        height: parent.height
        width: parent.width * slider.fraction
        radius: parent.radius
        color: slider.activeFocus || drag.pressed ? FoamyPalette.accent : Qt.alpha(FoamyPalette.accent, 0.7)
      }
    }

    Rectangle {
      id: thumb
      objectName: "studioSliderThumb"
      width: 14
      height: 14
      radius: FoamyStyle.rounded ? width / 2 : 2
      anchors.verticalCenter: parent.verticalCenter
      x: (slider.mirrored ? 1 - slider.fraction : slider.fraction) * (track.width - width)
      color: FoamyPalette.text
      border.width: slider.activeFocus ? 3 : FoamyStyle.borderWidth
      border.color: slider.activeFocus ? FoamyPalette.accent : FoamyPalette.border
    }

    MouseArea {
      id: drag
      anchors.fill: parent
      anchors.topMargin: -6
      anchors.bottomMargin: -6
      enabled: slider.enabled
      cursorShape: Qt.PointingHandCursor
      preventStealing: true
      onPressed: function(mouse) {
        slider.forceActiveFocus(Qt.MouseFocusReason)
        slider.dragValue = slider.valueAt(mouse.x)
        slider.moved(slider.dragValue)
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var next = slider.valueAt(mouse.x)
        if (next !== slider.dragValue) {
          slider.dragValue = next
          slider.moved(next)
        }
      }
      onReleased: {
        var final = slider.dragValue
        slider.dragValue = NaN
        if (!isNaN(final)) slider.committed(final)
      }
      onCanceled: {
        slider.dragValue = NaN
        slider.committed(slider.value)
      }
    }
  }
}
