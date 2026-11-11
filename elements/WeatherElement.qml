import QtQuick
import "../kit"

// The current weather from Foamy Weather (the service fetches and checks it;
// see Model.parseWeather): the view's `weather`, or nothing (LockView hides
// the element without one). Styles:
// - "compact": an icon and the temperature, no surface;
// - "pill": one line in a glass pill;
// - "detailed": a glass card;
// - "line": one line of text, no icon or surface: the condition and the
//   temperature ("Light rain · 6°");
// - "large": the temperature in the display face, the condition small
//   under it;
// - "card": a centred glass card: the icon, the temperature, the condition
//   and today's high and low, always (the full report).
// `details` "full" adds the condition and today's high and low (the line
// and large styles show the condition anyway); `showLocation` the place
// name. Every string is drawn as plain text and elides within the element,
// so a long condition or place can't push it off screen. Plain x, mirrored
// by hand, like the other elements.
Item {
  id: weather
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
  readonly property real surfaceRadius: glassy ? (pill ? height / 2 : Math.round(22 * unit)) : -1
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "start"
  property string styleName: "compact"
  // "temperature" or "full".
  property string details: "temperature"
  property bool showLocation: false
  readonly property bool compact: styleName === "compact"
  readonly property bool pill: styleName === "pill"
  readonly property bool detailed: styleName === "detailed"
  readonly property bool textLine: styleName === "line"
  readonly property bool large: styleName === "large"
  readonly property bool card: styleName === "card"
  // The styles drawn on glass, and those with the icon.
  readonly property bool glassy: pill || detailed || card
  readonly property bool iconShown: compact || detailed || card
  readonly property bool full: details === "full" || card
  readonly property var report: view.weather || null
  readonly property real unit: uiScale
  readonly property string temperatureText: report ? FoamyI18n.number(report.temperature) + "°" : ""
  // The condition: with "full", and always in the line, large and card.
  readonly property string conditionText: report && (full || textLine || large) ? String(report.condition || "") : ""
  readonly property string rangeText: report && full && report.high !== null && report.low !== null ? FoamyI18n.t("High %1", [FoamyI18n.number(report.high) + "°"]) + "  " + FoamyI18n.t("Low %1", [FoamyI18n.number(report.low) + "°"]) : ""
  readonly property string locationText: report && showLocation ? String(report.location || "") : ""
  // The widest it grows: the centre column at its scale.
  readonly property real maxWidth: view.contentWidthAt(uiScale)
  readonly property real padding: Math.round((pill ? 18 : detailed || card ? 20 : 0) * unit)
  readonly property real gap: Math.round(10 * unit)
  // The line under the temperature: "compact", the high and low first (they
  // are short, so a long condition elides after them); "large", the
  // condition, then the high and low; "detailed" and "card", the condition
  // alone, the high and low on a line of their own.
  readonly property string detailText: detailed || card ? conditionText : (compact ? [rangeText, conditionText] : [conditionText, rangeText]).filter(function (part) {
    return part !== ""
  }).join("  ·  ")
  // "line": everything on one line, the condition first.
  readonly property string lineText: [conditionText, temperatureText, rangeText, locationText].filter(function (part) {
    return part !== ""
  }).join(" · ")
  readonly property real headWidth: (iconShown && !card ? icon.width + gap : 0) + temperature.implicitWidth
  // The width it needs (and takes: the weather never fills the centre column).
  readonly property real naturalWidth: detailed ? Math.min(maxWidth, Math.round(300 * unit)) : card ? Math.min(maxWidth, Math.round(240 * unit)) : pill ? Math.min(maxWidth, line.implicitWidth + 2 * padding) : textLine ? Math.min(maxWidth, lineLabel.implicitWidth) : Math.min(maxWidth, Math.max(headWidth, detailLine.shown ? detailLine.implicitWidth : 0, placeLine.shown ? placeLine.implicitWidth : 0))
  readonly property real innerWidth: width - 2 * padding
  // The card centres its lines; the others follow the zone.
  readonly property int textAlignment: card || alignment === "center" ? Text.AlignHCenter : alignment === "end" ? Text.AlignRight : Text.AlignLeft

  objectName: "weatherBlock"
  width: naturalWidth
  height: pill ? Math.round(44 * unit) : textLine ? Math.round(30 * unit) : lastLineBottom + padding
  // Where the lines below the temperature end. Each line's own `shown`, not
  // `visible`, which is false in a hidden view (Lock Studio measures and
  // checks looks in views that are never drawn).
  readonly property real lastLineBottom: placeLine.shown ? placeLine.y + placeLine.height : rangeLine.shown ? rangeLine.y + rangeLine.height : detailLine.shown ? detailLine.y + detailLine.height : head.y + head.height

  // Where a part of `partWidth` starts inside the element, on screen.
  function startX(partWidth) {
    var free = Math.max(0, innerWidth - partWidth)
    var start = alignment === "center" || pill || card ? free / 2 : alignment === "start" ? 0 : free
    return padding + (view.rightToLeft ? free - start : start)
  }

  // The lock's own line icons, one per condition group (Model.weatherGroup).
  function iconPath(group) {
    var cloud = "M7 18a4 4 0 0 1-.6-7.96A5.5 5.5 0 0 1 17 9.5a4.25 4.25 0 0 1 0 8.5Z"
    var high = "M7 14a4 4 0 0 1-.6-7.96A5.5 5.5 0 0 1 17 5.5a4.25 4.25 0 0 1 0 8.5Z"
    switch (group) {
    case "clear":
      return "M12 8a4 4 0 1 0 0 8 4 4 0 1 0 0-8Z M12 2v2 M12 20v2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M2 12h2 M20 12h2 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4"
    case "partly":
      return "M8 2.5v1.5 M3.2 4.2l1.1 1.1 M12.8 4.2l-1.1 1.1 M2 9h1.5 M4.6 11.6A3.5 3.5 0 1 1 11.4 7.6 M9 20a3.5 3.5 0 0 1-.5-6.96A5 5 0 0 1 18 12.5a3.75 3.75 0 0 1 0 7.5Z"
    case "fog":
      return "M5 7h14 M3 11h18 M5 15h14 M8 19h8"
    case "rain":
      return high + " M8 17l-1 3 M12 17l-1 3 M16 17l-1 3"
    case "sleet":
      return high + " M8 17l-1 3 M16 17l-1 3 M12 18.5h.01"
    case "snow":
      return high + " M8 17.5h.01 M12 19.5h.01 M16 17.5h.01 M10 21.5h.01 M14 21.5h.01"
    case "thunder":
      return high + " M13 15l-3 4h4l-3 4"
    }
    return cloud
  }

  // The glass behind the pill and the cards.
  Rectangle {
    objectName: "weatherSurface"
    anchors.fill: parent
    visible: weather.glassy && weather.surfaceShown
    radius: weather.surfaceRadius
    color: weather.glassFill
    border.width: 1
    border.color: weather.view.glassBorder
  }

  // "compact", "detailed", "large" and "card": the temperature, after the
  // icon (the card: under it, centred; "large": no icon).
  Item {
    id: head
    objectName: "weatherHead"
    // Its own flag, not `visible` (false in a hidden view).
    readonly property bool shown: weather.compact || weather.detailed || weather.large || weather.card
    visible: shown
    readonly property real iconHeight: weather.card ? icon.height + Math.round(4 * weather.unit) : 0
    x: weather.card ? weather.padding : weather.startX(width)
    y: weather.padding
    width: weather.card ? weather.innerWidth : Math.min(weather.headWidth, weather.innerWidth)
    height: iconHeight + Math.round((weather.large ? 64 : weather.detailed ? 52 : weather.card ? 48 : 40) * weather.unit)

    LineIcon {
      id: icon
      objectName: "weatherIcon"
      visible: weather.iconShown
      x: weather.card ? (head.width - width) / 2 : weather.view.rightToLeft ? head.width - width : 0
      y: weather.card ? 0 : (head.height - height) / 2
      width: Math.round((weather.detailed ? 40 : weather.card ? 36 : 28) * weather.unit)
      height: width
      pathData: weather.iconPath(weather.report ? weather.view.weatherGroup(weather.report.code) : "")
      opacity: 0.9
    }

    Text {
      id: temperature
      objectName: "weatherTemperature"
      readonly property real lead: weather.iconShown && !weather.card ? icon.width + weather.gap : 0
      x: weather.view.rightToLeft || weather.card ? 0 : lead
      y: head.iconHeight
      width: Math.max(0, head.width - (weather.card ? 0 : lead))
      height: head.height - head.iconHeight
      textFormat: Text.PlainText
      text: weather.temperatureText
      color: weather.view.foreground
      font.family: weather.view.displayFontFamily
      font.pixelSize: Math.round((weather.large ? 56 : weather.detailed ? 44 : weather.card ? 40 : 30) * weather.unit)
      font.weight: weather.detailed || weather.large || weather.card ? Font.Light : Font.Normal
      horizontalAlignment: weather.card ? Text.AlignHCenter : Text.AlignLeft
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }

  Text {
    id: detailLine
    objectName: "weatherCondition"
    readonly property bool shown: head.shown && weather.detailText !== ""
    visible: shown
    x: weather.padding
    y: head.y + head.height + Math.round(2 * weather.unit)
    width: weather.innerWidth
    textFormat: Text.PlainText
    text: weather.detailText
    color: weather.view.foreground
    opacity: 0.86
    font.family: weather.view.textFontFamily
    font.pixelSize: Math.round((weather.large ? 14 : 15) * weather.unit)
    font.weight: Font.Medium
    horizontalAlignment: weather.textAlignment
    elide: Text.ElideRight
  }

  // "detailed" and "card": today's high and low.
  Text {
    id: rangeLine
    objectName: "weatherRange"
    readonly property bool shown: (weather.detailed || weather.card) && weather.rangeText !== ""
    visible: shown
    x: weather.padding
    y: (detailLine.shown ? detailLine.y + detailLine.height : head.y + head.height) + Math.round(2 * weather.unit)
    width: weather.innerWidth
    textFormat: Text.PlainText
    text: weather.rangeText
    color: weather.view.foreground
    opacity: 0.8
    font.family: weather.view.textFontFamily
    font.pixelSize: Math.round(14 * weather.unit)
    horizontalAlignment: weather.textAlignment
    elide: Text.ElideRight
  }

  Text {
    id: placeLine
    objectName: "weatherLocation"
    readonly property bool shown: head.shown && weather.locationText !== ""
    visible: shown
    x: weather.padding
    y: (rangeLine.shown ? rangeLine.y + rangeLine.height : detailLine.shown ? detailLine.y + detailLine.height : head.y + head.height) + Math.round(2 * weather.unit)
    width: weather.innerWidth
    textFormat: Text.PlainText
    text: weather.locationText
    color: weather.view.foreground
    opacity: 0.72
    font.family: weather.view.textFontFamily
    font.pixelSize: Math.round(14 * weather.unit)
    horizontalAlignment: weather.textAlignment
    elide: Text.ElideRight
  }

  // "line": the condition, the temperature (then the high and low, and the
  // place) as one line of text, eliding at the end.
  Text {
    id: lineLabel
    objectName: "weatherText"
    visible: weather.textLine
    x: weather.startX(width)
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, weather.innerWidth)
    textFormat: Text.PlainText
    text: weather.lineText
    color: weather.view.foreground
    opacity: 0.9
    font.family: weather.view.textFontFamily
    font.pixelSize: Math.round(16 * weather.unit)
    font.weight: Font.Medium
    elide: Text.ElideRight
  }

  // "pill": everything on one line, centred; the condition and the place
  // elide first when the line is too long.
  Row {
    id: line
    objectName: "weatherLine"
    visible: weather.pill
    readonly property real fixedWidth: pillIcon.width + pillTemperature.implicitWidth + pillRange.implicitWidth + (parts - 1) * spacing
    // The parts on the line (not visibleChildren: none are in a hidden view).
    readonly property int parts: 2 + (weather.conditionText !== "" ? 1 : 0) + (weather.rangeText !== "" ? 1 : 0) + (weather.locationText !== "" ? 1 : 0)
    readonly property real room: Math.max(0, weather.maxWidth - 2 * weather.padding - fixedWidth)
    x: weather.startX(width)
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, weather.innerWidth)
    spacing: weather.gap

    LineIcon {
      id: pillIcon
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round(22 * weather.unit)
      height: width
      pathData: weather.iconPath(weather.report ? weather.view.weatherGroup(weather.report.code) : "")
      opacity: 0.9
    }

    Text {
      id: pillTemperature
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: weather.temperatureText
      color: weather.view.foreground
      font.family: weather.view.textFontFamily
      font.pixelSize: Math.round(18 * weather.unit)
      font.weight: Font.DemiBold
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      width: Math.min(implicitWidth, Math.round(line.room * (weather.locationText !== "" ? 0.55 : 1)))
      textFormat: Text.PlainText
      text: weather.conditionText
      color: weather.view.foreground
      opacity: 0.86
      font.family: weather.view.textFontFamily
      font.pixelSize: Math.round(15 * weather.unit)
      elide: Text.ElideRight
    }

    Text {
      id: pillRange
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      textFormat: Text.PlainText
      text: weather.rangeText
      color: weather.view.foreground
      opacity: 0.72
      font.family: weather.view.textFontFamily
      font.pixelSize: Math.round(14 * weather.unit)
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      width: Math.min(implicitWidth, Math.round(line.room * (weather.conditionText !== "" ? 0.45 : 1)))
      textFormat: Text.PlainText
      text: weather.locationText
      color: weather.view.foreground
      opacity: 0.72
      font.family: weather.view.textFontFamily
      font.pixelSize: Math.round(14 * weather.unit)
      elide: Text.ElideRight
    }
  }
}
