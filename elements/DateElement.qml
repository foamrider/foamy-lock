import QtQuick
import "../kit"

// The date. Styles: "long" (the weekday, day and month in the display face),
// "caps" (shorter, spaced capitals in the text face), "short" (abbreviated
// weekday and month, semibold), "serif" (a large serif weekday over a small
// spaced line with the day, month and year), "numeric" (the locale's short
// date), "stacked" (a large day number beside the month over the weekday)
// "week" (the ISO week number and the date) and "iso" (the ISO date,
// 2026-09-26, and the short weekday, in the mono face, for a console look).
// The host sets the width in the center column; elsewhere it is
// `naturalWidth`.
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
  readonly property bool numeric: styleName === "numeric"
  readonly property bool stacked: styleName === "stacked"
  readonly property bool week: styleName === "week"
  readonly property bool iso: styleName === "iso"
  // The main line, as the tests read it.
  readonly property alias text: label.text
  readonly property alias font: label.font
  readonly property int textAlignment: alignment === "start" ? Text.AlignLeft : alignment === "end" ? Text.AlignRight : Text.AlignHCenter
  // "stacked": the day number, a gap, then the month and weekday column.
  readonly property real dayGap: Math.round(14 * uiScale)
  readonly property real columnWidth: Math.max(month.implicitWidth, weekday.implicitWidth)
  readonly property real stackWidth: label.implicitWidth + dayGap + columnWidth
  // The width it needs outside the center column.
  readonly property real naturalWidth: serif ? Math.max(label.implicitWidth, detail.implicitWidth) : stacked ? stackWidth : label.implicitWidth
  // A serif face where one is installed; fontconfig's generic serif otherwise.
  readonly property string serifFamily: view.fontOr("Georgia", view.fontOr("Noto Serif Display", view.fontOr("Noto Serif", "serif")))
  // "stacked": where the group starts inside the element, on screen (it is
  // centred, or at the start or end, like the other styles' text).
  readonly property real stackStart: {
    var free = Math.max(0, width - stackWidth)
    var start = alignment === "center" ? free / 2 : alignment === "start" ? 0 : free
    return view.rightToLeft ? width - start - stackWidth : start
  }

  objectName: "dateLabel"
  height: serif ? detail.y + detail.height : stacked ? Math.max(label.height, column.height) : label.height

  Text {
    id: label
    // "stacked": the day number at the group's start (plain x, mirrored by
    // hand); the full width otherwise.
    x: !date.stacked ? 0 : date.view.rightToLeft ? date.stackStart + date.stackWidth - width : date.stackStart
    width: date.stacked ? implicitWidth : date.width
    textFormat: Text.PlainText
    text: date.caps ? date.view.now.toLocaleString(date.view.userLocale, "dddd d MMMM").toLocaleUpperCase() : date.abbreviated ? date.view.now.toLocaleString(date.view.userLocale, "ddd d MMM") : date.serif ? date.view.now.toLocaleString(date.view.userLocale, "dddd") : date.numeric ? date.view.now.toLocaleDateString(date.view.userLocale, Locale.ShortFormat) : date.stacked ? FoamyI18n.number(date.view.now.getDate()) : date.week ? FoamyI18n.t("Week %1", [FoamyI18n.number(date.view.weekOf(date.view.now))]) + "  ·  " + date.view.now.toLocaleString(date.view.userLocale, "d MMMM") :
    // ISO 8601 keeps its own digits in every language.
    date.iso ? date.view.now.toLocaleString(Qt.locale("C"), "yyyy-MM-dd") + "  " + date.view.now.toLocaleString(date.view.userLocale, "ddd") : date.view.now.toLocaleString(date.view.userLocale, "dddd, d MMMM")
    color: date.view.foreground
    opacity: date.caps || date.week || date.iso ? 0.86 : 1
    font.family: date.serif ? date.serifFamily : date.iso ? FoamyStyle.monoFamily : date.caps || date.abbreviated || date.week ? date.view.textFontFamily : date.view.displayFontFamily
    font.pixelSize: Math.round((date.caps ? 17 : date.abbreviated ? 24 : date.serif ? 64 : date.numeric ? 34 : date.stacked ? 72 : date.week ? 18 : date.iso ? 20 : 30) * date.uiScale)
    font.weight: date.caps || date.week || date.iso ? Font.Medium : date.abbreviated || date.numeric ? Font.DemiBold : Font.Normal
    font.letterSpacing: date.caps ? Math.round(3 * date.uiScale) : date.numeric || date.iso ? Math.round(2 * date.uiScale) : 0
    horizontalAlignment: date.stacked ? Text.AlignLeft : date.textAlignment
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

  // "stacked" only: the month over the weekday, after the day number.
  Column {
    id: column
    objectName: "dateStack"
    visible: date.stacked
    x: date.view.rightToLeft ? date.stackStart : date.stackStart + label.implicitWidth + date.dayGap
    y: Math.max(0, Math.round((label.height - height) / 2))
    width: date.columnWidth

    Text {
      id: month
      width: parent.width
      textFormat: Text.PlainText
      text: date.view.now.toLocaleString(date.view.userLocale, "MMMM").toLocaleUpperCase()
      color: date.view.foreground
      font.family: date.view.textFontFamily
      font.pixelSize: Math.round(18 * date.uiScale)
      font.weight: Font.DemiBold
      font.letterSpacing: Math.round(2 * date.uiScale)
      horizontalAlignment: Text.AlignLeft
    }

    Text {
      id: weekday
      width: parent.width
      textFormat: Text.PlainText
      text: date.view.now.toLocaleString(date.view.userLocale, "dddd")
      color: date.view.foreground
      opacity: 0.8
      font.family: date.view.textFontFamily
      font.pixelSize: Math.round(16 * date.uiScale)
      horizontalAlignment: Text.AlignLeft
    }
  }
}
