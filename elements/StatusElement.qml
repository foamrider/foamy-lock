pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// The status line. Styles: "text" (icons and labels), "icons", "pill" (the
// parts in one glass pill) and "system" (a glass panel, one row per reading).
// Without `items` each style shows what it always has: network and battery
// in a line, or uptime, memory, load and the battery (the network on a
// machine without one) in the panel. With `items` (Layout.STATUS_ITEMS, in
// their order) it shows those, in any style; an item whose source isn't
// available is left out, never shown as an error. The host view owns every
// data source (Networking, UPower, PipeWire, Bluetooth, the keyboard layout,
// /proc) and loads only the ones an item needs; this only draws them.
// A line wider than the centre column wraps onto more lines (a Flow: one
// line lays out exactly as a Row).
Flow {
  id: status
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
  readonly property real surfaceRadius: pill ? Math.min(height, lineHeight) / 2 : system ? Math.round(20 * uiScale) : -1
  // "text" (icons and labels), "icons" (icons only), "pill" or "system".
  property string styleName: "text"
  // The look's `items`, or null for the style's own contents.
  property var items: null
  readonly property bool pill: styleName === "pill"
  readonly property bool system: styleName === "system"
  // Each part's padding on either side; the pill packs them edge to edge.
  readonly property real partPadding: pill ? Math.round(11 * uiScale) : Math.round(24 * uiScale) / 2
  // The line's parts, in order (each drawn only while available).
  readonly property var lineItems: items ? items : ["network", "battery"]
  // The first part that shows: it holds the pill behind them all.
  readonly property int firstShown: {
    for (var i = 0; i < lineItems.length; i++)
      if (available(lineItems[i]))
        return i
    return -1
  }
  // Something to show: always without `items` (the network is always known).
  readonly property bool hasContent: system ? systemPanel.rows.length > 0 : firstShown !== -1
  // The widest a reading in a line may grow (a long layout name elides).
  readonly property real valueLimit: Math.round(220 * uiScale)
  readonly property real lineHeight: Math.round(38 * uiScale)
  // Everything on one line: the parts that show, side by side. Each part's
  // own `shown`, not `visible`, which is false in a hidden view (Lock
  // Studio measures and checks looks in views that are never drawn).
  readonly property real naturalWidth: {
    var total = 0
    var shown = 0
    for (var i = 0; i < children.length; i++) {
      var child = children[i]
      if (child["shown"] !== true || !(child.width > 0))
        continue
      total += child.width
      shown++
    }
    return total + Math.max(0, shown - 1) * spacing
  }

  objectName: "statusFooter"
  width: Math.min(naturalWidth, view.contentWidthAt(uiScale))
  height: system ? systemPanel.height : Math.max(lineHeight, implicitHeight)
  spacing: pill ? 0 : Math.round(10 * uiScale)

  // Whether `item`'s source has something to show.
  function available(item) {
    switch (item) {
    case "network":
      return true
    case "battery":
      return view.hasBattery === true
    case "volume":
      return view.hasVolume === true
    case "bluetooth":
      return view.hasBluetooth === true
    case "keyboard":
      return String(view.keyboardLayout || "") !== ""
    case "uptime":
      return view.systemUptime >= 0
    case "load":
      return loadParts(view.systemLoad).length === 3
    case "memory":
      return view.memoryTotal > 0
    }
    return false
  }

  function icon(item) {
    switch (item) {
    case "network":
      return view.networkIcon
    case "battery":
      return view.batteryIcon(view.batteryPercentage)
    case "volume":
      if (view.volumeMuted || view.volumePercent <= 0)
        return "\u{f075f}"
      return view.volumePercent < 34 ? "\u{f057f}" : view.volumePercent < 67 ? "\u{f0580}" : "\u{f057e}"
    case "bluetooth":
      return !view.bluetoothEnabled ? "\u{f00b2}" : view.bluetoothConnected > 0 ? "\u{f00b1}" : "\u{f00af}"
    case "keyboard":
      return "\u{f030c}"
    case "uptime":
      return "\u{f0150}"
    case "load":
      return "\u{f04c5}"
    case "memory":
      return "\u{f035b}"
    }
    return ""
  }

  // The row label in the system panel.
  function label(item) {
    switch (item) {
    case "network":
      return FoamyI18n.t("Network")
    case "battery":
      return FoamyI18n.t("Battery")
    case "volume":
      return FoamyI18n.t("Volume")
    case "bluetooth":
      return FoamyI18n.t("Bluetooth")
    case "keyboard":
      return FoamyI18n.t("Keyboard")
    case "uptime":
      return FoamyI18n.t("Uptime")
    case "load":
      return FoamyI18n.t("Load")
    case "memory":
      return FoamyI18n.t("Memory")
    }
    return ""
  }

  // The reading in full: the "text" style and the panel.
  function value(item) {
    switch (item) {
    case "network":
      return FoamyI18n.t(view.networkLabel)
    case "battery":
      return FoamyI18n.number(view.batteryPercentage) + "%"
    case "volume":
      return view.volumeMuted ? FoamyI18n.t("Muted") : FoamyI18n.number(view.volumePercent) + "%"
    case "bluetooth":
      if (!view.bluetoothEnabled)
        return FoamyI18n.t("Off")
      return view.bluetoothConnected > 0 ? FoamyI18n.t("%1 connected", [FoamyI18n.number(view.bluetoothConnected)]) : FoamyI18n.t("On")
    case "keyboard":
      return String(view.keyboardLayout || "")
    case "uptime":
      return uptimeText(view.systemUptime)
    case "load":
      return system ? loadText(view.systemLoad) : FoamyI18n.number(Number(loadParts(view.systemLoad)[0]), 2)
    case "memory":
      return memoryText()
    }
    return ""
  }

  // The reading beside the icon in a line: in full for "text"; short, or
  // none where the icon says it, for "pill" and "icons".
  function lineValue(item) {
    if (styleName === "text")
      return value(item)
    switch (item) {
    case "network":
      return ""
    case "battery":
      return pill ? value(item) : ""
    case "volume":
      return pill && !view.volumeMuted ? value(item) : ""
    case "bluetooth":
      return pill && view.bluetoothConnected > 0 ? FoamyI18n.number(view.bluetoothConnected) : ""
    case "keyboard":
      return keyboardShort(view.keyboardLayout)
    case "memory":
      return FoamyI18n.number(Math.round(memoryPart() * 100)) + "%"
    }
    return value(item)
  }

  // The bar under a panel row (-1: none).
  function part(item) {
    switch (item) {
    case "battery":
      return view.batteryPercentage / 100
    case "volume":
      return view.volumeMuted ? 0 : Math.min(1, view.volumePercent / 100)
    case "memory":
      return memoryPart()
    }
    return -1
  }

  function memoryUsed() {
    return view.memoryTotal > 0 ? view.memoryTotal - view.memoryAvailable : 0
  }

  function memoryPart() {
    return view.memoryTotal > 0 ? memoryUsed() / view.memoryTotal : -1
  }

  function memoryText() {
    if (!(view.memoryTotal > 0))
      return "—"
    return FoamyI18n.t("%1 / %2 GB", [FoamyI18n.number(memoryUsed() / 1048576, 1), FoamyI18n.number(view.memoryTotal / 1048576, 1)])
  }

  // The layout's first word, at most three letters ("English (US)": ENG).
  function keyboardShort(name) {
    return String(name || "").split(/\s+/)[0].substring(0, 3).toLocaleUpperCase()
  }

  Repeater {
    model: status.lineItems

    Item {
      id: lineItem
      required property string modelData
      required property int index
      objectName: modelData + "Status"
      readonly property bool shown: !status.system && status.available(modelData)
      visible: shown
      width: lineContent.implicitWidth + 2 * status.partPadding
      height: status.lineHeight

      // The pill behind every part. It lives in the first part that shows,
      // so the Row doesn't place it, and spans the whole status from there.
      Rectangle {
        objectName: "statusPill"
        visible: status.pill && lineItem.index === status.firstShown && status.surfaceShown
        x: status.view.rightToLeft ? lineItem.width - status.width : 0
        width: status.width
        height: status.height
        radius: Math.min(height, status.lineHeight) / 2
        color: status.glassFill
        border.width: 1
        border.color: status.view.glassBorder
      }

      Row {
        id: lineContent
        anchors.centerIn: parent
        spacing: Math.round((lineItem.modelData === "network" ? 8 : 7) * status.uiScale)

        Text {
          textFormat: Text.PlainText
          height: status.lineHeight
          anchors.verticalCenter: parent.verticalCenter
          text: status.icon(lineItem.modelData)
          color: status.view.foreground
          opacity: 0.76
          font.family: status.view.iconFontFamily
          font.pixelSize: Math.round(18 * status.uiScale)
          font.weight: Font.Light
          verticalAlignment: Text.AlignVCenter
        }

        Text {
          textFormat: Text.PlainText
          height: status.lineHeight
          width: Math.min(implicitWidth, status.valueLimit)
          text: status.lineValue(lineItem.modelData)
          visible: text !== ""
          color: status.view.foreground
          opacity: 0.88
          font.family: status.view.textFontFamily
          font.pixelSize: Math.round(15 * status.uiScale)
          font.weight: Font.Normal
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }
      }
    }
  }

  // "system": one row per reading, a bar under the memory, the battery and
  // the volume. Without `items`, a fixed size: four rows whatever is known.
  Rectangle {
    id: systemPanel
    objectName: "systemPanel"
    readonly property real unit: status.uiScale
    readonly property real padding: Math.round(22 * unit)
    readonly property real rowHeight: Math.round(46 * unit)
    readonly property real rowGap: Math.round(12 * unit)
    readonly property var rows: {
      if (status.items) {
        var out = []
        for (var i = 0; i < status.items.length; i++) {
          var item = status.items[i]
          if (status.available(item))
            out.push({
              icon: status.icon(item),
              label: status.label(item),
              value: status.value(item),
              part: status.part(item)
            })
        }
        return out
      }
      return [
        {
          icon: "\u{f0150}",
          label: FoamyI18n.t("Uptime"),
          value: status.uptimeText(status.view.systemUptime),
          part: -1
        },
        {
          icon: "\u{f035b}",
          label: FoamyI18n.t("Memory"),
          value: status.memoryText(),
          part: status.memoryPart()
        },
        {
          icon: "\u{f04c5}",
          label: FoamyI18n.t("Load"),
          value: status.loadText(status.view.systemLoad),
          part: -1
        },
        status.view.hasBattery ? {
          icon: status.view.batteryIcon(status.view.batteryPercentage),
          label: FoamyI18n.t("Battery"),
          value: FoamyI18n.number(status.view.batteryPercentage) + "%",
          part: status.view.batteryPercentage / 100
        } : {
          icon: status.view.networkIcon,
          label: FoamyI18n.t("Network"),
          value: FoamyI18n.t(status.view.networkLabel),
          part: -1
        }]
    }

    readonly property bool shown: status.system && rows.length > 0
    visible: shown
    width: Math.round(320 * unit)
    height: rows.length > 0 ? 2 * padding + rows.length * rowHeight + (rows.length - 1) * rowGap : 0
    radius: Math.round(20 * unit)
    color: status.surfaceShown ? status.glassFill : "transparent"
    border.width: status.surfaceShown ? 1 : 0
    border.color: status.view.glassBorder

    Repeater {
      model: systemPanel.rows

      Item {
        id: reading
        required property var modelData
        required property int index
        // The icon column, then a gap: the widest icons (Wi-Fi, wired: 22 px
        // of ink at 19 px) fill most of the column.
        readonly property real iconWidth: Math.round(30 * systemPanel.unit)
        readonly property real labelStart: iconWidth + Math.round(6 * systemPanel.unit)
        readonly property real gap: Math.round(10 * systemPanel.unit)
        x: systemPanel.padding
        y: systemPanel.padding + index * (systemPanel.rowHeight + systemPanel.rowGap)
        width: systemPanel.width - 2 * systemPanel.padding
        height: systemPanel.rowHeight

        // Plain x, mirrored by hand: the icon at the start, the label after
        // it, the value at the end. The alignments are logical (they mirror
        // with the view).
        GlyphIcon {
          x: status.view.rightToLeft ? reading.width - width : 0
          width: reading.iconWidth
          height: Math.round(26 * systemPanel.unit)
          text: reading.modelData.icon
          color: status.view.foreground
          opacity: 0.76
          font.family: status.view.iconFontFamily
          font.pixelSize: Math.round(19 * systemPanel.unit)
        }

        Text {
          id: rowLabel
          x: status.view.rightToLeft ? reading.width - reading.labelStart - width : reading.labelStart
          width: Math.min(implicitWidth, (reading.width - reading.labelStart) / 2)
          height: Math.round(26 * systemPanel.unit)
          textFormat: Text.PlainText
          text: reading.modelData.label
          color: status.view.foreground
          opacity: 0.72
          font.family: status.view.textFontFamily
          font.pixelSize: Math.round(14 * systemPanel.unit)
          font.weight: Font.Medium
          font.letterSpacing: Math.round(1 * systemPanel.unit)
          horizontalAlignment: Text.AlignLeft
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }

        // The value takes the space after the label and elides there (a
        // long keyboard layout name).
        Text {
          x: status.view.rightToLeft ? 0 : reading.width - width
          width: Math.max(0, reading.width - reading.labelStart - rowLabel.width - reading.gap)
          height: Math.round(26 * systemPanel.unit)
          textFormat: Text.PlainText
          text: reading.modelData.value
          color: status.view.foreground
          font.family: status.view.textFontFamily
          font.pixelSize: Math.round(15 * systemPanel.unit)
          font.weight: Font.DemiBold
          horizontalAlignment: Text.AlignRight
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }

        Rectangle {
          visible: reading.modelData.part >= 0
          x: status.view.rightToLeft ? 0 : reading.labelStart
          y: reading.height - height - Math.round(4 * systemPanel.unit)
          width: reading.width - reading.labelStart
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
    if (!(seconds >= 0))
      return "—"
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor(seconds % 86400 / 3600)
    var minutes = Math.floor(seconds % 3600 / 60)
    if (days > 0)
      return FoamyI18n.t("%1 d %2 h", [days, hours])
    if (hours > 0)
      return FoamyI18n.t("%1 h %2 min", [hours, minutes])
    return FoamyI18n.t("%1 min", [minutes])
  }

  // The three load averages, or [] until they are known.
  function loadParts(load) {
    var parts = String(load || "").trim().split(/\s+/).slice(0, 3)
    return parts.length < 3 || parts.some(function (part) {
      return !isFinite(Number(part))
    }) ? [] : parts
  }

  // The 1, 5 and 15 minute load averages in the locale's numbers.
  function loadText(load) {
    var parts = loadParts(load)
    if (parts.length < 3)
      return "—"
    return parts.map(function (part) {
      return FoamyI18n.number(Number(part), 2)
    }).join("  ")
  }
}
