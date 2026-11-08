import QtQuick

// The date. Styles: "long" (the weekday, day and month in the display face),
// "caps" (shorter, spaced capitals in the text face), "short" (abbreviated
// weekday and month, semibold) and "serif" (a large serif weekday over a
// small spaced line with the day, month and year). The host sets the width
// in the center column; elsewhere it is `naturalWidth`.
Item {
  id: date
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // This element's size: the view's scale for its screen (LockView sets it).
  required property real uiScale
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "long"
  readonly property bool caps: styleName === "caps"
  readonly property bool abbreviated: styleName === "short"
  readonly property bool serif: styleName === "serif"
  // The main line, as the tests read it.
  readonly property alias text: label.text
  readonly property alias font: label.font
  readonly property int textAlignment: alignment === "start" ? Text.AlignLeft
    : alignment === "end" ? Text.AlignRight : Text.AlignHCenter
  // The width it needs outside the center column.
  readonly property real naturalWidth: serif ? Math.max(label.implicitWidth, detail.implicitWidth) : label.implicitWidth
  // A serif face where one is installed; fontconfig's generic serif otherwise.
  readonly property string serifFamily: view.fontOr("Georgia", view.fontOr("Noto Serif Display", view.fontOr("Noto Serif", "serif")))

  objectName: "dateLabel"
  height: serif ? detail.y + detail.height : label.height

  Text {
    id: label
    width: date.width
    textFormat: Text.PlainText
    text: date.caps ? date.view.now.toLocaleString(date.view.userLocale, "dddd d MMMM").toLocaleUpperCase()
      : date.abbreviated ? date.view.now.toLocaleString(date.view.userLocale, "ddd d MMM")
      : date.serif ? date.view.now.toLocaleString(date.view.userLocale, "dddd")
      : date.view.now.toLocaleString(date.view.userLocale, "dddd, d MMMM")
    color: date.view.foreground
    opacity: date.caps ? 0.86 : 1
    font.family: date.serif ? date.serifFamily
      : date.caps || date.abbreviated ? date.view.textFontFamily : date.view.displayFontFamily
    font.pixelSize: Math.round((date.caps ? 17 : date.abbreviated ? 24 : date.serif ? 64 : 30) * date.uiScale)
    font.weight: date.caps ? Font.Medium : date.abbreviated ? Font.DemiBold : Font.Normal
    font.letterSpacing: date.caps ? Math.round(3 * date.uiScale) : 0
    horizontalAlignment: date.textAlignment
    elide: Text.ElideRight
  }

  // "serif" only: the day, month and year in small spaced capitals.
  Text {
    id: detail
    objectName: "dateDetail"
    visible: date.serif
    y: label.height
    width: date.width
    textFormat: Text.PlainText
    text: date.view.now.toLocaleString(date.view.userLocale, "d MMMM yyyy").toLocaleUpperCase()
    color: date.view.foreground
    opacity: 0.86
    font.family: date.view.textFontFamily
    font.pixelSize: Math.round(14 * date.uiScale)
    font.weight: Font.Medium
    font.letterSpacing: Math.round(4 * date.uiScale)
    horizontalAlignment: date.textAlignment
    elide: Text.ElideRight
  }
}
