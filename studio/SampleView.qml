import QtQuick
import "kit"

// The real LockView with the studio's sample data: a sample user and track
// (never the user's own name or media), no input, no fallback (problems are
// reported, see Checker), and the preview states. Network, battery and the
// clock stay real. Disabled, so no pointer or key ever reaches the lock's
// own controls under the canvas.
LockView {
  id: sample

  // "idle", "typing", "wrong" or "noMedia".
  property string previewState: "idle"

  enabled: false
  inputEnabled: false
  latchFallback: false
  primary: true
  userName: "sample"
  userDisplayName: FoamyI18n.t("studio.sample.user")
  activePlayer: previewState === "noMedia" ? null : samplePlayer
  passwordText: previewState === "typing" ? "sample-password" : ""
  // The lock's own message for a refused password (PasswordElement shows
  // "Authentication failed (1)").
  failureMessage: previewState === "wrong" ? "Authentication failed" : ""
  failedAttempts: previewState === "wrong" ? 1 : 0

  QtObject {
    id: samplePlayer
    readonly property string trackTitle: FoamyI18n.t("studio.sample.track")
    readonly property string trackArtist: FoamyI18n.t("studio.sample.artist")
    readonly property bool isPlaying: true
    readonly property bool canGoPrevious: true
    readonly property bool canGoNext: true
    readonly property bool canTogglePlaying: true
    readonly property bool canPlay: true
    readonly property bool canPause: true
  }
}
