import QtQuick
import QtQuick.Effects

// Avatar and display name. Styles: "avatar" (a large picture with the name
// below; the host sets the width), "chip" (a small picture and the name in a
// glass pill, as wide as it needs) and "name" (the display name alone).
Item {
  id: account
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "avatar"
  readonly property bool chip: styleName === "chip"
  readonly property bool nameOnly: styleName === "name"
  readonly property real chipPadding: Math.round(7 * view.uiScale)
  readonly property real chipGap: Math.round(10 * view.uiScale)
  readonly property real chipEnd: Math.round(18 * view.uiScale)
  // Positions are plain x/y bindings, mirrored here: switching anchors on and
  // off between styles at runtime leaves stale anchors behind.
  readonly property bool mirrored: view.rightToLeft
  // The width it needs outside the center column (and the chip's width).
  readonly property real naturalWidth: chip
    ? chipPadding + avatar.width + chipGap + nameLabel.implicitWidth + chipEnd
    : nameOnly ? nameLabel.implicitWidth : Math.max(avatar.width, nameLabel.implicitWidth)

  objectName: "identityBlock"
  height: chip ? Math.round(48 * view.uiScale) : nameOnly ? nameLabel.height
    : avatar.height + nameLabel.topMargin + nameLabel.height

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
    visible: !account.nameOnly
    width: Math.round((account.chip ? 34 : 84) * account.view.uiScale)
    height: width
    radius: width / 2
    y: account.chip ? (account.height - height) / 2 : 0
    x: {
      if (account.chip) return account.mirrored ? account.width - account.chipPadding - width : account.chipPadding
      if (account.alignment === "center") return (account.width - width) / 2
      var atStart = account.alignment === "start"
      return atStart !== account.mirrored ? 0 : account.width - width
    }
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
    readonly property real topMargin: Math.round(7 * account.view.uiScale)
    height: Math.round((account.chip ? 24 : account.nameOnly ? 36 : 34) * account.view.uiScale)
    y: account.chip ? (account.height - height) / 2 : account.nameOnly ? 0 : avatar.height + topMargin
    width: account.chip ? Math.max(0, account.width - account.chipPadding - avatar.width - account.chipGap - account.chipEnd) : account.width
    x: !account.chip ? 0 : account.mirrored ? account.chipEnd : account.chipPadding + avatar.width + account.chipGap
    text: account.view.displayName
    color: account.view.foreground
    font.family: account.view.textFontFamily
    font.pixelSize: Math.round((account.chip ? 16 : account.nameOnly ? 24 : 20) * account.view.uiScale)
    font.weight: account.nameOnly ? Font.Medium : Font.Normal
    elide: Text.ElideRight
    horizontalAlignment: account.chip || account.alignment === "start" ? Text.AlignLeft
      : account.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
