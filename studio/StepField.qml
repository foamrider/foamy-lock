pragma ComponentBehavior: Bound
import QtQuick
import "kit"

// A number in grid steps with − and + on either side, and its pixels after
// it: an offset's X or Y in the inspector. `value` is the caller's (steps,
// one decimal); committed(steps) asks for a change. Typing a number and
// Enter (or leaving the field) commits it; Esc puts the value back.
// Up/Down step by one, Page Up/Down by five, on the field and on the
// buttons alike. Never takes the keyboard by itself.
FocusScope {
  id: field

  property string label: ""
  // The accessible name (e.g. "Offset X").
  property string name: label
  property real value: 0
  // The value in pixels, in words ("45 px").
  property string detail: ""

  signal committed(real value)

  implicitHeight: FoamyStyle.controlHeight - 6
  implicitWidth: row.implicitWidth

  Accessible.role: Accessible.SpinBox
  Accessible.name: name
  Accessible.description: detail
  Accessible.onIncreaseAction: field.stepBy(1)
  Accessible.onDecreaseAction: field.stepBy(-1)

  function format(v) {
    return FoamyI18n.number(v, Math.round(v) === v ? 0 : 1)
  }

  // The typed text as steps (one decimal), or NaN.
  function parse(text) {
    var cleaned = String(text).trim().replace(/\u2212/g, "-").replace(",", ".")
    if (!/^[-+]?\d{1,3}(\.\d*)?$/.test(cleaned)) return NaN
    return Math.round(Number(cleaned) * 10) / 10
  }

  function stepBy(steps) {
    committed(Math.round((value + steps) * 10) / 10)
  }

  function keyStep(event) {
    var steps = { }
    steps[Qt.Key_Up] = 1
    steps[Qt.Key_Down] = -1
    steps[Qt.Key_PageUp] = 5
    steps[Qt.Key_PageDown] = -5
    if (steps[event.key] === undefined) return false
    stepBy(steps[event.key])
    return true
  }

  Row {
    id: row
    height: parent.height
    spacing: FoamyStyle.gapTiny

    Text {
      textFormat: Text.PlainText
      width: FoamyStyle.unitWidthCompact
      height: parent.height
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignLeft
      text: field.label
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
    }

    StepButton { text: "\u2212"; steps: -1; name: FoamyI18n.t("studio.less", field.name) }

    Rectangle {
      width: 44
      height: parent.height
      radius: FoamyStyle.radiusSmall
      color: FoamyPalette.fieldFill
      border.width: input.activeFocus ? 2 : FoamyStyle.borderWidth
      border.color: input.activeFocus ? FoamyPalette.accent : FoamyPalette.border

      TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: FoamyStyle.gapSmall
        anchors.rightMargin: FoamyStyle.gapSmall
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnTab: true
        selectByMouse: true
        clip: true
        maximumLength: 7
        color: FoamyPalette.text
        selectionColor: FoamyPalette.selectedFill
        selectedTextColor: FoamyPalette.text
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.body
        Accessible.role: Accessible.EditableText
        Accessible.name: field.name

        // Shows the value whenever it isn't being typed in.
        Binding on text {
          value: field.format(field.value)
          when: !input.activeFocus
        }
        onActiveFocusChanged: if (activeFocus) selectAll()
        onEditingFinished: {
          var steps = field.parse(text)
          if (!isNaN(steps) && steps !== field.value) field.committed(steps)
          else text = field.format(field.value)
        }
        Keys.onEscapePressed: function(event) {
          text = field.format(field.value)
          selectAll()
          event.accepted = true
        }
        Keys.onPressed: function(event) {
          if (field.keyStep(event)) {
            event.accepted = true
            // After the caller has taken the new value.
            Qt.callLater(function() {
              input.text = field.format(field.value)
              input.selectAll()
            })
          }
        }
      }
    }

    StepButton { text: "+"; steps: 1; name: FoamyI18n.t("studio.more", field.name) }

    Text {
      textFormat: Text.PlainText
      height: parent.height
      leftPadding: FoamyStyle.gapSmall
      verticalAlignment: Text.AlignVCenter
      text: field.detail
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }
  }

  component StepButton: Rectangle {
    id: button
    property string text: ""
    property string name: ""
    property int steps: 1
    width: height
    height: row.height
    radius: FoamyStyle.radiusSmall
    color: buttonMouse.containsMouse ? FoamyPalette.hoverFill : "transparent"
    border.width: activeFocus ? 2 : 0
    border.color: FoamyPalette.accent
    activeFocusOnTab: false
    Accessible.role: Accessible.Button
    Accessible.name: name
    Accessible.onPressAction: field.stepBy(steps)

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: button.text
      color: FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.subtitle
    }
    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: field.stepBy(button.steps)
    }
  }
}
