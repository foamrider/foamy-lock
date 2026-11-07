import QtQuick

// The date line above the clock. The host sets the width.
Text {
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view

  objectName: "dateLabel"
  textFormat: Text.PlainText
  text: view.now.toLocaleString(view.userLocale, "dddd, d MMMM")
  color: view.foreground
  font.family: view.displayFontFamily
  font.pixelSize: Math.round(30 * view.uiScale)
  font.weight: Font.Normal
  horizontalAlignment: Text.AlignHCenter
  elide: Text.ElideRight
}
