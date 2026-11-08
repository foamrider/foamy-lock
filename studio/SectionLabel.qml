import QtQuick
import "kit"

// A section's title in a pane: caption, capitals, muted, on the reading
// start.
Text {
  textFormat: Text.PlainText
  width: parent ? parent.width : implicitWidth
  horizontalAlignment: Text.AlignLeft
  color: FoamyPalette.mutedText
  font.family: FoamyStyle.fontFamily
  font.pixelSize: FoamyStyle.font.caption
  font.weight: Font.DemiBold
  font.capitalization: Font.AllUppercase
  font.letterSpacing: 0.6
  bottomPadding: FoamyStyle.gapTiny
  Accessible.role: Accessible.Heading
  Accessible.name: text
}
