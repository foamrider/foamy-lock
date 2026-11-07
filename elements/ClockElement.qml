import QtQuick

// The clock. Styles: "thin" (the large display numerals) and "bold" (heavier
// and tighter). The host sets the width in the center column; the numerals
// shrink to fit it.
Text {
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "thin"
  readonly property bool bold: styleName === "bold"
  // Stacked under another element, the numerals' top bearing would leave a
  // gap: pull the clock up instead of the zone's usual spacing.
  readonly property real stackGap: Math.round((bold ? -12 : -20) * view.uiScale)

  objectName: "clockLabel"
  textFormat: Text.PlainText
  text: view.userLocale.toString(view.now, view.timeFormat === "12h" ? "h:mm AP" : "HH:mm")
  fontSizeMode: Text.Fit
  minimumPixelSize: Math.round(48 * view.uiScale)
  color: view.foreground
  font.family: bold ? view.textFontFamily : view.displayFontFamily
  font.pixelSize: Math.round((bold ? 150 : 192) * view.uiScale)
  font.weight: bold ? Font.Bold : Font.Normal
  font.letterSpacing: bold ? Math.round(-4 * view.uiScale) : 0
  horizontalAlignment: alignment === "start" ? Text.AlignLeft : alignment === "end" ? Text.AlignRight : Text.AlignHCenter
}
