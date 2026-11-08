import QtQuick
import QtQuick.Effects

// Now playing. Styles: "card" (artwork thumbnail, title, artist and
// transport controls on glass), "line" (title and artist on one line),
// "pill" (a small glass pill: round thumbnail, title, play/pause) and "art"
// (a large artwork square with the title, artist and transport below).
// Only the service's sandboxed thumbnail reaches this view.
Rectangle {
  id: media
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // This element's size: the view's scale for its screen (LockView sets it).
  required property real uiScale
  property string styleName: "card"
  readonly property bool line: styleName === "line"
  readonly property bool cardStyle: styleName === "card"
  readonly property bool pill: styleName === "pill"
  readonly property bool art: styleName === "art"
  // Positions of the new styles are plain x/y bindings, mirrored here.
  // The centre column at this element's scale: the line and pill never grow past it.
  readonly property real contentWidth: view.contentWidthAt(uiScale)
  readonly property bool mirrored: view.rightToLeft
  readonly property real pillPadding: Math.round(6 * uiScale)
  readonly property real artPadding: Math.round(14 * uiScale)
  // The art style's rows, from constants (no chain through the items).
  readonly property real artWidth: Math.round(236 * uiScale)
  readonly property real artSize: artWidth - 2 * artPadding
  readonly property real artTitleY: artPadding + artSize + Math.round(12 * uiScale)
  readonly property real artArtistY: artTitleY + Math.round(24 * uiScale)
  readonly property real artControlsY: artArtistY + Math.round(26 * uiScale)
  readonly property real pillTitleWidth: Math.min(mediaTitle.implicitWidth, Math.round(220 * uiScale))
  readonly property string title: view.activePlayer ? String(view.activePlayer.trackTitle || "") : ""
  readonly property string artist: view.activePlayer ? String(view.activePlayer.trackArtist || "") : ""

  objectName: "mediaRow"
  width: line ? Math.min(mediaLine.implicitWidth, contentWidth)
    : pill ? Math.min(contentWidth, pillPadding + albumArt.width + Math.round(12 * uiScale) + pillTitleWidth
      + Math.round(6 * uiScale) + mediaControls.width + pillPadding)
    : art ? artWidth
    : Math.min(Math.round(470 * uiScale), view.width - 48 * view.uiScale)
  height: pill ? Math.round(46 * uiScale)
    : art ? artControlsY + Math.round(54 * uiScale)
    : Math.round((line ? 30 : 92) * uiScale)
  radius: pill ? height / 2 : Math.round(22 * uiScale)
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
    spacing: Math.round(8 * media.uiScale)

    LineIcon {
      id: lineIcon
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round(18 * media.uiScale)
      height: width
      pathData: "M9 18V5l12-2v13 M9 18a3 3 0 1 1-3-3 3 3 0 0 1 3 3Z M21 16a3 3 0 1 1-3-3 3 3 0 0 1 3 3Z"
      opacity: 0.8
    }

    Text {
      objectName: "mediaLineText"
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, media.contentWidth - lineIcon.width - parent.spacing)
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
      font.pixelSize: Math.round(15 * media.uiScale)
      elide: Text.ElideRight
    }
  }

  Rectangle {
    id: albumArt
    objectName: "albumArt"
    visible: !media.line
    // The card's thumbnail, the pill's round one, or the art square.
    readonly property real inset: media.pill ? media.pillPadding : media.art ? media.artPadding : Math.round(14 * media.uiScale)
    width: media.pill ? media.height - 2 * media.pillPadding : media.art ? media.artSize
      : Math.round(64 * media.uiScale)
    height: width
    // Round in the pill where the GPU masks the artwork; without the mask a
    // rounded square matches the clipped picture.
    radius: media.pill ? (GraphicsInfo.api !== GraphicsInfo.Software ? width / 2 : Math.round(7 * media.uiScale))
      : Math.round((media.art ? 14 : 9) * media.uiScale)
    x: media.art ? media.artPadding : media.mirrored ? media.width - inset - width : inset
    y: media.art ? media.artPadding : (media.height - height) / 2
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
      // The new styles mask only on the GPU (the software renderer draws no
      // effects) and show the clipped square there.
      layer.enabled: media.cardStyle || GraphicsInfo.api !== GraphicsInfo.Software
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
      font.pixelSize: Math.round((media.art ? 54 : media.pill ? 16 : 20) * media.uiScale)
      font.weight: Font.Light
    }
  }

  // "pill" and "art": the title (and, for art, the artist below).
  Text {
    id: mediaTitle
    objectName: "mediaTitle"
    visible: media.pill || media.art
    readonly property real pillStart: media.pillPadding + albumArt.width + Math.round(12 * media.uiScale)
    x: media.art ? media.artPadding : media.mirrored ? media.width - pillStart - width : pillStart
    y: media.art ? media.artTitleY : (media.height - height) / 2
    width: media.art ? media.width - 2 * media.artPadding : media.pillTitleWidth
    height: Math.round((media.art ? 24 : 22) * media.uiScale)
    textFormat: Text.PlainText
    text: media.pill ? media.title || media.artist : media.title
    color: media.view.foreground
    font.family: media.view.textFontFamily
    font.pixelSize: Math.round((media.art ? 17 : 15) * media.uiScale)
    font.weight: Font.Medium
    horizontalAlignment: media.art ? Text.AlignHCenter : Text.AlignLeft
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Text {
    id: artArtist
    objectName: "mediaArtist"
    visible: media.art
    x: media.artPadding
    y: media.artArtistY
    width: media.width - 2 * media.artPadding
    height: Math.round(20 * media.uiScale)
    textFormat: Text.PlainText
    text: media.artist
    color: media.view.secondary
    font.family: media.view.textFontFamily
    font.pixelSize: Math.round(14 * media.uiScale)
    font.weight: Font.Light
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Column {
    id: trackInfo
    visible: media.cardStyle
    anchors.left: albumArt.right
    anchors.leftMargin: Math.round(17 * media.uiScale)
    anchors.right: mediaControls.left
    anchors.rightMargin: Math.round(16 * media.uiScale)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Math.round(3 * media.uiScale)

    Text {
      objectName: "trackTitle"
      textFormat: Text.PlainText
      width: parent.width
      text: media.view.activePlayer ? String(media.view.activePlayer.trackTitle || "") : ""
      color: media.view.foreground
      font.family: media.view.textFontFamily
      font.pixelSize: Math.round(17 * media.uiScale)
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
      font.pixelSize: Math.round(15 * media.uiScale)
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
    // At the trailing end of the card and pill (mirrored by hand), centred
    // under the art. The pill keeps only play/pause.
    readonly property real trailing: Math.round((media.pill ? 5 : 12) * media.uiScale)
    x: media.art ? Math.round((media.width - width) / 2) : media.mirrored ? trailing : media.width - trailing - width
    y: media.art ? media.artControlsY : (media.height - height) / 2
    spacing: Math.round(5 * media.uiScale)

    Item {
      visible: !media.pill
      width: Math.round(42 * media.uiScale)
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
        width: Math.round(21 * media.uiScale)
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
      width: Math.round((media.pill ? 36 : 46) * media.uiScale)
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
        width: Math.round((media.pill ? 20 : 26) * media.uiScale)
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
      visible: !media.pill
      width: Math.round(42 * media.uiScale)
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
        width: Math.round(21 * media.uiScale)
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
