import QtQuick
import "kit"

// The real LockView with the studio's sample data: a sample user and track
// (never the user's own name or media), no input, no fallback (problems are
// reported, see Checker), and the preview states. Network, battery, /proc
// and the clock stay real. The status's other readings and the weather are
// samples (`liveSources` false: the view opens no PipeWire, Bluetooth or
// Hyprland connection), never the user's own, and the weather's place is
// a made-up one. With `widest`, every sample is the widest it could be
// (the Checker's views: full weather with a long condition and place, every
// status item with a long reading), so a look that fits here fits on the
// lock screen. Disabled, so no pointer or key ever reaches the lock's own
// controls under the canvas.
LockView {
  id: sample

  // "idle", "typing", "wrong" or "noMedia".
  property string previewState: "idle"
  // The lock's "show media" setting: off, the player never shows.
  property bool showMedia: true
  // The widest samples (for the geometry check).
  property bool widest: false

  enabled: false
  inputEnabled: false
  latchFallback: false
  primary: true
  liveSources: false
  userName: "sample"
  userDisplayName: FoamyI18n.t("studio.sample.user")
  activePlayer: previewState === "noMedia" || !showMedia ? null : samplePlayer
  passwordText: previewState === "typing" ? "sample-password" : ""
  // The lock's own message for a refused password (PasswordElement shows
  // "Authentication failed (1)").
  failureMessage: previewState === "wrong" ? "Authentication failed" : ""
  failedAttempts: previewState === "wrong" ? 1 : 0

  hasVolume: true
  volumePercent: widest ? 100 : 64
  volumeMuted: false
  hasBluetooth: true
  bluetoothEnabled: true
  bluetoothConnected: widest ? 8 : 1
  keyboardLayout: widest ? FoamyI18n.t("studio.sample.keyboardLong") : FoamyI18n.t("studio.sample.keyboard")
  // Model.parseWeather's shape. The widest: the reply's limits (-150°, a
  // 64-character condition, an 80-character place).
  weather: ({
    temperature: widest ? -150 : 12, unit: "C", code: widest ? "heavyrainandthunder" : "partlycloudy_day",
    condition: widest ? FoamyI18n.t("studio.sample.conditionLong") : FoamyI18n.t("studio.sample.condition"),
    high: widest ? -150 : 14, low: widest ? -150 : 7,
    location: widest ? "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Ynys Môn, Cymru (UK)"
      : FoamyI18n.t("studio.sample.place"),
    updatedAtMs: Date.now()
  })

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
