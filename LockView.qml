import QtQuick
import Quickshell
import Quickshell.Networking
import Quickshell.Services.UPower
// Qualify the theme singleton to avoid QtQuick.Color taking precedence.
import qs.Commons as Commons
import "kit"
import "Model.js" as Model
import "elements"

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool fingerprintUnavailable: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property var activePlayer: null
  property string artworkPath: ""
  property bool showUserInfo: true
  property string timeFormat: "24h"
  property string passwordText: ""
  property bool syncingPasswordText: false
  property string userName: ""
  property string userDisplayName: ""
  property string avatarPath: ""
  property int avatarVersion: 0

  readonly property string displayName: String(userDisplayName || "").trim()
    || String(userName || "").trim()
  // The lock is an art-directed surface: its own typefaces and white glass
  // over the wallpaper scrim. Missing typefaces fall back to the foamy body
  // and Omarchy fonts; a theme that styles the lock ([lock] in shell.toml)
  // wins over the glass defaults.
  readonly property var installedFonts: Qt.fontFamilies()
  readonly property string textFontFamily: fontOr("Adwaita Sans", FoamyStyle.fontFamily)
  readonly property string displayFontFamily: fontOr("URW Gothic", FoamyStyle.fontFamily)
  readonly property string iconFontFamily: fontOr("JetBrainsMono Nerd Font", FoamyStyle.monoFamily)
  property bool rightToLeft: FoamyI18n.rightToLeft
  readonly property string placeholderText: FoamyI18n.t("Enter password")
  readonly property real uiScale: Math.max(0.82, Math.min(1.12, height / 1080))
  readonly property real contentWidth: Math.min(Math.round(560 * uiScale), width - Math.round(64 * uiScale))
  readonly property real fieldWidth: Math.min(Math.round(320 * uiScale), contentWidth)
  readonly property int fieldHeight: Math.round(51 * uiScale)
  readonly property int fieldLeadingInset: Math.round(24 * uiScale)
  readonly property int fieldFontSize: Math.round(18 * uiScale)
  readonly property int passwordDotFontSize: Math.round(17 * uiScale)
  readonly property int passwordDotLetterSpacing: Math.round(2 * uiScale)
  readonly property color foreground: themeLock("text", Commons.Color.lock.text, Qt.rgba(0.98, 0.98, 1, 0.96))
  readonly property color secondary: themeLock("placeholder", Commons.Color.lock.placeholder, Qt.rgba(0.94, 0.95, 1, 0.68))
  readonly property color glass: themeLock("background", Commons.Color.lock.background, Qt.rgba(0.025, 0.035, 0.065, 0.34))
  readonly property color glassBorder: themeLock("border", Commons.Color.lock.border, Qt.rgba(0.95, 0.96, 1, 0.18))
  readonly property color selection: themeLock("selection", Commons.Color.lock.selection, Qt.rgba(1, 1, 1, 0.25))
  readonly property bool hasMedia: activePlayer !== null
    && (String(activePlayer.trackTitle || "") !== "" || String(activePlayer.trackArtist || "") !== "")
  readonly property var batteryDevice: UPower.displayDevice
  readonly property bool hasBattery: batteryDevice
    && batteryDevice.ready
    && batteryDevice.isPresent
    && batteryDevice.isLaptopBattery
  readonly property int batteryPercentage: hasBattery ? Math.round(Number(batteryDevice.percentage || 0) * 100) : 0
  readonly property bool wiredConnected: hasConnectedDevice(DeviceType.Wired)
  readonly property string networkLabel: networkStatusLabel()
  readonly property string networkIcon: wiredConnected ? "\u{ef09}" : (networkLabel === "Offline" ? "\u{f092e}" : "\u{f1eb}")
  readonly property var userLocale: Qt.locale(FoamyI18n.formatLocale)
  // The clock and date read this; the render harness replaces lockClock.date.
  readonly property var now: lockClock.date
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  // Keep the editor focused while invisible so the first character is retained.
  readonly property bool compactLayout: width < 1100 * uiScale
  readonly property bool showPassword: passwordText.length > 0 || authenticatingPassword || errorState

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  signal artworkFailed(string path)

  LayoutMirroring.enabled: rightToLeft
  LayoutMirroring.childrenInherit: true

  function fontOr(family, fallback) {
    return installedFonts.indexOf(family) !== -1 ? family : fallback
  }

  // Commons.Color.lock.* always has a value (theme foreground and friends);
  // only an explicit [lock] entry replaces the glass look.
  function themeLock(key, themed, glass) {
    var values = Commons.Color.shellValues || ({})
    var value = values["lock." + key]
    return typeof value === "string" && value.length > 0 ? themed : glass
  }

  // Cache-bust profile and wallpaper images when their files change in place.
  function fileUrl(path, version) {
    if (!path) return ""
    return Model.fileUrl(path, version)
  }

  // Monitor wake can delay key releases; only deletion should auto-repeat.
  function dropsAutoRepeat(key) {
    return key !== Qt.Key_Backspace && key !== Qt.Key_Delete
  }

  function forcePasswordFocus() {
    inputField.input.forceActiveFocus()
  }

  function syncPasswordText() {
    if (inputField.input.text === passwordText) return
    syncingPasswordText = true
    inputField.input.text = passwordText
    syncingPasswordText = false
  }

  function submitCurrentPassword() {
    if (!inputEnabled || authenticatingPassword || passwordText.length === 0) return
    var submitted = passwordText
    passwordTextEdited("")
    submitPassword(submitted)
  }

  function networkStatusLabel() {
    if (Networking.connectivity === NetworkConnectivity.Full) return "Connected"
    if (Networking.connectivity === NetworkConnectivity.Portal) return "Sign-in required"
    if (Networking.connectivity === NetworkConnectivity.Limited) return "Limited connection"
    if (Networking.connectivity === NetworkConnectivity.None) return "Offline"

    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].connected) return "Connected"
    }
    return "Offline"
  }

  function hasConnectedDevice(deviceType) {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].type === deviceType && devices[i].connected) return true
    }
    return false
  }

  function batteryIcon(level) {
    var device = root.batteryDevice
    if (!device) return ""

    var index = Math.max(0, Math.min(9, Math.floor(level / 10)))
    var chargingIcons = ["\u{f089c}", "\u{f0086}", "\u{f0087}", "\u{f0088}", "\u{f089d}", "\u{f0089}", "\u{f089e}", "\u{f008a}", "\u{f008b}", "\u{f0085}"]
    var defaultIcons = ["\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}", "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}"]

    if (!UPower.onBattery && device.state === UPowerDeviceState.Charging) return chargingIcons[index]
    if (!UPower.onBattery
        && (device.state === UPowerDeviceState.FullyCharged || device.state === UPowerDeviceState.PendingCharge)) return "\u{f17e2}"
    return defaultIcons[index]
  }

  function runMediaAction(action) {
    if (!activePlayer) return
    Model.runMediaAction(activePlayer, action)
    wakeRequested()
    forcePasswordFocus()
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    Image {
      id: wallpaper
      objectName: "lockWallpaper"
      anchors.fill: parent
      source: root.loadBackground && width > 0 && height > 0 ? root.fileUrl(root.backgroundPath, root.backgroundVersion) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      sourceSize.width: width
      sourceSize.height: height
    }

    // A light scrim preserves wallpaper detail while keeping white type legible.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0.005, 0.01, 0.025, 0.25)
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    FoamyWallClock {
      id: lockClock
    }

    Column {
      id: mainColumn
      z: 2
      width: root.contentWidth
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Math.round(42 * root.uiScale), Math.round(parent.height * 0.09))
      // Offset the clock font’s top bearing to bring the visible numerals closer to the date.
      spacing: Math.round(-20 * root.uiScale)

      DateElement {
        id: dateLabel
        view: root
        width: parent.width
      }

      ClockElement {
        id: clockLabel
        view: root
        width: parent.width
      }
    }

    Column {
      id: loginColumn
      width: root.contentWidth
      anchors.horizontalCenter: parent.horizontalCenter
      // Reserve authentication space independently of media and input state.
      y: Math.min(root.height * 0.65, root.height - height - (root.compactLayout ? 140 : 36) * root.uiScale)
      spacing: Math.round(14 * root.uiScale)

      AccountElement {
        id: identityBlock
        view: root
        width: parent.width
      }

      PasswordElement {
        id: inputField
        view: root
        x: Math.round((parent.width - width) / 2)
      }
    }

    Text {
      objectName: "fingerprintNotice"
      anchors.top: loginColumn.bottom
      anchors.topMargin: Math.round(8 * root.uiScale)
      anchors.horizontalCenter: loginColumn.horizontalCenter
      width: root.contentWidth
      visible: root.fingerprintUnavailable
      textFormat: Text.PlainText
      text: FoamyI18n.t("Fingerprint reader unavailable")
      color: root.foreground
      font.family: root.textFontFamily
      font.pixelSize: Math.round(13 * root.uiScale)
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    MediaElement {
      id: mediaRow
      view: root
      anchors.left: parent.left
      // Stack below authentication on narrow displays to avoid overlap.
      anchors.leftMargin: root.compactLayout
        ? Math.round((root.width - width) / 2)
        : Math.round(32 * root.uiScale)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.round(32 * root.uiScale)
    }

    StatusElement {
      id: statusFooter
      view: root
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Math.round(24 * root.uiScale)
    }
  }
}
