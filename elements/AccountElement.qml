import QtQuick
import QtQuick.Effects
import "../kit"

// Avatar and display name. Styles: "avatar" (a large picture with the name
// below; the host sets the width), "chip" (a small picture and the name in a
// glass pill, as wide as it needs), "name" (the display name alone) and
// "greeting" (a greeting for the time of day with the first name, "Good
// evening, Ada", in the display face; the greeting alone without a name).
Item {
  id: account
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
  readonly property real surfaceRadius: chip ? height / 2 : -1
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  property string styleName: "avatar"
  readonly property bool chip: styleName === "chip"
  readonly property bool nameOnly: styleName === "name"
  readonly property bool greeting: styleName === "greeting"
  // The styles that are one line of text, without the picture.
  readonly property bool textOnly: nameOnly || greeting
  // The first word of the display name (a greeting is on first-name terms).
  readonly property string firstName: view.displayName.split(/\s+/)[0] || ""
  readonly property int hour: view.now.getHours()
  // Morning from 5, afternoon from 12, evening from 18.
  readonly property string greetingText: {
    var name = firstName
    if (hour >= 5 && hour < 12)
      return name ? FoamyI18n.t("Good morning, %1", [name]) : FoamyI18n.t("Good morning")
    if (hour >= 12 && hour < 18)
      return name ? FoamyI18n.t("Good afternoon, %1", [name]) : FoamyI18n.t("Good afternoon")
    return name ? FoamyI18n.t("Good evening, %1", [name]) : FoamyI18n.t("Good evening")
  }
  readonly property real chipPadding: Math.round(7 * uiScale)
  readonly property real chipGap: Math.round(10 * uiScale)
  readonly property real chipEnd: Math.round(18 * uiScale)
  // Positions are plain x/y bindings, mirrored here: switching anchors on and
  // off between styles at runtime leaves stale anchors behind.
  readonly property bool mirrored: view.rightToLeft
  // The width it needs outside the center column (and the chip's width).
  readonly property real naturalWidth: chip ? chipPadding + avatar.width + chipGap + nameLabel.implicitWidth + chipEnd : textOnly ? nameLabel.implicitWidth : Math.max(avatar.width, nameLabel.implicitWidth)

  objectName: "identityBlock"
  height: chip ? Math.round(48 * uiScale) : textOnly ? nameLabel.height : avatar.height + nameLabel.topMargin + nameLabel.height

  Rectangle {
    objectName: "accountChip"
    anchors.fill: parent
    visible: account.chip && account.surfaceShown
    radius: height / 2
    color: account.glassFill
    border.width: 1
    border.color: account.view.glassBorder
  }

  Rectangle {
    id: avatar
    objectName: "avatar"
    visible: !account.textOnly
    width: Math.round((account.chip ? 34 : 84) * account.uiScale)
    height: width
    radius: width / 2
    y: account.chip ? (account.height - height) / 2 : 0
    x: {
      if (account.chip)
        return account.mirrored ? account.width - account.chipPadding - width : account.chipPadding
      if (account.alignment === "center")
        return (account.width - width) / 2
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
      font.pixelSize: Math.round((account.chip ? 15 : 34) * account.uiScale)
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
    readonly property real topMargin: Math.round(7 * account.uiScale)
    height: Math.round((account.chip ? 24 : account.nameOnly ? 36 : account.greeting ? 44 : 34) * account.uiScale)
    y: account.chip ? (account.height - height) / 2 : account.textOnly ? 0 : avatar.height + topMargin
    width: account.chip ? Math.max(0, account.width - account.chipPadding - avatar.width - account.chipGap - account.chipEnd) : account.width
    x: !account.chip ? 0 : account.mirrored ? account.chipEnd : account.chipPadding + avatar.width + account.chipGap
    text: account.greeting ? account.greetingText : account.view.displayName
    color: account.view.foreground
    font.family: account.greeting ? account.view.displayFontFamily : account.view.textFontFamily
    font.pixelSize: Math.round((account.chip ? 16 : account.nameOnly ? 24 : account.greeting ? 32 : 20) * account.uiScale)
    font.weight: account.nameOnly ? Font.Medium : Font.Normal
    elide: Text.ElideRight
    horizontalAlignment: account.chip || account.alignment === "start" ? Text.AlignLeft : account.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
