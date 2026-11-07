import QtQuick
import "../kit"

// The clock. Styles:
// - "thin": the large display numerals; "bold": heavier and tighter;
//   "mono": the Omarchy mono font. These shrink to fit the width.
// - "stacked": heavy hours over minutes with a tight line height.
// - "outline": heavy numerals drawn as outlines (a Canvas stroke, which every
//   renderer draws; Text.Outline fills solid under the software renderer).
// - "dots": a dot-matrix LED face (a 5×7 dot font on a Canvas).
// - "flip": hours and minutes on two dark rounded cards with a seam.
// - "analog": a round face with hour and minute hands (a Canvas).
// - "small": one line in the text face, for a bar or a card.
// - "poster": huge heavy hours over minutes, the minutes in the accent.
// - "ring": the time inside a ring that fills with the minutes of the hour.
// The host sets the width in the center column; elsewhere it is
// `naturalWidth`. Nothing here animates.
Item {
  id: clock
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "thin"
  readonly property bool bold: styleName === "bold"
  readonly property bool mono: styleName === "mono"
  readonly property bool small: styleName === "small"
  // The styles drawn by the single text line below.
  readonly property bool textual: styleName === "thin" || bold || mono || small
  readonly property bool twelveHour: view.timeFormat === "12h"
  readonly property real uiScale: view.uiScale
  // Stacked under another element, the numerals' top bearing would leave a
  // gap: pull the clock up instead of the zone's usual spacing. The drawn
  // faces have no bearing and keep a small gap.
  readonly property real stackGap: Math.round((bold ? -12 : styleName === "thin" ? -20 : mono ? -14
    : styleName === "stacked" ? -14 : styleName === "outline" ? -8 : small ? 2 : styleName === "poster" ? -10 : 10) * uiScale)
  // The main line, as the tests read it.
  readonly property alias text: label.text
  readonly property alias font: label.font
  readonly property int textAlignment: alignment === "start" ? Text.AlignLeft
    : alignment === "end" ? Text.AlignRight : Text.AlignHCenter
  readonly property string hours: hourText()
  readonly property string minutes: view.userLocale.toString(view.now, "mm")
  readonly property string meridiem: twelveHour ? view.userLocale.toString(view.now, "AP") : ""
  // The width it needs outside the center column.
  readonly property real naturalWidth: {
    switch (styleName) {
    case "stacked": return Math.max(stacked.implicitWidth, stackedMeridiem.visible ? stackedMeridiem.implicitWidth : 0)
    case "outline": return outline.naturalWidth
    case "dots": return dots.naturalWidth
    case "flip": return flip.naturalWidth
    case "analog": return analog.diameter
    case "poster": return poster.naturalWidth
    case "ring": return ring.diameter
    }
    return label.implicitWidth
  }

  objectName: "clockLabel"
  height: {
    switch (styleName) {
    case "stacked": return stackedMeridiem.visible ? stackedMeridiem.y + stackedMeridiem.height : stacked.height
    case "outline": return outline.height
    case "dots": return dots.height
    case "flip": return flip.height
    case "analog": return analog.height
    case "poster": return poster.height
    case "ring": return ring.height
    }
    return label.height
  }

  // Two-digit hours (12- or 24-hour) in the locale's digits.
  function hourText() {
    var at = new Date(view.now.getTime())
    if (twelveHour) at.setHours(at.getHours() % 12 || 12)
    return view.userLocale.toString(at, "HH")
  }

  // The x of a block `blockWidth` wide inside the clock, by alignment;
  // mirrored by hand (plain x, no anchors switched at runtime).
  function blockX(blockWidth) {
    if (alignment === "center") return Math.round((width - blockWidth) / 2)
    return (alignment === "start") !== view.rightToLeft ? 0 : Math.round(width - blockWidth)
  }

  Text {
    id: label
    visible: clock.textual
    width: clock.width
    textFormat: Text.PlainText
    text: clock.view.userLocale.toString(clock.view.now, clock.twelveHour ? "h:mm AP" : "HH:mm")
    fontSizeMode: Text.Fit
    minimumPixelSize: Math.round((clock.small ? 18 : 48) * clock.uiScale)
    color: clock.view.foreground
    font.family: clock.mono ? FoamyStyle.monoFamily : clock.bold || clock.small ? clock.view.textFontFamily : clock.view.displayFontFamily
    font.pixelSize: Math.round((clock.bold ? 150 : clock.mono ? 140 : clock.small ? 34 : 192) * clock.uiScale)
    font.weight: clock.bold ? Font.Bold : clock.mono ? Font.Medium : clock.small ? Font.DemiBold : Font.Normal
    font.letterSpacing: clock.bold ? Math.round(-4 * clock.uiScale) : clock.mono ? Math.round(-6 * clock.uiScale) : 0
    horizontalAlignment: clock.textAlignment
  }

  // "stacked": hours over minutes, heavy, the lines pulled together.
  Text {
    id: stacked
    objectName: "clockStacked"
    visible: clock.styleName === "stacked"
    width: clock.width
    textFormat: Text.PlainText
    text: clock.hours + "\n" + clock.minutes
    color: clock.view.foreground
    font.family: clock.view.textFontFamily
    font.pixelSize: Math.round(124 * clock.uiScale)
    font.weight: Font.Black
    font.letterSpacing: Math.round(-3 * clock.uiScale)
    lineHeightMode: Text.ProportionalHeight
    lineHeight: 0.8
    horizontalAlignment: clock.textAlignment
  }

  Text {
    id: stackedMeridiem
    visible: stacked.visible && clock.twelveHour
    // The last line's full height leaves room under the numerals: tuck in.
    y: stacked.height - Math.round(14 * clock.uiScale)
    width: clock.width
    textFormat: Text.PlainText
    text: clock.meridiem
    color: clock.view.foreground
    opacity: 0.86
    font.family: clock.view.textFontFamily
    font.pixelSize: Math.round(17 * clock.uiScale)
    font.weight: Font.DemiBold
    font.letterSpacing: Math.round(3 * clock.uiScale)
    horizontalAlignment: clock.textAlignment
  }

  // "outline": the numerals stroked on a Canvas in the display face (its
  // glyphs have no overlapping contours to show through the stroke).
  Canvas {
    id: outline
    objectName: "clockOutline"
    readonly property real stroke: Math.max(1.5, Math.round(2.5 * clock.uiScale * 2) / 2)
    readonly property real baseSize: Math.round(176 * clock.uiScale)
    readonly property real naturalWidth: Math.ceil(outlineMetrics.advanceWidth + 2 * stroke)
    // Shrinks to fit the width, like the text styles.
    readonly property real fontSize: outlineMetrics.advanceWidth > 0
      ? Math.max(Math.round(48 * clock.uiScale),
        Math.min(baseSize, Math.floor(baseSize * (clock.width - 2 * stroke) / outlineMetrics.advanceWidth)))
      : baseSize
    readonly property string family: clock.view.displayFontFamily
    readonly property string time: label.text
    readonly property real textWidth: outlineMetrics.advanceWidth * fontSize / baseSize
    readonly property string paintKey: [time, fontSize, width, height, clock.view.foreground, family, stroke].join("|")

    visible: clock.styleName === "outline"
    x: clock.blockX(width)
    width: Math.min(clock.width, Math.ceil(textWidth + 2 * stroke))
    height: Math.ceil(outlineFont.height + 2 * stroke)
    antialiasing: true
    onPaintKeyChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    TextMetrics {
      id: outlineMetrics
      font.family: outline.family
      font.pixelSize: outline.baseSize
      font.weight: Font.Bold
      text: outline.time
    }

    FontMetrics {
      id: outlineFont
      font.family: outline.family
      font.pixelSize: outline.fontSize
      font.weight: Font.Bold
    }

    onPaint: {
      var context = getContext("2d")
      context.reset()
      context.clearRect(0, 0, width, height)
      context.font = "bold " + fontSize + "px \"" + family + "\""
      context.textBaseline = "alphabetic"
      context.lineJoin = "round"
      context.lineWidth = stroke
      context.strokeStyle = clock.view.foreground
      context.strokeText(time, stroke, stroke + outlineFont.ascent)
    }
  }

  // "dots": a 5×7 dot-matrix face; unlit dots stay faintly visible like an
  // LED panel. The meridiem sits beside it in small capitals.
  Item {
    id: dots
    objectName: "clockDots"
    // Each glyph: 7 rows of columns, "#" lit.
    readonly property var glyphs: ({
      "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
      "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
      "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
      "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
      "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
      "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
      "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
      "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
      "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
      "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
      ":": [".", ".", "#", ".", "#", ".", "."]
    })
    // ASCII digits from the time itself: the dot font has no other script.
    readonly property string time: {
      var hour = clock.view.now.getHours()
      if (clock.twelveHour) hour = hour % 12 || 12
      var minute = clock.view.now.getMinutes()
      return (hour < 10 && !clock.twelveHour ? "0" : "") + hour + ":" + (minute < 10 ? "0" : "") + minute
    }
    readonly property int columns: {
      var total = 0
      for (var i = 0; i < time.length; i++) total += (i > 0 ? 1 : 0) + glyphs[time[i]][0].length
      return total
    }
    readonly property real basePitch: Math.round(16 * clock.uiScale)
    readonly property real meridiemSpace: dotsMeridiem.visible ? dotsMeridiem.implicitWidth + Math.round(12 * clock.uiScale) : 0
    readonly property real naturalWidth: columns * basePitch + meridiemSpace
    readonly property real pitch: Math.max(4, Math.min(basePitch, Math.floor((clock.width - meridiemSpace) / columns)))

    visible: clock.styleName === "dots"
    x: clock.blockX(width)
    width: columns * pitch + meridiemSpace
    height: 7 * pitch

    Canvas {
      id: matrix
      readonly property string paintKey: [dots.time, dots.pitch, clock.view.foreground].join("|")
      x: clock.view.rightToLeft ? dots.meridiemSpace : 0
      width: dots.columns * dots.pitch
      height: dots.height
      antialiasing: true
      onPaintKeyChanged: requestPaint()
      onVisibleChanged: if (visible) requestPaint()
      onPaint: {
        var context = getContext("2d")
        context.reset()
        context.clearRect(0, 0, width, height)
        context.fillStyle = clock.view.foreground
        var pitch = dots.pitch
        var radius = pitch * 0.36
        var column = 0
        for (var i = 0; i < dots.time.length; i++) {
          var glyph = dots.glyphs[dots.time[i]]
          var span = glyph[0].length + (i < dots.time.length - 1 ? 1 : 0)
          for (var c = 0; c < span; c++) {
            for (var r = 0; r < 7; r++) {
              var lit = c < glyph[r].length && glyph[r][c] === "#"
              context.globalAlpha = lit ? 1 : 0.09
              context.beginPath()
              context.arc((column + c + 0.5) * pitch, (r + 0.5) * pitch, radius, 0, Math.PI * 2)
              context.fill()
            }
          }
          column += span
        }
      }
    }

    Text {
      id: dotsMeridiem
      visible: clock.twelveHour
      x: clock.view.rightToLeft ? 0 : matrix.width + Math.round(12 * clock.uiScale)
      y: dots.height - height + Math.round(2 * clock.uiScale)
      textFormat: Text.PlainText
      text: clock.meridiem
      color: clock.view.foreground
      opacity: 0.86
      font.family: FoamyStyle.monoFamily
      font.pixelSize: Math.round(20 * clock.uiScale)
      font.weight: Font.Bold
    }
  }

  // "flip": two dark cards, hours and minutes, each split by a seam. They
  // keep the time's reading order in every language.
  Item {
    id: flip
    objectName: "clockFlip"
    readonly property real gap: Math.round(14 * clock.uiScale)
    readonly property real baseCard: Math.round(172 * clock.uiScale)
    readonly property real cardWidth: Math.min(baseCard, Math.floor((clock.width - gap) / 2))
    readonly property real naturalWidth: 2 * baseCard + gap

    visible: clock.styleName === "flip"
    x: clock.blockX(width)
    width: 2 * cardWidth + gap
    height: Math.round(cardWidth * 1.08)

    Repeater {
      model: 2

      Rectangle {
        required property int index
        x: index * (flip.cardWidth + flip.gap)
        width: flip.cardWidth
        height: flip.height
        radius: Math.round(16 * clock.uiScale)
        color: Qt.rgba(0.02, 0.025, 0.045, 0.78)
        border.width: 1
        border.color: clock.view.glassBorder

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: parent.index === 0 ? clock.hours : clock.minutes
          color: clock.view.foreground
          font.family: clock.view.textFontFamily
          font.pixelSize: Math.round(parent.width * 0.66)
          font.weight: Font.Bold
          font.letterSpacing: Math.round(-2 * clock.uiScale)
        }

        // The seam: a dark split with a faint highlight under it.
        Rectangle {
          y: Math.round(parent.height / 2) - height
          width: parent.width
          height: Math.max(2, Math.round(3 * clock.uiScale))
          color: Qt.rgba(0, 0, 0, 0.55)
        }

        Rectangle {
          y: Math.round(parent.height / 2)
          width: parent.width
          height: 1
          color: Qt.rgba(1, 1, 1, 0.08)
        }

        Text {
          visible: parent.index === 0 && clock.twelveHour
          x: Math.round(12 * clock.uiScale)
          y: parent.height - height - Math.round(8 * clock.uiScale)
          textFormat: Text.PlainText
          text: clock.meridiem
          color: clock.view.foreground
          opacity: 0.8
          font.family: clock.view.textFontFamily
          font.pixelSize: Math.round(14 * clock.uiScale)
          font.weight: Font.DemiBold
          font.letterSpacing: Math.round(1 * clock.uiScale)
        }
      }
    }
  }

  // "analog": a glass face with twelve ticks and two hands.
  Canvas {
    id: analog
    objectName: "clockAnalog"
    readonly property real diameter: Math.round(220 * clock.uiScale)
    readonly property real faceSize: Math.min(diameter, clock.width)
    readonly property string paintKey: [clock.view.now.getHours(), clock.view.now.getMinutes(), faceSize,
      clock.view.foreground, clock.view.glass, clock.view.glassBorder].join("|")

    visible: clock.styleName === "analog"
    x: clock.blockX(width)
    width: faceSize
    height: faceSize
    antialiasing: true
    onPaintKeyChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onPaint: {
      var context = getContext("2d")
      context.reset()
      context.clearRect(0, 0, width, height)
      var center = faceSize / 2
      var unit = clock.uiScale * faceSize / diameter
      var radius = center - 1
      context.fillStyle = clock.view.glass
      context.strokeStyle = clock.view.glassBorder
      context.lineWidth = 1
      context.beginPath()
      context.arc(center, center, radius, 0, Math.PI * 2)
      context.fill()
      context.stroke()
      context.strokeStyle = clock.view.foreground
      context.lineCap = "round"
      for (var tick = 0; tick < 12; tick++) {
        var major = tick % 3 === 0
        var angle = tick * Math.PI / 6
        var outer = radius - 14 * unit
        var inner = outer - (major ? 16 : 8) * unit
        context.globalAlpha = major ? 0.9 : 0.5
        context.lineWidth = (major ? 3 : 2) * unit
        context.beginPath()
        context.moveTo(center + Math.sin(angle) * inner, center - Math.cos(angle) * inner)
        context.lineTo(center + Math.sin(angle) * outer, center - Math.cos(angle) * outer)
        context.stroke()
      }
      context.globalAlpha = 1
      var minutes = clock.view.now.getMinutes()
      var hourAngle = ((clock.view.now.getHours() % 12) + minutes / 60) * Math.PI / 6
      var minuteAngle = minutes * Math.PI / 30
      var hands = [[hourAngle, radius * 0.5, 7 * unit], [minuteAngle, radius * 0.76, 4 * unit]]
      for (var i = 0; i < hands.length; i++) {
        context.lineWidth = hands[i][2]
        context.beginPath()
        context.moveTo(center - Math.sin(hands[i][0]) * 12 * unit, center + Math.cos(hands[i][0]) * 12 * unit)
        context.lineTo(center + Math.sin(hands[i][0]) * hands[i][1], center - Math.cos(hands[i][0]) * hands[i][1])
        context.stroke()
      }
      context.fillStyle = clock.view.foreground
      context.beginPath()
      context.arc(center, center, 6 * unit, 0, Math.PI * 2)
      context.fill()
    }
  }

  // "poster": hours over minutes, very large and heavy, the lines overlapping
  // a little as on a print; the minutes take the theme's accent.
  Item {
    id: poster
    objectName: "clockPoster"
    readonly property real fontSize: Math.round(250 * clock.uiScale)
    readonly property real lineStep: Math.round(fontSize * 0.84)
    readonly property real naturalWidth: Math.max(posterHours.implicitWidth, posterMinutes.implicitWidth)

    visible: clock.styleName === "poster"
    x: clock.blockX(width)
    width: Math.min(clock.width, Math.ceil(naturalWidth))
    height: posterMeridiem.visible ? posterMeridiem.y + posterMeridiem.height : posterMinutes.y + posterMinutes.height

    Text {
      id: posterHours
      width: poster.width
      height: poster.lineStep
      textFormat: Text.PlainText
      text: clock.hours
      color: clock.view.foreground
      font.family: clock.view.textFontFamily
      font.pixelSize: poster.fontSize
      font.weight: Font.Black
      font.letterSpacing: Math.round(-8 * clock.uiScale)
      horizontalAlignment: clock.textAlignment
      verticalAlignment: Text.AlignVCenter
    }

    Text {
      id: posterMinutes
      y: poster.lineStep
      width: poster.width
      height: poster.lineStep
      textFormat: Text.PlainText
      text: clock.minutes
      color: clock.view.accent
      font: posterHours.font
      horizontalAlignment: clock.textAlignment
      verticalAlignment: Text.AlignVCenter
    }

    Text {
      id: posterMeridiem
      visible: clock.twelveHour
      y: posterMinutes.y + posterMinutes.height + Math.round(4 * clock.uiScale)
      width: poster.width
      textFormat: Text.PlainText
      text: clock.meridiem
      color: clock.view.foreground
      opacity: 0.86
      font.family: clock.view.textFontFamily
      font.pixelSize: Math.round(22 * clock.uiScale)
      font.weight: Font.Bold
      font.letterSpacing: Math.round(4 * clock.uiScale)
      horizontalAlignment: clock.textAlignment
    }
  }

  // "ring": a faint track with the minutes of the hour drawn over it in the
  // accent, and the time in the middle. It changes once a minute, like the
  // other faces.
  Item {
    id: ring
    objectName: "clockRing"
    readonly property real diameter: Math.round(300 * clock.uiScale)
    readonly property real size: Math.min(diameter, clock.width)
    readonly property real unit: clock.uiScale * size / diameter

    visible: clock.styleName === "ring"
    x: clock.blockX(width)
    width: size
    height: size

    Canvas {
      id: ringFace
      readonly property string paintKey: [clock.view.now.getMinutes(), ring.size, clock.view.accent,
        clock.view.foreground, clock.view.glass].join("|")
      anchors.fill: parent
      antialiasing: true
      onPaintKeyChanged: requestPaint()
      onVisibleChanged: if (visible) requestPaint()
      onPaint: {
        var context = getContext("2d")
        context.reset()
        context.clearRect(0, 0, width, height)
        var center = ring.size / 2
        var line = Math.max(3, 9 * ring.unit)
        var radius = center - line / 2 - 1
        context.fillStyle = clock.view.glass
        context.beginPath()
        context.arc(center, center, radius - line / 2, 0, Math.PI * 2)
        context.fill()
        context.lineWidth = line
        context.lineCap = "round"
        context.strokeStyle = clock.view.foreground
        context.globalAlpha = 0.14
        context.beginPath()
        context.arc(center, center, radius, 0, Math.PI * 2)
        context.stroke()
        // Twelve faint marks inside the track.
        context.globalAlpha = 0.4
        context.lineWidth = Math.max(1, 2 * ring.unit)
        for (var mark = 0; mark < 12; mark++) {
          var angle = mark * Math.PI / 6
          var outer = radius - line - 6 * ring.unit
          var inner = outer - (mark % 3 === 0 ? 10 : 5) * ring.unit
          context.beginPath()
          context.moveTo(center + Math.sin(angle) * inner, center - Math.cos(angle) * inner)
          context.lineTo(center + Math.sin(angle) * outer, center - Math.cos(angle) * outer)
          context.stroke()
        }
        // The minutes so far, clockwise from the top; a dot at minute 0.
        var minutes = clock.view.now.getMinutes()
        context.globalAlpha = 1
        context.strokeStyle = clock.view.accent
        context.lineWidth = line
        context.beginPath()
        if (minutes > 0) {
          context.arc(center, center, radius, -Math.PI / 2, -Math.PI / 2 + minutes / 60 * Math.PI * 2, false)
          context.stroke()
        } else {
          context.fillStyle = clock.view.accent
          context.arc(center, center - radius, line / 2, 0, Math.PI * 2)
          context.fill()
        }
      }
    }

    Text {
      id: ringTime
      anchors.centerIn: parent
      anchors.verticalCenterOffset: ringMeridiem.visible ? -Math.round(10 * ring.unit) : 0
      textFormat: Text.PlainText
      text: clock.view.userLocale.toString(clock.view.now, clock.twelveHour ? "h:mm" : "HH:mm")
      color: clock.view.foreground
      font.family: clock.view.displayFontFamily
      font.pixelSize: Math.round(78 * ring.unit)
    }

    Text {
      id: ringMeridiem
      visible: clock.twelveHour
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: ringTime.bottom
      anchors.topMargin: -Math.round(6 * ring.unit)
      textFormat: Text.PlainText
      text: clock.meridiem
      color: clock.view.foreground
      opacity: 0.8
      font.family: clock.view.textFontFamily
      font.pixelSize: Math.round(16 * ring.unit)
      font.weight: Font.DemiBold
      font.letterSpacing: Math.round(3 * ring.unit)
    }
  }
}
