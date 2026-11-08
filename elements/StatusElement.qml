import QtQuick
import "../kit"

// Network and battery status. Styles: "text" (icons and labels), "icons",
// "pill" (both icons and the battery percentage in one glass pill) and
// "system" (a glass panel with uptime, memory, load and the battery, or the
// network without one). The host view owns the data sources (Networking,
// UPower, /proc while the panel shows); this only draws them.
Row {
  id: status
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // This element's size: the view's scale for its screen (LockView sets it).
  required property real uiScale
  // The opacity of its glass surface (the look's, or its own `glass`).
  required property real glassOpacity
  readonly property color glassFill: view.glassAt(glassOpacity)
  // "text" (icons and labels), "icons" (icons only), "pill" or "system".
  property string styleName: "text"
  readonly property bool pill: styleName === "pill"
  readonly property bool system: styleName === "system"
  // Each part's padding on either side; the pill packs them edge to edge.
  readonly property real partPadding: pill ? Math.round(11 * uiScale) : Math.round(24 * uiScale) / 2

  objectName: "statusFooter"
  height: system ? systemPanel.height : Math.round(38 * uiScale)
  spacing: pill ? 0 : Math.round(10 * uiScale)

  Item {
    id: networkPill
    objectName: "networkStatus"
    visible: !status.system
    width: networkStatusContent.implicitWidth + 2 * status.partPadding
    height: parent.height

    // The pill behind both parts. It lives in the first part so the Row
    // doesn't place it; it spans the whole status from the Row's start.
    Rectangle {
      objectName: "statusPill"
      visible: status.pill
      x: status.view.rightToLeft ? networkPill.width - status.width : 0
      width: status.width
      height: status.height
      radius: height / 2
      color: status.glassFill
      border.width: 1
      border.color: status.view.glassBorder
    }

    Row {
      id: networkStatusContent
      anchors.centerIn: parent
      spacing: Math.round(8 * status.uiScale)

      Text {
        textFormat: Text.PlainText
        height: status.height
        anchors.verticalCenter: parent.verticalCenter
        text: status.view.networkIcon
        color: status.view.foreground
        opacity: 0.76
        font.family: status.view.iconFontFamily
        font.pixelSize: Math.round(18 * status.uiScale)
        font.weight: Font.Light
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        height: status.height
        text: FoamyI18n.t(status.view.networkLabel)
        visible: status.styleName === "text"
        color: status.view.foreground
        opacity: 0.88
        font.family: status.view.textFontFamily
        font.pixelSize: Math.round(15 * status.uiScale)
        font.weight: Font.Normal
        verticalAlignment: Text.AlignVCenter
      }
    }
  }

  Item {
    id: batteryPill
    objectName: "batteryStatus"
    width: batteryStatusContent.implicitWidth + 2 * status.partPadding
    height: parent.height
    visible: status.view.hasBattery && !status.system

    Row {
      id: batteryStatusContent
      anchors.centerIn: parent
      spacing: Math.round(7 * status.uiScale)

      Text {
        textFormat: Text.PlainText
        height: status.height
        anchors.verticalCenter: parent.verticalCenter
        text: status.view.batteryIcon(status.view.batteryPercentage)
        color: status.view.foreground
        opacity: 0.76
        font.family: status.view.iconFontFamily
        font.pixelSize: Math.round(18 * status.uiScale)
        font.weight: Font.Light
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        height: status.height
        text: FoamyI18n.number(status.view.batteryPercentage) + "%"
        visible: status.styleName !== "icons"
        color: status.view.foreground
        opacity: 0.88
        font.family: status.view.textFontFamily
        font.pixelSize: Math.round(15 * status.uiScale)
        font.weight: Font.Normal
        verticalAlignment: Text.AlignVCenter
      }
    }
  }

  // "system": one row per reading, a bar under the memory and the battery.
  // A fixed size: four rows whatever is known.
  Rectangle {
    id: systemPanel
    objectName: "systemPanel"
    readonly property real unit: status.uiScale
    readonly property real padding: Math.round(22 * unit)
    readonly property real rowHeight: Math.round(46 * unit)
    readonly property real rowGap: Math.round(12 * unit)
    readonly property real memoryUsed: status.view.memoryTotal > 0 ? status.view.memoryTotal - status.view.memoryAvailable : 0
    readonly property var rows: [
      { icon: "\u{f0150}", label: FoamyI18n.t("Uptime"), value: status.uptimeText(status.view.systemUptime), part: -1 },
      { icon: "\u{f035b}", label: FoamyI18n.t("Memory"),
        value: status.view.memoryTotal > 0 ? FoamyI18n.t("%1 / %2 GB", [FoamyI18n.number(memoryUsed / 1048576, 1),
          FoamyI18n.number(status.view.memoryTotal / 1048576, 1)]) : "\u2014",
        part: status.view.memoryTotal > 0 ? memoryUsed / status.view.memoryTotal : -1 },
      { icon: "\u{f04c5}", label: FoamyI18n.t("Load"), value: status.loadText(status.view.systemLoad), part: -1 },
      status.view.hasBattery
        ? { icon: status.view.batteryIcon(status.view.batteryPercentage), label: FoamyI18n.t("Battery"),
          value: FoamyI18n.number(status.view.batteryPercentage) + "%", part: status.view.batteryPercentage / 100 }
        : { icon: status.view.networkIcon, label: FoamyI18n.t("Network"), value: FoamyI18n.t(status.view.networkLabel), part: -1 }
    ]

    visible: status.system
    width: Math.round(320 * unit)
    height: 2 * padding + rows.length * rowHeight + (rows.length - 1) * rowGap
    radius: Math.round(20 * unit)
    color: status.glassFill
    border.width: 1
    border.color: status.view.glassBorder

    Repeater {
      model: systemPanel.rows

      Item {
        id: reading
        required property var modelData
        required property int index
        readonly property real iconWidth: Math.round(30 * systemPanel.unit)
        x: systemPanel.padding
        y: systemPanel.padding + index * (systemPanel.rowHeight + systemPanel.rowGap)
        width: systemPanel.width - 2 * systemPanel.padding
        height: systemPanel.rowHeight

        // Plain x, mirrored by hand: the icon at the start, the value at the end.
        Text {
          x: status.view.rightToLeft ? reading.width - width : 0
          width: reading.iconWidth
          height: Math.round(26 * systemPanel.unit)
          textFormat: Text.PlainText
          text: reading.modelData.icon
          color: status.view.foreground
          opacity: 0.76
          font.family: status.view.iconFontFamily
          font.pixelSize: Math.round(19 * systemPanel.unit)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Text {
          x: status.view.rightToLeft ? 0 : reading.iconWidth
          width: reading.width - reading.iconWidth
          height: Math.round(26 * systemPanel.unit)
          textFormat: Text.PlainText
          text: reading.modelData.label
          color: status.view.foreground
          opacity: 0.72
          font.family: status.view.textFontFamily
          font.pixelSize: Math.round(14 * systemPanel.unit)
          font.weight: Font.Medium
          font.letterSpacing: Math.round(1 * systemPanel.unit)
          horizontalAlignment: status.view.rightToLeft ? Text.AlignRight : Text.AlignLeft
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }

        Text {
          x: status.view.rightToLeft ? 0 : reading.iconWidth
          width: reading.width - reading.iconWidth
          height: Math.round(26 * systemPanel.unit)
          textFormat: Text.PlainText
          text: reading.modelData.value
          color: status.view.foreground
          font.family: status.view.textFontFamily
          font.pixelSize: Math.round(15 * systemPanel.unit)
          font.weight: Font.DemiBold
          horizontalAlignment: status.view.rightToLeft ? Text.AlignLeft : Text.AlignRight
          verticalAlignment: Text.AlignVCenter
        }

        Rectangle {
          visible: reading.modelData.part >= 0
          x: status.view.rightToLeft ? 0 : reading.iconWidth
          y: reading.height - height - Math.round(4 * systemPanel.unit)
          width: reading.width - reading.iconWidth
          height: Math.max(2, Math.round(4 * systemPanel.unit))
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.12)

          Rectangle {
            x: status.view.rightToLeft ? parent.width - width : 0
            width: Math.round(parent.width * Math.max(0, Math.min(1, reading.modelData.part)))
            height: parent.height
            radius: height / 2
            color: status.view.accent
          }
        }
      }
    }
  }

  // "3 d 4 h", "4 h 12 min", "12 min"; a dash until known.
  function uptimeText(seconds) {
    if (!(seconds >= 0)) return "\u2014"
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor(seconds % 86400 / 3600)
    var minutes = Math.floor(seconds % 3600 / 60)
    if (days > 0) return FoamyI18n.t("%1 d %2 h", [days, hours])
    if (hours > 0) return FoamyI18n.t("%1 h %2 min", [hours, minutes])
    return FoamyI18n.t("%1 min", [minutes])
  }

  // The 1, 5 and 15 minute load averages in the locale's numbers.
  function loadText(load) {
    var parts = String(load || "").trim().split(/\s+/).slice(0, 3)
    if (parts.length < 3 || parts.some(function(part) { return !isFinite(Number(part)) })) return "\u2014"
    return parts.map(function(part) { return FoamyI18n.number(Number(part), 2) }).join("  ")
  }
}
