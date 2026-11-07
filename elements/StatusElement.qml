import QtQuick
import "../kit"

// Network and battery status. Styles: "text" (icons and labels), "icons" and
// "pill" (both icons and the battery percentage in one glass pill). The host
// view owns the data sources (Networking, UPower); this only draws them.
Row {
  id: status
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "text" (icons and labels), "icons" (icons only) or "pill".
  property string styleName: "text"
  readonly property bool pill: styleName === "pill"
  // Each part's padding on either side; the pill packs them edge to edge.
  readonly property real partPadding: pill ? Math.round(11 * view.uiScale) : Math.round(24 * view.uiScale) / 2

  objectName: "statusFooter"
  height: Math.round(38 * view.uiScale)
  spacing: pill ? 0 : Math.round(10 * view.uiScale)

  Item {
    id: networkPill
    objectName: "networkStatus"
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
      color: status.view.glass
      border.width: 1
      border.color: status.view.glassBorder
    }

    Row {
      id: networkStatusContent
      anchors.centerIn: parent
      spacing: Math.round(8 * status.view.uiScale)

      Text {
        textFormat: Text.PlainText
        height: status.height
        anchors.verticalCenter: parent.verticalCenter
        text: status.view.networkIcon
        color: status.view.foreground
        opacity: 0.76
        font.family: status.view.iconFontFamily
        font.pixelSize: Math.round(18 * status.view.uiScale)
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
        font.pixelSize: Math.round(15 * status.view.uiScale)
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
    visible: status.view.hasBattery

    Row {
      id: batteryStatusContent
      anchors.centerIn: parent
      spacing: Math.round(7 * status.view.uiScale)

      Text {
        textFormat: Text.PlainText
        height: status.height
        anchors.verticalCenter: parent.verticalCenter
        text: status.view.batteryIcon(status.view.batteryPercentage)
        color: status.view.foreground
        opacity: 0.76
        font.family: status.view.iconFontFamily
        font.pixelSize: Math.round(18 * status.view.uiScale)
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
        font.pixelSize: Math.round(15 * status.view.uiScale)
        font.weight: Font.Normal
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
