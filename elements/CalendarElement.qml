pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// This month as a grid, or this week as a strip. Styles: "card" (on glass,
// today ringed in the accent), "plain" (the same grid without the card),
// "mini" (a smaller grid without a card, one-letter weekdays) and "week"
// (this week's seven days on a glass strip, today ringed). A grid is always
// six weeks tall, so the element keeps one size whatever the month. The
// week starts on the locale's first day; cells are placed by hand (plain
// x/y, mirrored for right-to-left), like the other elements.
Item {
  id: calendar
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // This element's size: the view's scale for its screen (LockView sets it).
  required property real uiScale
  // The opacity of its glass surface (the look's, or its own `glass`).
  required property real glassOpacity
  readonly property color glassFill: view.glassAt(glassOpacity)
  // False while a shape is this element's background (absorb): its own
  // surface (fill and border) isn't drawn; the content stays where it is.
  property bool surfaceShown: true
  // Its surface's corner radius (a shape's "auto" radius), -1 without one.
  readonly property real surfaceRadius: card || week ? Math.round((week ? 18 : 22) * unit) : -1
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "card"
  readonly property bool card: styleName === "card"
  readonly property bool mini: styleName === "mini"
  readonly property bool week: styleName === "week"
  readonly property real unit: uiScale
  readonly property real cell: Math.round((mini ? 30 : week ? 48 : 42) * unit)
  readonly property real rowHeight: Math.round((mini ? 24 : week ? 36 : 34) * unit)
  readonly property real padding: Math.round((mini ? 6 : week ? 14 : 22) * unit)
  readonly property real titleHeight: week ? 0 : Math.round((mini ? 24 : 32) * unit)
  readonly property real headerHeight: Math.round((mini ? 18 : week ? 20 : 26) * unit)
  readonly property real gridTop: week ? padding : padding + titleHeight + Math.round((mini ? 4 : 10) * unit)
  readonly property int rows: week ? 1 : 6
  readonly property var locale: view.userLocale
  readonly property int firstDay: locale.firstDayOfWeek
  readonly property int year: view.now.getFullYear()
  readonly property int month: view.now.getMonth()
  readonly property int today: view.now.getDate()
  // Blank cells before the 1st, and the month's length.
  readonly property int offset: (new Date(year, month, 1).getDay() - firstDay + 7) % 7
  readonly property int days: new Date(year, month + 1, 0).getDate()
  // "week": how many days this week started before today.
  readonly property int weekIndex: (view.now.getDay() - firstDay + 7) % 7
  readonly property real naturalWidth: width

  objectName: "calendarBlock"
  width: 7 * cell + 2 * padding
  height: gridTop + headerHeight + rows * rowHeight + padding

  // Column `column` (0 = the week's first day) on screen.
  function columnX(column) {
    return padding + (view.rightToLeft ? 6 - column : column) * cell
  }

  // The day of the month in cell `index`: of this month in a grid (outside
  // 1..days for the blanks), of this week's days (any month) in the strip.
  function dayAt(index) {
    if (!week) return index - offset + 1
    return new Date(year, month, today - weekIndex + index).getDate()
  }

  Rectangle {
    objectName: "calendarCard"
    anchors.fill: parent
    visible: (calendar.card || calendar.week) && calendar.surfaceShown
    radius: calendar.surfaceRadius
    color: calendar.glassFill
    border.width: 1
    border.color: calendar.view.glassBorder
  }

  Text {
    objectName: "calendarTitle"
    visible: !calendar.week
    x: calendar.padding
    y: calendar.padding
    width: calendar.width - 2 * calendar.padding
    height: calendar.titleHeight
    textFormat: Text.PlainText
    text: calendar.locale.standaloneMonthName(calendar.month, Locale.LongFormat) + " "
      + calendar.view.now.toLocaleString(calendar.locale, "yyyy")
    color: calendar.view.foreground
    font.family: calendar.view.textFontFamily
    font.pixelSize: Math.round((calendar.mini ? 15 : 19) * calendar.unit)
    font.weight: Font.DemiBold
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Repeater {
    model: 7

    Text {
      required property int index
      readonly property bool isToday: calendar.week && index === calendar.weekIndex
      x: calendar.columnX(index)
      y: calendar.gridTop
      width: calendar.cell
      height: calendar.headerHeight
      textFormat: Text.PlainText
      text: calendar.locale.dayName((calendar.firstDay + index) % 7, calendar.mini ? Locale.NarrowFormat : Locale.ShortFormat)
      color: calendar.view.foreground
      opacity: isToday ? 1 : 0.6
      font.family: calendar.view.textFontFamily
      font.pixelSize: Math.round((calendar.mini ? 11 : 12) * calendar.unit)
      font.weight: isToday ? Font.Bold : Font.Medium
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }

  Repeater {
    model: 7 * calendar.rows

    Item {
      id: day
      required property int index
      readonly property int number: calendar.dayAt(index)
      readonly property bool isToday: calendar.week ? index === calendar.weekIndex : number === calendar.today
      visible: calendar.week || (number >= 1 && number <= calendar.days)
      x: calendar.columnX(index % 7)
      y: calendar.gridTop + calendar.headerHeight + Math.floor(index / 7) * calendar.rowHeight
      width: calendar.cell
      height: calendar.rowHeight

      Rectangle {
        anchors.centerIn: parent
        visible: day.isToday
        width: Math.min(parent.width, parent.height) - Math.round((calendar.mini ? 2 : 4) * calendar.unit)
        height: width
        radius: width / 2
        color: Qt.rgba(calendar.view.accent.r, calendar.view.accent.g, calendar.view.accent.b, 0.22)
        border.width: Math.max(1, Math.round((calendar.mini ? 1.5 : 2) * calendar.unit))
        border.color: calendar.view.accent
      }

      Text {
        anchors.fill: parent
        textFormat: Text.PlainText
        text: FoamyI18n.number(day.number)
        color: calendar.view.foreground
        opacity: day.isToday ? 1 : 0.86
        font.family: calendar.view.textFontFamily
        font.pixelSize: Math.round((calendar.mini ? 12 : calendar.week ? 16 : 15) * calendar.unit)
        font.weight: day.isToday ? Font.Bold : Font.Normal
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
