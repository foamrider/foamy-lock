import QtQuick

// The date. Styles: "long" (the weekday, day and month in the display face)
// and "caps" (shorter, spaced capitals in the text face). The host sets the
// width in the center column; elsewhere it is the text's own width.
Text {
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "long"
  readonly property bool caps: styleName === "caps"

  objectName: "dateLabel"
  textFormat: Text.PlainText
  text: caps
    ? view.now.toLocaleString(view.userLocale, "dddd d MMMM").toLocaleUpperCase()
    : view.now.toLocaleString(view.userLocale, "dddd, d MMMM")
  color: view.foreground
  opacity: caps ? 0.86 : 1
  font.family: caps ? view.textFontFamily : view.displayFontFamily
  font.pixelSize: Math.round((caps ? 17 : 30) * view.uiScale)
  font.weight: caps ? Font.Medium : Font.Normal
  font.letterSpacing: caps ? Math.round(3 * view.uiScale) : 0
  horizontalAlignment: alignment === "start" ? Text.AlignLeft : alignment === "end" ? Text.AlignRight : Text.AlignHCenter
  elide: Text.ElideRight
}
