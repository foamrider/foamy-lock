import QtQuick
import QtQuick.Effects

// Avatar and display name. The host sets the width.
Item {
  id: account
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view

  objectName: "identityBlock"
  visible: view.showUserInfo
  height: avatar.height + nameLabel.anchors.topMargin + nameLabel.height

  Rectangle {
    id: avatar
    objectName: "avatar"
    width: Math.round(84 * account.view.uiScale)
    height: width
    radius: width / 2
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
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
      font.pixelSize: Math.round(34 * account.view.uiScale)
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
    anchors.top: avatar.bottom
    anchors.topMargin: Math.round(7 * account.view.uiScale)
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.round(34 * account.view.uiScale)
    text: account.view.displayName
    color: account.view.foreground
    font.family: account.view.textFontFamily
    font.pixelSize: Math.round(20 * account.view.uiScale)
    font.weight: Font.Normal
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
