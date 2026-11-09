import QtQuick
import "kit"

// A short note in a pane: one wrapped line or two, bodySmall, muted, on
// the reading start.
Text {
  textFormat: Text.PlainText
  width: parent ? parent.width : implicitWidth
  visible: text !== ""
  horizontalAlignment: Text.AlignLeft
  wrapMode: Text.Wrap
  color: FoamyPalette.mutedText
  font.family: FoamyStyle.fontFamily
  font.pixelSize: FoamyStyle.font.bodySmall
  Accessible.role: Accessible.StaticText
  Accessible.name: text
}
