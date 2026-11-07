import QtQuick
import "../kit"

// Network and battery status. The host view owns the data sources
// (Networking, UPower); this only draws them.
Row {
  id: status
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view

  objectName: "statusFooter"
  height: Math.round(38 * view.uiScale)
  spacing: Math.round(10 * view.uiScale)

  Item {
    id: networkPill
    objectName: "networkStatus"
    width: networkStatusContent.implicitWidth + Math.round(24 * status.view.uiScale)
    height: parent.height

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
    width: batteryStatusContent.implicitWidth + Math.round(24 * status.view.uiScale)
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
