import QtQuick

// The large clock. The host sets the width; the numerals shrink to fit it.
Text {
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view

  objectName: "clockLabel"
  textFormat: Text.PlainText
  text: view.userLocale.toString(view.now, view.timeFormat === "12h" ? "h:mm AP" : "HH:mm")
  fontSizeMode: Text.Fit
  minimumPixelSize: Math.round(48 * view.uiScale)
  color: view.foreground
  font.family: view.displayFontFamily
  font.pixelSize: Math.round(192 * view.uiScale)
  font.weight: Font.Normal
  horizontalAlignment: Text.AlignHCenter
}
