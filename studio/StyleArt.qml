pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import "kit"
import "elements" as Elements

// A small drawing of one element style, made from its name: what the style
// tiles in the inspector show (ported from the retired foamy-lock-studio
// popup, with its own line icons). Each drawing follows the style's
// description in Foamy Lock's README (a dot-matrix clock, a "card" field
// with a greeting above it…); the clock, date, calendar and weather use
// sample values (12:30, 7 November 2026 in the chosen language, 12°).
// With `element` "decor" it draws a background decoration on a small
// screen instead (the background page's tiles), and with "animation" one of
// the drawn backgrounds (Layout.DRAWN_SOURCES), by the lock's own code. A name the studio has no
// drawing for gets a generic one (`known` is false) and the tile names it
// as Foamy Lock does.
// Static: no motion, no effects (Canvas draws in every renderer).
Item {
  id: root

  property string element: ""
  property string styleName: ""
  property color ink: FoamyPalette.text

  readonly property string key: element + ":" + styleName
  readonly property Component drawing: pick(key)
  readonly property bool known: drawing !== generic
  readonly property color soft: Qt.alpha(ink, 0.16)
  readonly property color edge: Qt.alpha(ink, 0.5)
  readonly property color faint: Qt.alpha(ink, 0.1)
  readonly property var locale: Qt.locale(FoamyI18n.formatLocale)
  readonly property var sampleDate: new Date(2026, 10, 7, 12, 30)
  readonly property real u: Math.min(width / 80, height / 40)

  implicitWidth: Style.space(80)
  implicitHeight: Style.space(40)
  // The style drawings are pictures (they mix anchors and x, so they never
  // mirror); a decoration's start and end follow the reading direction.
  LayoutMirroring.enabled: element === "decor" && FoamyI18n.rightToLeft
  LayoutMirroring.childrenInherit: true

  function dateText(format) { return sampleDate.toLocaleDateString(locale, format) }

  // A small line icon in a w × h box: the arrow, music note, play, globe,
  // battery, timer, gauge, chip and box the drawings use.
  function paintIcon(ctx, name, w, h, color) {
    ctx.reset()
    var s = Math.min(w, h)
    ctx.save()
    ctx.translate((w - s) / 2, (h - s) / 2)
    ctx.strokeStyle = color
    ctx.fillStyle = color
    ctx.lineWidth = Math.max(1, s / 11)
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    function line(points) {
      ctx.beginPath()
      ctx.moveTo(points[0] * s, points[1] * s)
      for (var i = 2; i < points.length; i += 2) ctx.lineTo(points[i] * s, points[i + 1] * s)
      ctx.stroke()
    }
    function circle(x, y, r, fill) {
      ctx.beginPath()
      ctx.arc(x * s, y * s, r * s, 0, Math.PI * 2)
      if (fill) ctx.fill()
      else ctx.stroke()
    }
    switch (name) {
    case "arrow-right":
      line([0.2, 0.5, 0.8, 0.5])
      line([0.55, 0.25, 0.8, 0.5, 0.55, 0.75])
      break
    case "music":
      circle(0.33, 0.72, 0.13, true)
      line([0.46, 0.72, 0.46, 0.18, 0.78, 0.3])
      break
    case "play":
      ctx.beginPath()
      ctx.moveTo(0.3 * s, 0.2 * s)
      ctx.lineTo(0.8 * s, 0.5 * s)
      ctx.lineTo(0.3 * s, 0.8 * s)
      ctx.closePath()
      ctx.fill()
      break
    case "globe":
      circle(0.5, 0.5, 0.38)
      line([0.12, 0.5, 0.88, 0.5])
      ctx.beginPath()
      ctx.ellipse(0.32 * s, 0.12 * s, 0.36 * s, 0.76 * s)
      ctx.stroke()
      break
    case "battery-medium":
      ctx.strokeRect(0.12 * s, 0.3 * s, 0.66 * s, 0.4 * s)
      ctx.fillRect(0.2 * s, 0.38 * s, 0.3 * s, 0.24 * s)
      line([0.86, 0.42, 0.86, 0.58])
      break
    case "timer":
      circle(0.5, 0.55, 0.33)
      line([0.5, 0.55, 0.5, 0.36])
      line([0.4, 0.12, 0.6, 0.12])
      break
    case "gauge":
      ctx.beginPath()
      ctx.arc(0.5 * s, 0.62 * s, 0.36 * s, Math.PI, Math.PI * 2)
      ctx.stroke()
      line([0.5, 0.62, 0.7, 0.4])
      break
    case "cpu":
      ctx.strokeRect(0.26 * s, 0.26 * s, 0.48 * s, 0.48 * s)
      for (var p = 0.38; p < 0.7; p += 0.24) {
        line([p, 0.1, p, 0.26])
        line([p, 0.74, p, 0.9])
        line([0.1, p, 0.26, p])
        line([0.74, p, 0.9, p])
      }
      break
    default:
      ctx.strokeRect(0.2 * s, 0.25 * s, 0.6 * s, 0.5 * s)
      line([0.2, 0.25, 0.5, 0.45, 0.8, 0.25])
    }
    ctx.restore()
  }

  function pick(name) {
    if (element === "animation") return animationArt
    switch (name) {
    case "clock:thin": return clockThin
    case "clock:bold": return clockBold
    case "clock:stacked": return clockStacked
    case "clock:mono": return clockMono
    case "clock:outline": return clockOutline
    case "clock:dots": return clockDots
    case "clock:flip": return clockFlip
    case "clock:analog": return clockAnalog
    case "clock:small": return clockSmall
    case "clock:poster": return clockPoster
    case "clock:ring": return clockRing
    case "date:long": return dateLong
    case "date:caps": return dateCaps
    case "date:short": return dateShort
    case "date:serif": return dateSerif
    case "date:numeric": return dateNumeric
    case "date:stacked": return dateStacked
    case "date:week": return dateWeek
    case "account:avatar": return accountAvatar
    case "account:chip": return accountChip
    case "account:name": return accountName
    case "password:pill": return passwordPill
    case "password:underline": return passwordUnderline
    case "password:box": return passwordBox
    case "password:dots": return passwordDots
    case "password:terminal": return passwordTerminal
    case "password:card": return passwordCard
    case "media:card": return mediaCard
    case "media:line": return mediaLine
    case "media:pill": return mediaPill
    case "media:art": return mediaArt
    case "media:hero": return mediaHero
    case "media:minimal": return mediaMinimal
    case "media:disc": return mediaDisc
    case "status:text": return statusText
    case "status:icons": return statusIcons
    case "status:pill": return statusPill
    case "status:system": return statusSystem
    case "calendar:card": return calendarCard
    case "calendar:plain": return calendarPlain
    case "calendar:week": return calendarWeek
    case "calendar:mini": return calendarMini
    case "weather:compact": return weatherCompact
    case "weather:pill": return weatherPill
    case "weather:detailed": return weatherDetailed
    case "weather:line": return weatherLine
    case "weather:large": return weatherLarge
    case "weather:card": return weatherCard
    case "decor:none": return decorNone
    case "decor:split": return decorSplit
    case "decor:sheet": return decorSheet
    case "decor:cinema": return decorCinema
    case "decor:strip": return decorStrip
    case "decor:island": return decorIsland
    case "decor:frame": return decorFrame
    case "decor:card": return decorCard
    }
    return generic
  }

  Loader {
    anchors.fill: parent
    sourceComponent: root.drawing
  }

  // ---- pieces
  // Text shrunk to fit the drawing (art: sizes follow the tile).
  component Fit: Text {
    anchors.centerIn: parent
    width: parent.width
    height: parent.height
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    fontSizeMode: Text.Fit
    minimumPixelSize: 6
    // A long date takes two lines rather than shrinking.
    wrapMode: Text.WordWrap
    maximumLineCount: 2
    lineHeight: 0.95
    color: root.ink
    font.family: FoamyStyle.fontFamily
  }
  component Bar: Rectangle {
    height: Math.max(2, root.u * 3)
    radius: height / 2
    color: root.ink
  }
  component Avatar: Rectangle {
    radius: width / 2
    height: width
    clip: true
    color: root.soft
    border.width: 1
    border.color: root.edge
    Rectangle {
      width: parent.width * 0.4; height: width; radius: width / 2
      x: (parent.width - width) / 2; y: parent.height * 0.2
      color: root.edge
    }
    Rectangle {
      width: parent.width * 0.8; height: width; radius: width / 2
      x: (parent.width - width) / 2; y: parent.height * 0.66
      color: root.edge
    }
  }
  component Dots: Row {
    property int count: 4
    property real size: root.u * 4
    spacing: size * 0.6
    Repeater {
      model: parent.count
      Rectangle { width: parent.size; height: width; radius: width / 2; color: root.ink }
    }
  }
  component Glass: Rectangle {
    color: root.soft
    border.width: 1
    border.color: root.edge
  }
  // The few line icons the drawings use, drawn here: see paintIcon (the
  // weather's is the kit's FoamyIcon).
  component Icon: Canvas {
    property string name: ""
    property color color: root.ink
    width: root.u * 11
    height: width
    onColorChanged: requestPaint()
    onNameChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: root.paintIcon(getContext("2d"), name, width, height, color)
  }
  // A meter: a faint track and a filled part.
  component Meter: Rectangle {
    property real value: 0.5
    height: Math.max(2, root.u * 2.4)
    radius: height / 2
    color: root.faint
    Rectangle { width: parent.width * parent.value; height: parent.height; radius: parent.radius; color: root.ink }
  }
  // This month (November 2026) as a grid: weekday initials, then six weeks
  // (the lock keeps six rows whatever the month); today, the 7th, in the
  // accent (the lock rings it).
  component Month: Grid {
    id: month
    property real cell: root.u * 4.6
    readonly property int first: (new Date(2026, 10, 1).getDay() + 6) % 7
    columns: 7
    Repeater {
      model: 7 * 7
      Item {
        required property int index
        readonly property int day: index - 7 - month.first + 1
        width: month.cell
        height: month.cell
        Rectangle {
          anchors.centerIn: parent
          visible: parent.index < 7 || (parent.day >= 1 && parent.day <= 30)
          width: parent.index < 7 ? month.cell * 0.5 : month.cell * 0.34
          height: parent.index < 7 ? Math.max(1, month.cell * 0.18) : width
          radius: height / 2
          color: parent.index < 7 ? Qt.alpha(root.ink, 0.5) : root.ink
          opacity: parent.index < 7 ? 1 : 0.8
        }
        Rectangle {
          anchors.centerIn: parent
          visible: parent.day === 7
          width: month.cell
          height: width
          radius: width / 2
          color: Commons.Color.accent
        }
      }
    }
  }
  // A small lock screen for the decorations: the wallpaper as a faint wash
  // and a sample field, the decoration drawn between them.
  component Screen: Rectangle {
    default property alias shapes: layer.data
    anchors.centerIn: parent
    height: parent.height - 2
    width: Math.min(parent.width - 2, height * 16 / 10)
    radius: root.u * 2
    clip: true
    color: Qt.alpha(root.ink, 0.06)
    border.width: 1
    border.color: root.edge
    Item { id: layer; anchors.fill: parent }
  }

  // ---- clock (digits keep their order in right-to-left languages)
  Component { id: clockThin; Item { Fit { text: "12:30"; font.pixelSize: FoamyStyle.font.display; font.weight: Font.Light } } }
  Component { id: clockBold; Item { Fit { text: "12:30"; font.pixelSize: FoamyStyle.font.display; font.weight: Font.Black; font.letterSpacing: -0.5 } } }
  Component { id: clockMono; Item { Fit { text: "12:30"; font.pixelSize: FoamyStyle.font.display; font.family: FoamyStyle.monoFamily } } }
  Component {
    id: clockStacked
    Item {
      Column {
        anchors.centerIn: parent
        spacing: -root.u * 3
        Repeater {
          model: ["12", "30"]
          Text {
            required property string modelData
            anchors.horizontalCenter: parent.horizontalCenter
            text: modelData
            textFormat: Text.PlainText
            color: root.ink
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.iconLarge
            font.weight: Font.Black
          }
        }
      }
    }
  }
  Component {
    id: clockOutline
    Canvas {
      readonly property color ink: root.ink
      onInkChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var size = Math.round(Math.min(height * 0.62, width / 3))
        ctx.font = "bold " + size + "px \"" + FoamyStyle.fontFamily + "\""
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        ctx.lineWidth = Math.max(1, size / 26)
        ctx.strokeStyle = ink
        ctx.strokeText("12:30", width / 2, height / 2)
      }
    }
  }
  Component {
    id: clockDots
    Canvas {
      // 5×7 dot glyphs, as on the lock's LED face.
      readonly property var glyphs: ({
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        ":": ["0", "0", "1", "0", "1", "0", "0"]
      })
      readonly property color ink: root.ink
      onInkChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var text = "12:30"
        var columns = 0
        for (var c = 0; c < text.length; c++) columns += glyphs[text[c]][0].length + (c ? 1 : 0)
        var pitch = Math.min(width / columns, height / 7)
        var x0 = (width - pitch * columns) / 2, y0 = (height - pitch * 7) / 2
        var x = x0
        for (var i = 0; i < text.length; i++) {
          var glyph = glyphs[text[i]]
          for (var row = 0; row < 7; row++)
            for (var col = 0; col < glyph[row].length; col++) {
              ctx.fillStyle = glyph[row][col] === "1" ? ink : Qt.alpha(ink, 0.12)
              ctx.beginPath()
              ctx.arc(x + (col + 0.5) * pitch, y0 + (row + 0.5) * pitch, pitch * 0.36, 0, Math.PI * 2)
              ctx.fill()
            }
          x += (glyph[0].length + 1) * pitch
        }
      }
    }
  }
  Component {
    id: clockFlip
    Item {
      LayoutMirroring.enabled: false
      LayoutMirroring.childrenInherit: true
      Row {
        anchors.centerIn: parent
        spacing: root.u * 3
        Repeater {
          model: ["12", "30"]
          Rectangle {
            required property string modelData
            width: root.u * 28
            height: root.u * 32
            radius: root.u * 4
            color: Qt.alpha(root.ink, 0.2)
            Text {
              anchors.centerIn: parent
              text: parent.modelData
              textFormat: Text.PlainText
              color: root.ink
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.heading
              font.weight: Font.Bold
            }
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: Math.max(1, root.u)
              color: Commons.Color.popups.background
              opacity: 0.8
            }
          }
        }
      }
    }
  }
  Component {
    id: clockAnalog
    Canvas {
      readonly property color ink: root.ink
      onInkChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var r = Math.min(width, height) / 2 - 1.5
        var cx = width / 2, cy = height / 2
        ctx.strokeStyle = ink
        ctx.lineCap = "round"
        ctx.lineWidth = Math.max(1, r / 12)
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
        for (var t = 0; t < 12; t += 3) {
          var a = t / 12 * Math.PI * 2
          ctx.beginPath()
          ctx.moveTo(cx + Math.sin(a) * r * 0.78, cy - Math.cos(a) * r * 0.78)
          ctx.lineTo(cx + Math.sin(a) * r * 0.9, cy - Math.cos(a) * r * 0.9)
          ctx.stroke()
        }
        // 12:30: the minute hand down, the hour hand halfway past 12.
        var hand = function(angle, length, w) {
          ctx.lineWidth = w
          ctx.beginPath(); ctx.moveTo(cx, cy)
          ctx.lineTo(cx + Math.sin(angle) * length, cy - Math.cos(angle) * length); ctx.stroke()
        }
        hand(Math.PI, r * 0.78, Math.max(1, r / 10))
        hand(Math.PI * 2 * 12.5 / 12, r * 0.5, Math.max(1.5, r / 7))
      }
    }
  }

  // One line, smaller: for a bar or a card.
  Component {
    id: clockSmall
    Item {
      Text {
        anchors.centerIn: parent
        text: "12:30"
        textFormat: Text.PlainText
        color: root.ink
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.title
        font.weight: Font.DemiBold
      }
    }
  }
  // Huge hours over the minutes in the accent.
  Component {
    id: clockPoster
    Item {
      Column {
        anchors.centerIn: parent
        Repeater {
          model: ["12", "30"]
          Text {
            required property string modelData
            required property int index
            anchors.horizontalCenter: parent.horizontalCenter
            // Lines as tall as the digits, so the minutes sit right under the hours.
            height: root.u * 20.5
            verticalAlignment: Text.AlignVCenter
            text: modelData
            textFormat: Text.PlainText
            color: index === 0 ? root.ink : Commons.Color.accent
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.display
            font.weight: Font.Black
          }
        }
      }
    }
  }
  // The time in a ring that fills over the hour (half full at :30).
  Component {
    id: clockRing
    Item {
      Canvas {
        anchors.fill: parent
        readonly property color ink: root.ink
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var r = Math.min(width, height) / 2 - 2
          ctx.lineWidth = Math.max(1.5, r / 9)
          ctx.lineCap = "round"
          ctx.strokeStyle = Qt.alpha(ink, 0.18)
          ctx.beginPath(); ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2); ctx.stroke()
          ctx.strokeStyle = ink
          ctx.beginPath(); ctx.arc(width / 2, height / 2, r, -Math.PI / 2, Math.PI / 2); ctx.stroke()
        }
      }
      Text {
        anchors.centerIn: parent
        text: "12:30"
        textFormat: Text.PlainText
        color: root.ink
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.caption
        font.weight: Font.Medium
      }
    }
  }

  // ---- date
  Component { id: dateLong; Item { Fit { text: root.dateText("dddd d MMMM"); font.pixelSize: FoamyStyle.font.subtitle; font.weight: Font.Light } } }
  Component {
    id: dateCaps
    Item { Fit { text: root.dateText("ddd d MMMM").toLocaleUpperCase(); font.pixelSize: FoamyStyle.font.caption; font.weight: Font.Medium; font.letterSpacing: 1.5 } }
  }
  Component { id: dateShort; Item { Fit { text: root.dateText("ddd d MMM"); font.pixelSize: FoamyStyle.font.subtitle; font.weight: Font.DemiBold } } }
  Component {
    id: dateSerif
    Item {
      Column {
        anchors.centerIn: parent
        width: parent.width
        spacing: root.u
        Text {
          width: parent.width
          height: root.u * 22
          text: root.dateText("dddd")
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignBottom
          fontSizeMode: Text.Fit
          minimumPixelSize: 6
          color: root.ink
          font.family: "serif"
          font.pixelSize: FoamyStyle.font.heading
        }
        Text {
          width: parent.width
          text: root.dateText("d MMMM yyyy").toLocaleUpperCase()
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          fontSizeMode: Text.HorizontalFit
          minimumPixelSize: 5
          color: Qt.alpha(root.ink, 0.75)
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.caption
          font.letterSpacing: 1.2
        }
      }
    }
  }

  Component {
    id: dateNumeric
    Item { Fit { text: root.dateText(Locale.ShortFormat); font.pixelSize: FoamyStyle.font.subtitle; font.weight: Font.DemiBold; font.letterSpacing: 1 } }
  }
  // A large day number beside the month over the weekday.
  Component {
    id: dateStacked
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 3
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: FoamyI18n.number(root.sampleDate.getDate())
          textFormat: Text.PlainText
          color: root.ink
          font.family: FoamyStyle.fontFamily
          font.pixelSize: Math.round(root.u * 28)
          font.weight: Font.Light
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0
          Repeater {
            model: [root.dateText("MMMM"), root.dateText("dddd")]
            Text {
              required property string modelData
              required property int index
              text: modelData
              textFormat: Text.PlainText
              color: index === 0 ? root.ink : Qt.alpha(root.ink, 0.7)
              font.family: FoamyStyle.fontFamily
              font.pixelSize: Math.max(7, Math.round(root.u * (index === 0 ? 10 : 9)))
              font.weight: index === 0 ? Font.DemiBold : Font.Normal
            }
          }
        }
      }
    }
  }
  // The ISO week (7 November 2026 is in week 45) and the date.
  Component {
    id: dateWeek
    Item {
      Fit {
        text: FoamyI18n.t("studio.art.week", FoamyI18n.number(45)) + "  ·  " + root.dateText("d MMMM")
        font.pixelSize: FoamyStyle.font.caption
        font.weight: Font.Medium
      }
    }
  }

  // ---- account
  Component {
    id: accountAvatar
    Item {
      Column {
        anchors.centerIn: parent
        spacing: root.u * 3
        Avatar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 24 }
        Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 30 }
      }
    }
  }
  Component {
    id: accountChip
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 56
        height: root.u * 18
        radius: height / 2
        Avatar { id: chipAvatar; x: root.u * 3; anchors.verticalCenter: parent.verticalCenter; width: parent.height - root.u * 6 }
        Bar { anchors.left: chipAvatar.right; anchors.leftMargin: root.u * 4; anchors.verticalCenter: parent.verticalCenter; width: root.u * 26 }
      }
    }
  }
  Component { id: accountName; Item { Bar { anchors.centerIn: parent; width: root.u * 40; height: root.u * 5 } } }

  // ---- password field
  Component {
    id: passwordPill
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 66
        height: root.u * 18
        radius: height / 2
        Dots { x: root.u * 8; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }
  Component {
    id: passwordUnderline
    Item {
      Item {
        anchors.centerIn: parent
        width: root.u * 66
        height: root.u * 16
        Dots { x: root.u * 4; anchors.verticalCenter: parent.verticalCenter }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Math.max(1, root.u * 1.2); color: root.ink }
      }
    }
  }
  Component {
    id: passwordBox
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 66
        height: root.u * 20
        radius: root.u * 4
        Dots { x: root.u * 7; anchors.verticalCenter: parent.verticalCenter }
        Icon { name: "arrow-right"; anchors.right: parent.right; anchors.rightMargin: root.u * 4; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }
  Component { id: passwordDots; Item { Dots { anchors.centerIn: parent; count: 6; size: root.u * 6 } } }
  Component {
    id: passwordTerminal
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 2
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "$ ****"
          textFormat: Text.PlainText
          color: root.ink
          font.family: FoamyStyle.monoFamily
          font.pixelSize: FoamyStyle.font.body
        }
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: root.u * 5; height: root.u * 11; color: root.ink }
      }
    }
  }
  Component {
    id: passwordCard
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 70
        height: root.u * 36
        radius: root.u * 5
        color: root.faint
        Bar { anchors.horizontalCenter: parent.horizontalCenter; y: root.u * 7; width: root.u * 32 }
        Glass {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: root.u * 6
          width: parent.width - root.u * 14
          height: root.u * 12
          radius: height / 2
          Dots { x: root.u * 5; anchors.verticalCenter: parent.verticalCenter; size: root.u * 3 }
        }
      }
    }
  }

  // ---- media player
  Component {
    id: mediaCard
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 74
        height: root.u * 30
        radius: root.u * 5
        Rectangle { id: cardArt; x: root.u * 4; anchors.verticalCenter: parent.verticalCenter; width: parent.height - root.u * 8; height: width; radius: root.u * 3; color: root.edge }
        Column {
          anchors.left: cardArt.right
          anchors.leftMargin: root.u * 5
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.u * 3
          Bar { width: root.u * 30 }
          Bar { width: root.u * 20; opacity: 0.6 }
          Row {
            spacing: root.u * 4
            Repeater { model: 3; Rectangle { width: root.u * 3; height: width; radius: width / 2; color: root.ink } }
          }
        }
      }
    }
  }
  Component {
    id: mediaLine
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 4
        Icon { name: "music"; anchors.verticalCenter: parent.verticalCenter }
        Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 32 }
        Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 18; opacity: 0.6 }
      }
    }
  }
  Component {
    id: mediaPill
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 64
        height: root.u * 18
        radius: height / 2
        Rectangle { id: pillArt; x: root.u * 3; anchors.verticalCenter: parent.verticalCenter; width: parent.height - root.u * 6; height: width; radius: width / 2; color: root.edge }
        Bar { anchors.left: pillArt.right; anchors.leftMargin: root.u * 4; anchors.verticalCenter: parent.verticalCenter; width: root.u * 26 }
        Icon { name: "play"; width: root.u * 9; anchors.right: parent.right; anchors.rightMargin: root.u * 5; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }
  Component {
    id: mediaArt
    Item {
      Column {
        anchors.centerIn: parent
        spacing: root.u * 3
        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 26; height: width; radius: root.u * 3; color: root.edge }
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: root.u * 5
          Repeater { model: 3; Rectangle { width: root.u * 3.5; height: width; radius: width / 2; color: root.ink } }
        }
      }
    }
  }

  // No surface: a large cover, the title and artist under it.
  Component {
    id: mediaHero
    Item {
      Column {
        anchors.centerIn: parent
        spacing: root.u * 2.5
        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 27; height: width; radius: root.u * 3.5; color: root.edge }
        Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 22 }
        Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 14; opacity: 0.6 }
      }
    }
  }
  // One line of text: a note, the title and the artist.
  Component {
    id: mediaMinimal
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 3
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "♪"
          color: root.ink
          font.family: FoamyStyle.fontFamily
          font.pixelSize: Math.round(root.u * 10)
        }
        Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 26 }
        Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 4; opacity: 0.6 }
        Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 18; opacity: 0.6 }
      }
    }
  }
  // A round cover with a centre hole, the title and artist, play/pause.
  Component {
    id: mediaDisc
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 4
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: root.u * 24
          height: width
          radius: width / 2
          color: root.edge
          Rectangle { anchors.centerIn: parent; width: root.u * 5; height: width; radius: width / 2; color: root.faint; border.width: 1; border.color: root.ink }
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.u * 3
          Bar { width: root.u * 24 }
          Bar { width: root.u * 16; opacity: 0.6 }
        }
        Icon { name: "play"; width: root.u * 9; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }

  // ---- status
  Component {
    id: statusText
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 6
        Row {
          spacing: root.u * 2
          Icon { name: "globe"; width: root.u * 13; anchors.verticalCenter: parent.verticalCenter }
          Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 16 }
        }
        Row {
          spacing: root.u * 2
          Icon { name: "battery-medium"; width: root.u * 13; anchors.verticalCenter: parent.verticalCenter }
          Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 12 }
        }
      }
    }
  }
  Component {
    id: statusIcons
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 6
        Icon { name: "globe"; width: root.u * 16 }
        Icon { name: "battery-medium"; width: root.u * 16 }
      }
    }
  }
  Component {
    id: statusPill
    Item {
      Glass {
        anchors.centerIn: parent
        width: statusRow.width + root.u * 12
        height: root.u * 18
        radius: height / 2
        Row {
          id: statusRow
          anchors.centerIn: parent
          spacing: root.u * 3
          Icon { name: "globe"; width: root.u * 9; anchors.verticalCenter: parent.verticalCenter }
          Icon { name: "battery-medium"; width: root.u * 9; anchors.verticalCenter: parent.verticalCenter }
          Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 10 }
        }
      }
    }
  }

  // A panel: uptime, memory, load and the battery, each a meter.
  Component {
    id: statusSystem
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 60
        height: root.u * 36
        radius: root.u * 4
        Grid {
          anchors.centerIn: parent
          columns: 2
          columnSpacing: root.u * 6
          rowSpacing: root.u * 4
          Repeater {
            model: [["timer", 0.7], ["gauge", 0.45], ["cpu", 0.3], ["battery-medium", 0.6]]
            Row {
              required property var modelData
              spacing: root.u * 2
              Icon { name: parent.modelData[0]; width: root.u * 9; anchors.verticalCenter: parent.verticalCenter }
              Meter { width: root.u * 14; value: parent.modelData[1]; anchors.verticalCenter: parent.verticalCenter }
            }
          }
        }
      }
    }
  }

  // ---- calendar
  Component {
    id: calendarCard
    Item {
      Glass {
        anchors.centerIn: parent
        width: cardMonth.width + root.u * 8
        height: parent.height
        radius: root.u * 4
        Bar { id: cardTitle; anchors.horizontalCenter: parent.horizontalCenter; y: root.u * 3; width: root.u * 16; height: root.u * 2.2; opacity: 0.8 }
        Month { id: cardMonth; anchors.horizontalCenter: parent.horizontalCenter; anchors.top: cardTitle.bottom; anchors.topMargin: root.u * 1.2; cell: root.u * 4.1 }
      }
    }
  }
  Component {
    id: calendarPlain
    Item {
      Column {
        anchors.centerIn: parent
        spacing: root.u * 1.2
        Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 16; height: root.u * 2.2; opacity: 0.8 }
        Month { anchors.horizontalCenter: parent.horizontalCenter; cell: root.u * 4.1 }
      }
    }
  }

  // This week as a strip: seven days, today (Saturday the 7th) ringed.
  Component {
    id: calendarWeek
    Item {
      Glass {
        anchors.centerIn: parent
        width: weekRow.width + root.u * 8
        height: weekRow.height + root.u * 8
        radius: root.u * 4
        Row {
          id: weekRow
          anchors.centerIn: parent
          spacing: root.u * 1.4
          Repeater {
            model: 7
            Column {
              id: weekDay
              required property int index
              spacing: root.u * 1.6
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.u * 3
                height: Math.max(1, root.u * 1)
                radius: height / 2
                color: Qt.alpha(root.ink, 0.5)
              }
              Item {
                width: root.u * 7
                height: width
                Rectangle {
                  anchors.centerIn: parent
                  visible: weekDay.index === 5
                  width: parent.width
                  height: width
                  radius: width / 2
                  color: Commons.Color.accent
                }
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * 0.34
                  height: width
                  radius: width / 2
                  color: root.ink
                  opacity: 0.8
                }
              }
            }
          }
        }
      }
    }
  }
  // A smaller month without a card.
  Component {
    id: calendarMini
    Item {
      Column {
        anchors.centerIn: parent
        spacing: root.u
        Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 12; height: root.u * 1.8; opacity: 0.8 }
        Month { anchors.horizontalCenter: parent.horizontalCenter; cell: root.u * 3.4 }
      }
    }
  }

  // ---- weather (a sample: partly cloudy, 12°)
  // The kit's Lucide icon (an image: it draws in every renderer).
  component WeatherIcon: FoamyIcon {
    name: "cloud-sun"
    color: root.ink
  }
  component Temperature: Text {
    text: FoamyI18n.number(12) + "°"
    textFormat: Text.PlainText
    color: root.ink
    font.family: FoamyStyle.fontFamily
  }
  // An icon and the temperature, no surface.
  Component {
    id: weatherCompact
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 3
        WeatherIcon { anchors.verticalCenter: parent.verticalCenter; width: root.u * 14; height: width }
        Temperature { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: Math.round(root.u * 15) }
      }
    }
  }
  // One line in a glass pill.
  Component {
    id: weatherPill
    Item {
      Glass {
        anchors.centerIn: parent
        width: pillLine.width + root.u * 12
        height: root.u * 16
        radius: height / 2
        Row {
          id: pillLine
          anchors.centerIn: parent
          spacing: root.u * 3
          WeatherIcon { anchors.verticalCenter: parent.verticalCenter; width: root.u * 9; height: width }
          Temperature { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: Math.round(root.u * 8); font.weight: Font.DemiBold }
          Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 16; opacity: 0.6 }
        }
      }
    }
  }
  // A glass card: the icon and a large temperature, then the condition
  // and today's high and low.
  Component {
    id: weatherDetailed
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 50
        height: parent.height
        radius: root.u * 4
        Row {
          id: cardHead
          x: root.u * 5
          y: root.u * 4
          spacing: root.u * 3
          WeatherIcon { anchors.verticalCenter: parent.verticalCenter; width: root.u * 13; height: width }
          Temperature { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: Math.round(root.u * 14); font.weight: Font.Light }
        }
        Column {
          anchors.top: cardHead.bottom
          anchors.topMargin: root.u * 2.5
          x: root.u * 5
          spacing: root.u * 2.5
          Bar { width: root.u * 30; opacity: 0.8 }
          Bar { width: root.u * 22; opacity: 0.55 }
        }
      }
    }
  }

  // One line of text: the condition, then the temperature.
  Component {
    id: weatherLine
    Item {
      Row {
        anchors.centerIn: parent
        spacing: root.u * 3
        Bar { anchors.verticalCenter: parent.verticalCenter; width: root.u * 24; opacity: 0.7 }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "·"
          color: root.ink
          font.family: FoamyStyle.fontFamily
          font.pixelSize: Math.round(root.u * 9)
        }
        Temperature { anchors.verticalCenter: parent.verticalCenter; font.pixelSize: Math.round(root.u * 9); font.weight: Font.DemiBold }
      }
    }
  }
  // A large temperature, the condition small under it.
  Component {
    id: weatherLarge
    Item {
      Column {
        anchors.centerIn: parent
        spacing: root.u * 1.5
        Temperature { anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: Math.round(root.u * 22); font.weight: Font.Light }
        Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 20; opacity: 0.6 }
      }
    }
  }
  // A centred glass card: the icon, the temperature, the condition, the
  // high and low.
  Component {
    id: weatherCard
    Item {
      Glass {
        anchors.centerIn: parent
        width: root.u * 34
        height: parent.height
        radius: root.u * 4
        Column {
          anchors.centerIn: parent
          spacing: root.u * 1.5
          WeatherIcon { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 10; height: width }
          Temperature { anchors.horizontalCenter: parent.horizontalCenter; font.pixelSize: Math.round(root.u * 10); font.weight: Font.Light }
          Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 20; opacity: 0.8 }
          Bar { anchors.horizontalCenter: parent.horizontalCenter; width: root.u * 14; opacity: 0.55 }
        }
      }
    }
  }

  // ---- background decorations (start and end mirror with the page)
  component Field: Rectangle {
    width: root.u * 18
    height: root.u * 4
    radius: height / 2
    color: root.soft
    border.width: 1
    border.color: root.edge
  }
  Component { id: decorNone; Item { Screen { Field { anchors.centerIn: parent } } } }
  Component {
    id: decorSplit
    Item {
      Screen {
        Rectangle {
          id: splitPanel
          anchors.left: parent.left
          width: parent.width * 0.4
          height: parent.height
          color: Qt.alpha(root.ink, 0.28)
        }
        Rectangle { anchors.left: splitPanel.right; width: Math.max(1, root.u * 0.8); height: parent.height; color: Commons.Color.accent }
        Field { anchors.horizontalCenter: splitPanel.horizontalCenter; anchors.verticalCenter: parent.verticalCenter; width: splitPanel.width * 0.7 }
      }
    }
  }
  Component {
    id: decorSheet
    Item {
      Screen {
        Rectangle {
          id: sheetPanel
          anchors.right: parent.right
          anchors.rightMargin: root.u * 3
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * 0.32
          height: parent.height - root.u * 6
          radius: root.u * 2
          color: root.soft
          border.width: 1
          border.color: root.edge
        }
        Field { anchors.horizontalCenter: sheetPanel.horizontalCenter; anchors.verticalCenter: parent.verticalCenter; width: sheetPanel.width * 0.75 }
      }
    }
  }
  Component {
    id: decorCinema
    Item {
      Screen {
        Rectangle { width: parent.width; height: parent.height * 0.2; color: root.ink; opacity: 0.6 }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: parent.height * 0.2; color: root.ink; opacity: 0.6 }
        Field { anchors.horizontalCenter: parent.horizontalCenter; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }
  Component {
    id: decorStrip
    Item {
      Screen {
        Rectangle {
          id: stripBand
          anchors.bottom: parent.bottom
          width: parent.width
          height: parent.height * 0.24
          color: Qt.alpha(root.ink, 0.28)
        }
        Field { anchors.centerIn: stripBand; width: root.u * 14; height: root.u * 3.4 }
      }
    }
  }
  Component {
    id: decorIsland
    Item {
      Screen {
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: root.u * 3
          width: parent.width * 0.34
          height: root.u * 8
          radius: height / 2
          color: root.ink
          opacity: 0.6
        }
        Field { anchors.horizontalCenter: parent.horizontalCenter; anchors.verticalCenter: parent.verticalCenter }
      }
    }
  }
  Component {
    id: decorFrame
    Item {
      Screen {
        Rectangle {
          anchors.fill: parent
          anchors.margins: root.u * 3
          radius: root.u * 1.5
          color: "transparent"
          border.width: Math.max(1.5, root.u * 1.2)
          border.color: root.ink
        }
        Field { anchors.centerIn: parent }
      }
    }
  }
  Component {
    id: decorCard
    Item {
      Screen {
        Rectangle {
          anchors.centerIn: parent
          width: parent.width * 0.4
          height: parent.height * 0.62
          radius: root.u * 2
          color: root.soft
          border.width: 1
          border.color: root.edge
        }
        Field { anchors.centerIn: parent; width: parent.width * 0.3 }
      }
    }
  }

  // ---- an animation (the background page's picker): the lock's own drawing
  // (elements/Backdrop.qml) in its still frame, on the theme's background,
  // drawn at a small screen's size and scaled down, so every animation
  // Layout.js lists has its picture. Never moves (no motion allowed).
  Component {
    id: animationArt
    Item {
      Screen {
        id: animationScreen
        color: Commons.Color.background
        Elements.Backdrop {
          width: 480
          height: 300
          view: stillView
          source: root.styleName
          transform: Scale { xScale: animationScreen.width / 480; yScale: animationScreen.height / 300 }
        }
      }
      // What Backdrop reads from its LockView.
      QtObject {
        id: stillView
        readonly property real uiScale: 0.5
        readonly property bool motionAllowed: false
        readonly property bool reduceMotion: true
        readonly property color accent: Commons.Color.accent
        readonly property color foreground: Commons.Color.foreground
        readonly property string passwordText: ""
      }
    }
  }

  // ---- a style the studio doesn't know yet
  Component {
    id: generic
    Item {
      Rectangle {
        anchors.centerIn: parent
        width: root.u * 44
        height: root.u * 26
        radius: root.u * 4
        color: root.faint
        border.width: 1
        border.color: root.edge
        Icon { name: "box"; anchors.centerIn: parent; color: Qt.alpha(root.ink, 0.7) }
      }
    }
  }
}
