import QtQuick
import QtQuick.Effects

// Now playing. Styles:
// - "card": artwork thumbnail, title, artist and transport controls on glass;
// - "line": title and artist on one line;
// - "pill": a small glass pill: round thumbnail, title, play/pause;
// - "art": a large artwork square with the title, artist and transport below;
// - "hero": no surface: a large rounded cover, the title and artist centred
//   under it (no controls: the media keys still work while locked);
// - "minimal": one line of text, "♪ Title — Artist", no controls;
// - "disc": a round cover with a centre hole, the title and artist beside it
//   and play/pause. It turns only while the player plays, with GPU
//   rendering, motion not reduced, the display awake and the element shown.
// Only the service's sandboxed thumbnail reaches this view, and only while
// `artwork` (the look's media.artwork) is on; otherwise, as without a
// thumbnail, the music icon shows in its place.
Rectangle {
  id: media
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
  property string styleName: "card"
  readonly property bool line: styleName === "line"
  readonly property bool cardStyle: styleName === "card"
  readonly property bool pill: styleName === "pill"
  readonly property bool art: styleName === "art"
  readonly property bool hero: styleName === "hero"
  readonly property bool minimal: styleName === "minimal"
  readonly property bool disc: styleName === "disc"
  // The styles that draw a cover (Layout.ARTWORK_STYLES), and whether this
  // look shows the player's artwork in it.
  readonly property bool coverShown: !line && !minimal
  property bool artwork: true
  readonly property bool playing: !!view.activePlayer && !!view.activePlayer.isPlaying
  // The disc may turn (see the header); it turns while playing. One turn
  // takes discTurnMs (a loop period, not a transition).
  readonly property bool discMotion: disc && view.gpuRendering && view.displayAwake && visible
  readonly property bool discSpinning: discMotion && !view.reduceMotion && playing
  readonly property int discTurnMs: 12000
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
  // The hero's rows: the cover as wide as the element (at most the centre
  // column), then the title and the artist.
  readonly property real heroWidth: Math.min(Math.round(280 * uiScale), contentWidth)
  readonly property real heroTitleY: heroWidth + Math.round(14 * uiScale)
  readonly property real heroArtistY: heroTitleY + Math.round(28 * uiScale)
  // The disc: the cover, then the title and artist, then play/pause.
  readonly property real discSize: Math.round(84 * uiScale)
  readonly property real discGap: Math.round(14 * uiScale)
  readonly property real discTextWidth: Math.min(Math.max(mediaTitle.implicitWidth, artArtist.implicitWidth), Math.round(220 * uiScale))
  readonly property real minimalWidth: Math.min(minimalLine.implicitWidth, contentWidth)
  readonly property string title: view.activePlayer ? String(view.activePlayer.trackTitle || "") : ""
  readonly property string artist: view.activePlayer ? String(view.activePlayer.trackArtist || "") : ""

  objectName: "mediaRow"
  width: line ? Math.min(mediaLine.implicitWidth, contentWidth) : minimal ? minimalWidth : pill ? Math.min(contentWidth, pillPadding + albumArt.width + Math.round(12 * uiScale) + pillTitleWidth + Math.round(6 * uiScale) + mediaControls.width + pillPadding) : art ? artWidth : hero ? heroWidth : disc ? Math.min(contentWidth, discSize + discGap + discTextWidth + Math.round(8 * uiScale) + mediaControls.width) : Math.min(Math.round(470 * uiScale), view.width - 48 * view.uiScale)
  height: pill ? Math.round(46 * uiScale) : art ? artControlsY + Math.round(54 * uiScale) : hero ? heroArtistY + Math.round(24 * uiScale) : disc ? discSize : Math.round((line || minimal ? 30 : 92) * uiScale)
  // The line, minimal, hero and disc have no surface.
  readonly property bool surface: cardStyle || pill || art
  // Its surface's corner radius (a shape's "auto" radius), -1 without one.
  readonly property real surfaceRadius: surface ? radius : -1
  radius: pill ? height / 2 : Math.round(22 * uiScale)
  color: surface && surfaceShown ? glassFill : "transparent"
  border.width: surface && surfaceShown ? 1 : 0
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
        if (!player)
          return ""
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

  // "minimal": one line of text, no icon or controls.
  Text {
    id: minimalLine
    objectName: "mediaMinimal"
    visible: media.minimal
    anchors.verticalCenter: parent.verticalCenter
    x: media.mirrored ? media.width - width : 0
    width: media.minimalWidth
    textFormat: Text.PlainText
    text: {
      var parts = [media.title, media.artist].filter(function (part) {
        return part !== ""
      })
      return parts.length > 0 ? "\u266a " + parts.join(" \u2014 ") : ""
    }
    color: media.view.foreground
    opacity: 0.88
    font.family: media.view.textFontFamily
    font.pixelSize: Math.round(15 * media.uiScale)
    elide: Text.ElideRight
  }

  Rectangle {
    id: albumArt
    objectName: "albumArt"
    visible: media.coverShown
    // The card's thumbnail, the pill's round one, the art square, the
    // hero's cover or the disc.
    readonly property real inset: media.pill ? media.pillPadding : media.art ? media.artPadding : media.hero || media.disc ? 0 : Math.round(14 * media.uiScale)
    width: media.pill ? media.height - 2 * media.pillPadding : media.art ? media.artSize : media.hero ? media.heroWidth : media.disc ? media.discSize : Math.round(64 * media.uiScale)
    height: width
    // Round in the pill and the disc where the GPU masks the artwork;
    // without the mask a rounded square matches the clipped picture.
    radius: media.pill || media.disc ? (GraphicsInfo.api !== GraphicsInfo.Software ? width / 2 : Math.round((media.disc ? 12 : 7) * media.uiScale)) : Math.round((media.art ? 14 : media.hero ? 18 : 9) * media.uiScale)
    x: media.art ? media.artPadding : media.hero ? 0 : media.mirrored ? media.width - inset - width : inset
    y: media.art ? media.artPadding : media.hero ? 0 : (media.height - height) / 2
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
      source: media.artwork && media.view.artworkPath ? media.view.fileUrl(media.view.artworkPath, 0) : ""
      sourceSize.width: 256
      sourceSize.height: 256
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      visible: status === Image.Ready
      onStatusChanged: if (status === Image.Error)
        media.view.artworkFailed(media.view.artworkPath)
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
      font.pixelSize: Math.round((media.hero ? 72 : media.art ? 54 : media.disc ? 26 : media.pill ? 16 : 20) * media.uiScale)
      font.weight: Font.Light
    }

    // The disc's centre hole, turning with it.
    Rectangle {
      objectName: "discHole"
      visible: media.disc
      anchors.centerIn: parent
      width: Math.round(14 * media.uiScale)
      height: width
      radius: width / 2
      color: Qt.rgba(0.025, 0.035, 0.065, 0.9)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.22)
    }
  }

  // The disc turns while the player plays: GPU rendering only, never with
  // reduced motion, while blanked or while the element isn't shown. Paused,
  // it holds its angle; stopped, it goes back upright.
  RotationAnimator {
    target: albumArt
    from: 0
    to: 360
    duration: media.discTurnMs
    loops: Animation.Infinite
    running: media.discMotion && !media.view.reduceMotion
    paused: running && !media.playing
    onRunningChanged: if (!running)
      albumArt.rotation = 0
  }

  // "pill" and "art": the title (and, for art, the artist below).
  Text {
    id: mediaTitle
    objectName: "mediaTitle"
    visible: media.pill || media.art || media.hero || media.disc
    readonly property real pillStart: media.pillPadding + albumArt.width + Math.round(12 * media.uiScale)
    readonly property real discStart: media.discSize + media.discGap
    x: media.art ? media.artPadding : media.hero ? 0 : media.disc ? (media.mirrored ? media.width - discStart - width : discStart) : media.mirrored ? media.width - pillStart - width : pillStart
    y: media.art ? media.artTitleY : media.hero ? media.heroTitleY : media.disc ? Math.round(media.height / 2 - height) : (media.height - height) / 2
    width: media.art ? media.width - 2 * media.artPadding : media.hero ? media.width : media.disc ? Math.max(0, Math.min(media.discTextWidth, media.width - discStart - Math.round(8 * media.uiScale) - mediaControls.width)) : media.pillTitleWidth
    height: Math.round((media.hero ? 28 : media.art ? 24 : 22) * media.uiScale)
    textFormat: Text.PlainText
    text: media.pill ? media.title || media.artist : media.title
    color: media.view.foreground
    font.family: media.view.textFontFamily
    font.pixelSize: Math.round((media.hero ? 20 : media.art ? 17 : 15) * media.uiScale)
    font.weight: Font.Medium
    horizontalAlignment: media.art || media.hero ? Text.AlignHCenter : Text.AlignLeft
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Text {
    id: artArtist
    objectName: "mediaArtist"
    visible: media.art || media.hero || media.disc
    x: media.art ? media.artPadding : media.hero ? 0 : mediaTitle.x
    y: media.art ? media.artArtistY : media.hero ? media.heroArtistY : Math.round(media.height / 2 + 2 * media.uiScale)
    width: media.art ? media.width - 2 * media.artPadding : media.hero ? media.width : mediaTitle.width
    height: Math.round(20 * media.uiScale)
    textFormat: Text.PlainText
    text: media.artist
    color: media.view.secondary
    font.family: media.view.textFontFamily
    font.pixelSize: Math.round((media.hero ? 16 : 14) * media.uiScale)
    font.weight: Font.Light
    horizontalAlignment: media.disc ? Text.AlignLeft : Text.AlignHCenter
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
    visible: !media.line && !media.minimal && !media.hero
    // Transport controls keep their left-to-right order in every language:
    // mirroring flips this Row's direction, so ask for the opposite.
    layoutDirection: media.view.rightToLeft ? Qt.RightToLeft : Qt.LeftToRight
    // At the trailing end of the card, pill and disc (mirrored by hand),
    // centred under the art. The pill and the disc keep only play/pause.
    readonly property bool playOnly: media.pill || media.disc
    readonly property real trailing: Math.round((media.pill ? 5 : media.disc ? 0 : 12) * media.uiScale)
    x: media.art ? Math.round((media.width - width) / 2) : media.mirrored ? trailing : media.width - trailing - width
    y: media.art ? media.artControlsY : (media.height - height) / 2
    spacing: Math.round(5 * media.uiScale)

    Item {
      visible: !mediaControls.playOnly
      width: Math.round(42 * media.uiScale)
      height: width
      opacity: media.view.activePlayer && media.view.activePlayer.canGoPrevious ? 1 : 0.38

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: previousMouse.containsMouse && previousMouse.enabled ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
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
      opacity: media.view.activePlayer && (media.view.activePlayer.canTogglePlaying || media.view.activePlayer.canPlay || media.view.activePlayer.canPause) ? 1 : 0.38

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: playMouse.containsMouse && playMouse.enabled ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
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
        enabled: media.view.activePlayer && (media.view.activePlayer.canTogglePlaying || media.view.activePlayer.canPlay || media.view.activePlayer.canPause)
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: media.view.runMediaAction("playPause")
      }
    }

    Item {
      visible: !mediaControls.playOnly
      width: Math.round(42 * media.uiScale)
      height: width
      opacity: media.view.activePlayer && media.view.activePlayer.canGoNext ? 1 : 0.38

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: nextMouse.containsMouse && nextMouse.enabled ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
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
