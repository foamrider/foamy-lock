import QtQuick
import "../kit"

// This month as a grid. Styles: "card" (on glass, today ringed in the
// accent) and "plain" (the same grid without the card). Always six weeks
// tall, so the element keeps one size whatever the month. The week starts on
// the locale's first day; cells are placed by hand (plain x/y, mirrored for
// right-to-left), like the other elements.
Item {
  id: calendar
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "card"
  readonly property bool card: styleName === "card"
  readonly property real unit: view.uiScale
  readonly property real cell: Math.round(42 * unit)
  readonly property real rowHeight: Math.round(34 * unit)
  readonly property real padding: Math.round(22 * unit)
  readonly property real titleHeight: Math.round(32 * unit)
  readonly property real headerHeight: Math.round(26 * unit)
  readonly property real gridTop: padding + titleHeight + Math.round(10 * unit)
  readonly property var locale: view.userLocale
  readonly property int firstDay: locale.firstDayOfWeek
  readonly property int year: view.now.getFullYear()
  readonly property int month: view.now.getMonth()
  readonly property int today: view.now.getDate()
  // Blank cells before the 1st, and the month's length.
  readonly property int offset: (new Date(year, month, 1).getDay() - firstDay + 7) % 7
  readonly property int days: new Date(year, month + 1, 0).getDate()
  readonly property real naturalWidth: width

  objectName: "calendarBlock"
  width: 7 * cell + 2 * padding
  height: gridTop + headerHeight + 6 * rowHeight + padding

  // Column `column` (0 = the week's first day) on screen.
  function columnX(column) {
    return padding + (view.rightToLeft ? 6 - column : column) * cell
  }

  Rectangle {
    objectName: "calendarCard"
    anchors.fill: parent
    visible: calendar.card
    radius: Math.round(22 * calendar.unit)
    color: calendar.view.glass
    border.width: 1
    border.color: calendar.view.glassBorder
  }

  Text {
    objectName: "calendarTitle"
    x: calendar.padding
    y: calendar.padding
    width: calendar.width - 2 * calendar.padding
    height: calendar.titleHeight
    textFormat: Text.PlainText
    text: calendar.locale.standaloneMonthName(calendar.month, Locale.LongFormat) + " "
      + calendar.view.now.toLocaleString(calendar.locale, "yyyy")
    color: calendar.view.foreground
    font.family: calendar.view.textFontFamily
    font.pixelSize: Math.round(19 * calendar.unit)
    font.weight: Font.DemiBold
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Repeater {
    model: 7

    Text {
      required property int index
      x: calendar.columnX(index)
      y: calendar.gridTop
      width: calendar.cell
      height: calendar.headerHeight
      textFormat: Text.PlainText
      text: calendar.locale.dayName((calendar.firstDay + index) % 7, Locale.ShortFormat)
      color: calendar.view.foreground
      opacity: 0.6
      font.family: calendar.view.textFontFamily
      font.pixelSize: Math.round(12 * calendar.unit)
      font.weight: Font.Medium
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }

  Repeater {
    model: 42

    Item {
      id: day
      required property int index
      readonly property int number: index - calendar.offset + 1
      readonly property bool isToday: number === calendar.today
      visible: number >= 1 && number <= calendar.days
      x: calendar.columnX(index % 7)
      y: calendar.gridTop + calendar.headerHeight + Math.floor(index / 7) * calendar.rowHeight
      width: calendar.cell
      height: calendar.rowHeight

      Rectangle {
        anchors.centerIn: parent
        visible: day.isToday
        width: Math.min(parent.width, parent.height) - Math.round(4 * calendar.unit)
        height: width
        radius: width / 2
        color: Qt.rgba(calendar.view.accent.r, calendar.view.accent.g, calendar.view.accent.b, 0.22)
        border.width: Math.max(1, Math.round(2 * calendar.unit))
        border.color: calendar.view.accent
      }

      Text {
        anchors.fill: parent
        textFormat: Text.PlainText
        text: FoamyI18n.number(day.number)
        color: calendar.view.foreground
        opacity: day.isToday ? 1 : 0.86
        font.family: calendar.view.textFontFamily
        font.pixelSize: Math.round(15 * calendar.unit)
        font.weight: day.isToday ? Font.Bold : Font.Normal
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
