import QtQuick
import QtQuick.Effects

// Now playing. Styles: "card" (artwork thumbnail, title, artist and
// transport controls on glass) and "line" (title and artist on one line).
// Only the service's sandboxed thumbnail reaches this view.
Rectangle {
  id: media
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  property string styleName: "card"
  readonly property bool line: styleName === "line"

  objectName: "mediaRow"
  width: line
    ? Math.min(mediaLine.implicitWidth, view.contentWidth)
    : Math.min(Math.round(470 * view.uiScale), view.width - 48 * view.uiScale)
  height: Math.round((line ? 30 : 92) * view.uiScale)
  radius: Math.round(22 * view.uiScale)
  color: line ? "transparent" : view.glass
  border.width: line ? 0 : 1
  border.color: view.glassBorder

  Row {
    id: mediaLine
    objectName: "mediaLine"
    visible: media.line
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Math.round(8 * media.view.uiScale)

    LineIcon {
      id: lineIcon
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round(18 * media.view.uiScale)
      height: width
      pathData: "M9 18V5l12-2v13 M9 18a3 3 0 1 1-3-3 3 3 0 0 1 3 3Z M21 16a3 3 0 1 1-3-3 3 3 0 0 1 3 3Z"
      opacity: 0.8
    }

    Text {
      objectName: "mediaLineText"
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, media.view.contentWidth - lineIcon.width - parent.spacing)
      textFormat: Text.PlainText
      text: {
        var player = media.view.activePlayer
        if (!player) return ""
        var title = String(player.trackTitle || "")
        var artist = String(player.trackArtist || "")
        return title && artist ? title + " · " + artist : title || artist
      }
      color: media.view.foreground
      opacity: 0.88
      font.family: media.view.textFontFamily
      font.pixelSize: Math.round(15 * media.view.uiScale)
      elide: Text.ElideRight
    }
  }

  Rectangle {
    id: albumArt
    objectName: "albumArt"
    visible: !media.line
    width: Math.round(64 * media.view.uiScale)
    height: width
    radius: Math.round(9 * media.view.uiScale)
    anchors.left: parent.left
    anchors.leftMargin: Math.round(14 * media.view.uiScale)
    anchors.verticalCenter: parent.verticalCenter
    color: Qt.rgba(0.025, 0.035, 0.065, 0.55)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.12)
    clip: true

    Image {
      id: artworkImage
      objectName: "artworkImage"
      anchors.fill: parent
      anchors.margins: albumArt.border.width
      // Rectangle.clip is rectangular; mask artwork to the inside of its border.
      layer.enabled: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: artworkMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
      // Only the isolated helper's fixed-size thumbnail reaches Qt.
      source: media.view.artworkPath ? media.view.fileUrl(media.view.artworkPath, 0) : ""
      sourceSize.width: 256
      sourceSize.height: 256
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      visible: status === Image.Ready
      onStatusChanged: if (status === Image.Error) media.view.artworkFailed(media.view.artworkPath)
    }

    Rectangle {
      id: artworkMask
      width: artworkImage.width
      height: artworkImage.height
      radius: Math.max(0, albumArt.radius - albumArt.border.width)
      color: "white"
      visible: false
      layer.enabled: true
    }

    Text {
      objectName: "artworkFallback"
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: artworkImage.status !== Image.Ready
      text: "\u{f075a}"
      color: media.view.secondary
      opacity: 0.78
      font.family: media.view.iconFontFamily
      font.pixelSize: Math.round(20 * media.view.uiScale)
      font.weight: Font.Light
    }
  }

  Column {
    id: trackInfo
    visible: !media.line
    anchors.left: albumArt.right
    anchors.leftMargin: Math.round(17 * media.view.uiScale)
    anchors.right: mediaControls.left
    anchors.rightMargin: Math.round(16 * media.view.uiScale)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Math.round(3 * media.view.uiScale)

    Text {
      objectName: "trackTitle"
      textFormat: Text.PlainText
      width: parent.width
      text: media.view.activePlayer ? String(media.view.activePlayer.trackTitle || "") : ""
      color: media.view.foreground
      font.family: media.view.textFontFamily
      font.pixelSize: Math.round(17 * media.view.uiScale)
      font.weight: Font.Medium
      elide: Text.ElideRight
    }

    Text {
      objectName: "trackArtist"
      textFormat: Text.PlainText
      width: parent.width
      text: media.view.activePlayer ? String(media.view.activePlayer.trackArtist || "") : ""
      color: media.view.secondary
      font.family: media.view.textFontFamily
      font.pixelSize: Math.round(15 * media.view.uiScale)
      font.weight: Font.Light
      elide: Text.ElideRight
    }
  }

  Row {
    id: mediaControls
    objectName: "mediaControls"
    visible: !media.line
    // Transport controls keep their left-to-right order in every language:
    // mirroring flips this Row's direction, so ask for the opposite.
    layoutDirection: media.view.rightToLeft ? Qt.RightToLeft : Qt.LeftToRight
    anchors.right: parent.right
    anchors.rightMargin: Math.round(12 * media.view.uiScale)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Math.round(5 * media.view.uiScale)

    Item {
      width: Math.round(42 * media.view.uiScale)
      height: width
      opacity: media.view.activePlayer && media.view.activePlayer.canGoPrevious ? 1 : 0.38

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: previousMouse.containsMouse && previousMouse.enabled
          ? Qt.rgba(1, 1, 1, 0.1)
          : "transparent"
      }

      LineIcon {
        anchors.centerIn: parent
        width: Math.round(21 * media.view.uiScale)
        height: width
        pathData: "M6 5v14 M19 5 8 12l11 7Z"
        opacity: 0.9
      }

      MouseArea {
        id: previousMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: media.view.activePlayer && media.view.activePlayer.canGoPrevious
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: media.view.runMediaAction("previous")
      }
    }

    Item {
      width: Math.round(46 * media.view.uiScale)
      height: width
      opacity: media.view.activePlayer
        && (media.view.activePlayer.canTogglePlaying || media.view.activePlayer.canPlay || media.view.activePlayer.canPause) ? 1 : 0.38

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: playMouse.containsMouse && playMouse.enabled
          ? Qt.rgba(1, 1, 1, 0.1)
          : "transparent"
      }

      LineIcon {
        anchors.centerIn: parent
        width: Math.round(26 * media.view.uiScale)
        height: width
        pathData: media.view.activePlayer && media.view.activePlayer.isPlaying ? "M8 5v14 M16 5v14" : "M7 4 20 12 7 20Z"
        opacity: 0.9
      }

      MouseArea {
        id: playMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: media.view.activePlayer
          && (media.view.activePlayer.canTogglePlaying || media.view.activePlayer.canPlay || media.view.activePlayer.canPause)
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: media.view.runMediaAction("playPause")
      }
    }

    Item {
      width: Math.round(42 * media.view.uiScale)
      height: width
      opacity: media.view.activePlayer && media.view.activePlayer.canGoNext ? 1 : 0.38

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: nextMouse.containsMouse && nextMouse.enabled
          ? Qt.rgba(1, 1, 1, 0.1)
          : "transparent"
      }

      LineIcon {
        anchors.centerIn: parent
        width: Math.round(21 * media.view.uiScale)
        height: width
        pathData: "M18 5v14 M5 5l11 7-11 7Z"
        opacity: 0.9
      }

      MouseArea {
        id: nextMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: media.view.activePlayer && media.view.activePlayer.canGoNext
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: media.view.runMediaAction("next")
      }
    }
  }
}
