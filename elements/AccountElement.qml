import QtQuick
import QtQuick.Effects

// Avatar and display name. Styles: "avatar" (a large picture with the name
// below; the host sets the width) and "chip" (a small picture and the name
// in a glass pill, as wide as it needs).
Item {
  id: account
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "avatar"
  readonly property bool chip: styleName === "chip"
  readonly property real chipPadding: Math.round(7 * view.uiScale)
  readonly property real chipGap: Math.round(10 * view.uiScale)
  // The width it needs outside the center column (and the chip's width).
  readonly property real naturalWidth: chip
    ? chipPadding + avatar.width + chipGap + nameLabel.implicitWidth + Math.round(18 * view.uiScale)
    : Math.max(avatar.width, nameLabel.implicitWidth)

  objectName: "identityBlock"
  height: chip ? Math.round(48 * view.uiScale) : avatar.height + nameLabel.anchors.topMargin + nameLabel.height

  Rectangle {
    objectName: "accountChip"
    anchors.fill: parent
    visible: account.chip
    radius: height / 2
    color: account.view.glass
    border.width: 1
    border.color: account.view.glassBorder
  }

  Rectangle {
    id: avatar
    objectName: "avatar"
    width: Math.round((account.chip ? 34 : 84) * account.view.uiScale)
    height: width
    radius: width / 2
    anchors.top: account.chip ? undefined : parent.top
    anchors.verticalCenter: account.chip ? parent.verticalCenter : undefined
    anchors.horizontalCenter: !account.chip && account.alignment === "center" ? parent.horizontalCenter : undefined
    anchors.left: account.chip || account.alignment === "start" ? parent.left : undefined
    anchors.leftMargin: account.chip ? account.chipPadding : 0
    anchors.right: !account.chip && account.alignment === "end" ? parent.right : undefined
    color: Qt.rgba(0.025, 0.03, 0.055, 0.55)

    Item {
      id: avatarMask
      anchors.fill: parent
      visible: false
      layer.enabled: true

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "white"
      }
    }

    Image {
      id: avatarImage
      anchors.fill: parent
      source: account.view.avatarPath ? account.view.fileUrl(account.view.avatarPath, account.view.avatarVersion) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      smooth: true
      // The service provides a Lanczos-filtered runtime thumbnail so Qt
      // only performs the small final scale to the physical output.
      sourceSize.width: 256
      sourceSize.height: 256
      visible: false
    }

    MultiEffect {
      anchors.fill: parent
      source: avatarImage
      visible: avatarImage.status === Image.Ready
      maskEnabled: true
      maskSource: avatarMask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.05
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: avatarImage.status !== Image.Ready
      text: account.view.displayName.length > 0 ? account.view.displayName.charAt(0).toLocaleUpperCase() : "?"
      color: account.view.foreground
      font.family: account.view.textFontFamily
      font.pixelSize: Math.round((account.chip ? 15 : 34) * account.view.uiScale)
      font.weight: Font.Light
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.22)
    }
  }

  Text {
    id: nameLabel
    objectName: "nameLabel"
    textFormat: Text.PlainText
    anchors.top: account.chip ? undefined : avatar.bottom
    anchors.topMargin: Math.round(7 * account.view.uiScale)
    anchors.verticalCenter: account.chip ? parent.verticalCenter : undefined
    anchors.left: account.chip ? avatar.right : parent.left
    anchors.leftMargin: account.chip ? account.chipGap : 0
    anchors.right: parent.right
    anchors.rightMargin: account.chip ? Math.round(18 * account.view.uiScale) : 0
    height: Math.round((account.chip ? 24 : 34) * account.view.uiScale)
    text: account.view.displayName
    color: account.view.foreground
    font.family: account.view.textFontFamily
    font.pixelSize: Math.round((account.chip ? 16 : 20) * account.view.uiScale)
    font.weight: Font.Normal
    elide: Text.ElideRight
    horizontalAlignment: account.chip || account.alignment === "start" ? Text.AlignLeft
      : account.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
