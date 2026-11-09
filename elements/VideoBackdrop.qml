pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtMultimedia

// A video background's clip, over its poster (LockView loads this only for
// motion "play", a clip from the helper's cache for this file and screen
// size, and GPU rendering). It shows nothing until its first frame has
// arrived, so the poster stays until then. Playing follows `playing`
// (LockView's pause rules); paused, the last frame stays. It plays muted
// (the clip has no sound) and loops. The first error, or no new frame for
// 2 s while it should play, is reported once through failed(); LockView then
// unloads it for the rest of the lock.
Item {
  id: video

  // The clip (an absolute path) and whether it should play now.
  property string path: ""
  property bool playing: false
  // The look's blur, applied here as the wallpaper's is (GPU only, like
  // this whole item).
  property real blur: 0
  // How long playback may go without a frame (a test can shorten it).
  property int stallMs: 2000
  readonly property bool frameSeen: frames > 0
  property int frames: 0
  property double lastProgressMs: 0
  property bool reported: false
  // Test hooks: the player's state.
  readonly property int playbackState: player.playbackState
  readonly property int mediaStatus: player.mediaStatus

  signal failed(string reason)

  objectName: "videoBackdrop"
  visible: frameSeen

  function fileUrl(path) {
    return path ? "file://" + String(path).split("/").map(encodeURIComponent).join("/") : ""
  }

  // Once: the view gives up after the first failure.
  function fail(reason) {
    if (reported) return
    reported = true
    player.stop()
    failed(reason)
  }

  // Plays or pauses the player's current source (a new source stops it,
  // so this runs again once the source is set).
  function follow() {
    if (reported || String(player.source) === "") return
    if (playing) {
      if (player.playbackState !== MediaPlayer.PlayingState) {
        lastProgressMs = Date.now()
        player.play()
      }
    } else if (player.playbackState === MediaPlayer.PlayingState) {
      player.pause()
    }
  }

  onPlayingChanged: follow()
  onPathChanged: frames = 0

  MediaPlayer {
    id: player
    source: video.fileUrl(video.path)
    loops: MediaPlayer.Infinite
    videoOutput: output
    onSourceChanged: video.follow()
    // Loading counts as progress: only a player that stops moving stalls.
    onMediaStatusChanged: {
      video.lastProgressMs = Date.now()
      video.follow()
    }
    onErrorOccurred: function(error, errorString) { video.fail("error") }
  }

  VideoOutput {
    id: output
    objectName: "videoOutput"
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectCrop
    layer.enabled: video.blur > 0
    layer.effect: MultiEffect {
      blurEnabled: true
      blur: video.blur
      blurMax: 64
      autoPaddingEnabled: false
    }
  }

  Connections {
    target: output.videoSink
    function onVideoFrameChanged() {
      video.frames += 1
      video.lastProgressMs = Date.now()
    }
  }

  // The stall check runs only while it should play.
  Timer {
    interval: 250
    repeat: true
    running: video.playing && !video.reported && video.path !== ""
    onTriggered: if (Date.now() - video.lastProgressMs >= video.stallMs) video.fail("stall")
  }
}
