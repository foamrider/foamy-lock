// Thumbnail shell: every selectable preset at 1920×1080 with the synthetic
// data, captured at 480×270 (and at full size when __FULL__ is true). The
// offscreen platform has no GPU, so they show what CPU rendering shows (no
// blur or masks); reduced motion is on as well, so the drawn backgrounds
// hold their still frame. Written into a temporary app by the harness.
import QtQuick
import Quickshell
import qs.Commons as Commons
import "Layout.js" as Layout

ShellRoot {
  id: shellRoot
  readonly property var presets: __PRESETS__
  readonly property bool full: __FULL__
  property int at: 0
  property int phase: 0
  property int pending: 0

  Component.onCompleted: Commons.Style.reduceMotion = true

  FloatingWindow {
    visible: true
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    LockView {
      id: view
      width: 1920
      height: 1080
      userName: "foamy"
      userDisplayName: "Foamy User"
      backgroundPath: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
      activePlayer: player
      artworkPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
      // No picture: CPU rendering can't mask it round; the initial reads.
      avatarPath: ""
      fingerprintConfigured: true
      look: Layout.defaults()
      onPasswordTextEdited: function (value) {
        passwordText = value
      }
    }
  }
  QtObject {
    id: player
    property string trackTitle: "Evening Light"
    property string trackArtist: "Sample Artist"
    property bool isPlaying: true
    property bool canGoPrevious: true
    property bool canGoNext: true
    property bool canTogglePlaying: true
    property bool canPlay: true
    property bool canPause: true
  }

  function path(name) {
    return Qt.resolvedUrl(name).toString().replace("file://", "")
  }

  function grab(file, size) {
    pending++
    var ok = size ? view.grabToImage(function (result) {
      save(result, file)
    }, size) : view.grabToImage(function (result) {
      save(result, file)
    })
    if (!ok) {
      console.error("THUMBNAILS_FAIL: capture of " + file)
      Qt.exit(1)
    }
  }

  function save(result, file) {
    if (!result.saveToFile(path(file))) {
      console.error("THUMBNAILS_FAIL: saving " + file)
      Qt.exit(1)
    }
    pending--
  }

  Timer {
    // Above the view's 300 ms geometry debounce.
    interval: 450
    repeat: true
    running: true
    onTriggered: {
      if (shellRoot.pending > 0)
        return
      if (shellRoot.at >= shellRoot.presets.length) {
        console.log("THUMBNAILS_PASS: " + shellRoot.presets.length + " presets")
        Qt.quit()
        return
      }
      var name = shellRoot.presets[shellRoot.at]
      if (shellRoot.at === 0 && shellRoot.phase === 0)
        console.log("thumbnails: renderer " + (view.GraphicsInfo.api === GraphicsInfo.Software ? "software" : "gpu") + ", motion " + (view.motionAllowed ? "on" : "off"))
      if (shellRoot.phase === 0) {
        view.look = Layout.preset(name)
        shellRoot.phase = 1
        return
      }
      if (view.fallbackPreset !== "") {
        console.error("THUMBNAILS_FAIL: " + name + " fell back: " + view.layoutError)
        Qt.exit(1)
        return
      }
      shellRoot.grab("thumb-" + name + ".png", Qt.size(480, 270))
      if (shellRoot.full)
        shellRoot.grab("capture-" + name + ".png", null)
      console.log("thumbnail: " + name)
      shellRoot.phase = 0
      shellRoot.at++
    }
  }
}
