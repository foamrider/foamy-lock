import QtQuick
import "../kit"

// The current weather from Foamy Weather (the service fetches and checks it;
// see Model.parseWeather): the view's `weather`, or nothing (LockView hides
// the element without one). Styles: "compact" (an icon and the temperature,
// no surface), "pill" (one line in a glass pill) and "detailed" (a glass
// card). `details` "full" adds the condition and today's high and low;
// `showLocation` the place name. Every string is drawn as plain text and
// elides within the element, so a long condition or place can't push it
// off screen. Plain x, mirrored by hand, like the other elements.
Item {
  id: weather
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // This element's size: the view's scale for its screen (LockView sets it).
  required property real uiScale
  // The opacity of its glass surface (the look's, or its own `glass`).
  required property real glassOpacity
  readonly property color glassFill: view.glassAt(glassOpacity)
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "start"
  property string styleName: "compact"
  // "temperature" or "full".
  property string details: "temperature"
  property bool showLocation: false
  readonly property bool compact: styleName === "compact"
  readonly property bool pill: styleName === "pill"
  readonly property bool detailed: styleName === "detailed"
  readonly property var report: view.weather || null
  readonly property real unit: uiScale
  readonly property string temperatureText: report ? FoamyI18n.number(report.temperature) + "°" : ""
  readonly property string conditionText: report && details === "full" ? String(report.condition || "") : ""
  readonly property string rangeText: report && details === "full" && report.high !== null && report.low !== null
    ? FoamyI18n.t("High %1", [FoamyI18n.number(report.high) + "°"]) + "  " + FoamyI18n.t("Low %1", [FoamyI18n.number(report.low) + "°"])
    : ""
  readonly property string locationText: report && showLocation ? String(report.location || "") : ""
  // The widest it grows: the centre column at its scale.
  readonly property real maxWidth: view.contentWidthAt(uiScale)
  readonly property real padding: Math.round((pill ? 18 : detailed ? 20 : 0) * unit)
  readonly property real gap: Math.round(10 * unit)
  // "compact" and "detailed": the second line (condition, high and low).
  readonly property string detailText: [conditionText, rangeText].filter(function(part) { return part !== "" }).join("  ·  ")
  readonly property real headWidth: icon.width + gap + temperature.implicitWidth
  // The width it needs (and takes: the weather never fills the centre column).
  readonly property real naturalWidth: detailed ? Math.min(maxWidth, Math.round(300 * unit))
    : pill ? Math.min(maxWidth, line.implicitWidth + 2 * padding)
    : Math.min(maxWidth, Math.max(headWidth, detailLine.visible ? detailLine.implicitWidth : 0,
      placeLine.visible ? placeLine.implicitWidth : 0))
  readonly property real innerWidth: width - 2 * padding

  objectName: "weatherBlock"
  width: naturalWidth
  height: pill ? Math.round(44 * unit)
    : (placeLine.visible ? placeLine.y + placeLine.height : detailLine.visible ? detailLine.y + detailLine.height
      : head.y + head.height) + padding

  // Where a part of `partWidth` starts inside the element, on screen.
  function startX(partWidth) {
    var free = Math.max(0, innerWidth - partWidth)
    var start = alignment === "center" || pill ? free / 2 : alignment === "start" ? 0 : free
    return padding + (view.rightToLeft ? free - start : start)
  }

  // The lock's own line icons, one per condition group (Model.weatherGroup).
  function iconPath(group) {
    var cloud = "M7 18a4 4 0 0 1-.6-7.96A5.5 5.5 0 0 1 17 9.5a4.25 4.25 0 0 1 0 8.5Z"
    var high = "M7 14a4 4 0 0 1-.6-7.96A5.5 5.5 0 0 1 17 5.5a4.25 4.25 0 0 1 0 8.5Z"
    switch (group) {
    case "clear": return "M12 8a4 4 0 1 0 0 8 4 4 0 1 0 0-8Z M12 2v2 M12 20v2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M2 12h2 M20 12h2 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4"
    case "partly": return "M8 2.5v1.5 M3.2 4.2l1.1 1.1 M12.8 4.2l-1.1 1.1 M2 9h1.5 M4.6 11.6A3.5 3.5 0 1 1 11.4 7.6 M9 20a3.5 3.5 0 0 1-.5-6.96A5 5 0 0 1 18 12.5a3.75 3.75 0 0 1 0 7.5Z"
    case "fog": return "M5 7h14 M3 11h18 M5 15h14 M8 19h8"
    case "rain": return high + " M8 17l-1 3 M12 17l-1 3 M16 17l-1 3"
    case "sleet": return high + " M8 17l-1 3 M16 17l-1 3 M12 18.5h.01"
    case "snow": return high + " M8 17.5h.01 M12 19.5h.01 M16 17.5h.01 M10 21.5h.01 M14 21.5h.01"
    case "thunder": return high + " M13 15l-3 4h4l-3 4"
    }
    return cloud
  }

  // The glass behind the pill and the card.
  Rectangle {
    objectName: "weatherSurface"
    anchors.fill: parent
    visible: !weather.compact
    radius: weather.pill ? height / 2 : Math.round(22 * weather.unit)
    color: weather.glassFill
    border.width: 1
    border.color: weather.view.glassBorder
  }

  // "compact" and "detailed": the icon and the temperature.
  Item {
    id: head
    objectName: "weatherHead"
    visible: !weather.pill
    x: weather.startX(width)
    y: weather.padding
    width: Math.min(weather.headWidth, weather.innerWidth)
    height: Math.round((weather.detailed ? 52 : 40) * weather.unit)

    LineIcon {
      id: icon
      objectName: "weatherIcon"
      x: weather.view.rightToLeft ? head.width - width : 0
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round((weather.detailed ? 40 : 28) * weather.unit)
      height: width
      pathData: weather.iconPath(weather.report ? weather.view.weatherGroup(weather.report.code) : "")
      opacity: 0.9
    }

    Text {
      id: temperature
      objectName: "weatherTemperature"
      x: weather.view.rightToLeft ? 0 : icon.width + weather.gap
      width: Math.max(0, head.width - icon.width - weather.gap)
      height: head.height
      textFormat: Text.PlainText
      text: weather.temperatureText
      color: weather.view.foreground
      font.family: weather.view.displayFontFamily
      font.pixelSize: Math.round((weather.detailed ? 44 : 30) * weather.unit)
      font.weight: weather.detailed ? Font.Light : Font.Normal
      horizontalAlignment: Text.AlignLeft
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }

  Text {
    id: detailLine
    objectName: "weatherCondition"
    visible: !weather.pill && weather.detailText !== ""
    x: weather.padding
    y: head.y + head.height + Math.round(2 * weather.unit)
    width: weather.innerWidth
    textFormat: Text.PlainText
    text: weather.detailText
    color: weather.view.foreground
    opacity: 0.86
    font.family: weather.view.textFontFamily
    font.pixelSize: Math.round(15 * weather.unit)
    font.weight: Font.Medium
    horizontalAlignment: weather.alignment === "center" ? Text.AlignHCenter : weather.alignment === "end" ? Text.AlignRight : Text.AlignLeft
    elide: Text.ElideRight
  }

  Text {
    id: placeLine
    objectName: "weatherLocation"
    visible: !weather.pill && weather.locationText !== ""
    x: weather.padding
    y: (detailLine.visible ? detailLine.y + detailLine.height : head.y + head.height) + Math.round(2 * weather.unit)
    width: weather.innerWidth
    textFormat: Text.PlainText
    text: weather.locationText
    color: weather.view.foreground
    opacity: 0.72
    font.family: weather.view.textFontFamily
    font.pixelSize: Math.round(14 * weather.unit)
    horizontalAlignment: detailLine.horizontalAlignment
    elide: Text.ElideRight
  }

  // "pill": everything on one line, centred; the condition and the place
  // elide first when the line is too long.
  Row {
    id: line
    objectName: "weatherLine"
    visible: weather.pill
    readonly property real fixedWidth: pillIcon.width + pillTemperature.implicitWidth + pillRange.implicitWidth
      + (visibleChildren.length - 1) * spacing
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
