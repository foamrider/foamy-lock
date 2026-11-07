import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Networking
import Quickshell.Services.UPower
// Qualify the theme singleton to avoid QtQuick.Color taking precedence.
import qs.Commons as Commons
import "kit"
import "Model.js" as Model
import "Layout.js" as Layout
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
  // backgroundPath is already blurred to the look's amount (prepared by the
  // helper); otherwise a GPU renderer blurs it here.
  property bool backgroundPrepared: false
  // The look (Layout.js): preset, element zones and styles, background, glass.
  property var look: Layout.defaults()
  // This surface gets the keystrokes (or no surface is known to): it shows
  // the account and the field. Every surface keeps a live password input.
  property bool primary: true
  // Geometry fallback: "" shows `look`; otherwise the preset shown instead,
  // latched until the look changes (each lock creates a new view).
  property string fallbackPreset: ""
  property string layoutError: ""
  readonly property var effectiveLook: fallbackPreset ? Layout.preset(fallbackPreset) : look
  readonly property var placed: effectiveLook.elements

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
  readonly property color glassBase: themeLock("background", Commons.Color.lock.background, Qt.rgba(0.025, 0.035, 0.065, 0.34))
  // The look's glass opacity scales the theme's (or default) glass alpha.
  readonly property color glass: Qt.rgba(glassBase.r, glassBase.g, glassBase.b, glassBase.a * effectiveLook.glass.opacity)
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
  // The geometry check replaced the look: `error` is the reason, `preset` the
  // one now shown.
  signal layoutFellBack(string error, string preset)

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

  // Layout: each element sits in its zone, stacked by order. The zone rules
  // reproduce the 1.2.0 positions for the foamy preset (tests/harness parity).
  readonly property real zoneGap: Math.round(14 * uiScale)

  function elementItem(name) {
    switch (name) {
    case "date": return dateLabel
    case "clock": return clockLabel
    case "account": return identityBlock
    case "password": return inputField
    case "media": return mediaRow
    case "status": return statusFooter
    }
    return null
  }

  function elementShown(name) {
    var item = placed[name]
    if (!item || item.hidden) return name === "password"
    if (name === "account") return showUserInfo && primary
    if (name === "media") return hasMedia
    return true
  }

  function shownMap() {
    var shown = {}
    for (var i = 0; i < Layout.ELEMENTS.length; i++) shown[Layout.ELEMENTS[i]] = elementShown(Layout.ELEMENTS[i])
    return shown
  }

  // Logical alignment inside the element: mirroring flips it with the text.
  function elementAlignment(name) {
    var column = Layout.zoneColumn(placed[name].zone)
    return column === "center" ? "center" : column
  }

  function gapBefore(name) {
    var item = elementItem(name)
    return item && item.stackGap !== undefined ? item.stackGap : zoneGap
  }

  // The zone's stack as `self` sees it: an element always counts itself, so a
  // hidden one keeps the place it would take (as the 1.2.0 anchors did).
  function zoneStack(zone, self) {
    var shown = shownMap()
    if (self) shown[self] = true
    return Layout.stack(placed, zone, shown)
  }

  function stackHeight(zone, self) {
    var names = zoneStack(zone, self)
    var total = 0
    for (var i = 0; i < names.length; i++) total += (i > 0 ? gapBefore(names[i]) : 0) + elementItem(names[i]).height
    return total
  }

  function offsetInZone(name) {
    var names = zoneStack(placed[name].zone, name)
    var offset = 0
    for (var i = 0; i < names.length && names[i] !== name; i++)
      offset += elementItem(names[i]).height + gapBefore(names[i + 1])
    return offset
  }

  function edgeMargin(row) {
    return Math.round((row === "top" ? 24 : row === "middle" ? 64 : 32) * uiScale)
  }

  function placeX(name, itemWidth) {
    var zone = placed[name].zone
    var row = Layout.zoneRow(zone)
    var column = Layout.screenColumn(zone, rightToLeft)
    // Narrow screens stack the bottom corners under the field.
    if (column === "center" || (row === "bottom" && compactLayout)) {
      return column === "center" ? (width - itemWidth) / 2 : Math.round((width - itemWidth) / 2)
    }
    return column === "start" ? edgeMargin(row) : width - itemWidth - edgeMargin(row)
  }

  function placeY(name) {
    var zone = placed[name].zone
    var row = Layout.zoneRow(zone)
    var center = Layout.zoneColumn(zone) === "center"
    var total = stackHeight(zone, name)
    var top
    if (row === "top") top = center ? Math.max(Math.round(42 * uiScale), Math.round(height * 0.09)) : edgeMargin(row)
    else if (row === "middle") top = Math.round((height - total) / 2)
    else if (center) top = Math.min(height * 0.65, height - total - bottomReserve())
    else if (!compactLayout || Layout.zoneColumn(zone) === "start") top = height - edgeMargin(row) - total
    else {
      // Narrow: the end zone sits above the start zone, both centred.
      var below = stackHeight("bottom-start")
      top = height - edgeMargin(row) - (below > 0 ? below + 2 * zoneGap : 0) - total
    }
    return top + offsetInZone(name)
  }

  // The space the bottom-center stack keeps free below it. Narrow screens
  // stack the bottom corners under it (1.2.0 reserved 140 for the media card).
  function bottomReserve() {
    if (!compactLayout) return 36 * uiScale
    var start = stackHeight("bottom-start")
    var end = stackHeight("bottom-end")
    var corners = start + end + (start > 0 && end > 0 ? 2 * zoneGap : 0)
    return Math.max(140 * uiScale, corners > 0 ? corners + edgeMargin("bottom") + zoneGap : 0)
  }

  // Full content width in the center column, natural width at the sides.
  function textWidth(name, naturalWidth) {
    return Layout.zoneColumn(placed[name].zone) === "center" ? contentWidth : Math.min(contentWidth, naturalWidth)
  }

  function rectOf(item) {
    return { x: item.x, y: item.y, width: item.width, height: item.height }
  }

  // The field must be on screen and uncovered; otherwise fall back a stage.
  function checkGeometry() {
    // Nothing to judge before the surface has its size.
    if (!(width > 0 && height > 0)) return
    var others = []
    for (var i = 0; i < Layout.ELEMENTS.length; i++) {
      var name = Layout.ELEMENTS[i]
      if (name !== "password" && elementShown(name)) others.push(rectOf(elementItem(name)))
    }
    var error = Layout.geometryError(rectOf(inputField), others, width, height, Math.round(4 * uiScale))
    if (!error) return
    // The user's look falls back to plain foamy (unless it is plain foamy),
    // then to the field-only layout, then nothing more.
    var next
    if (!fallbackPreset) {
      var plainFoamy = JSON.stringify(look) === JSON.stringify(Layout.defaults())
      next = plainFoamy ? Layout.FALLBACK_PRESET : Layout.DEFAULT_PRESET
    } else next = Layout.fallbackAfter(fallbackPreset)
    if (!next) return
    layoutError = error
    fallbackPreset = next
    layoutFellBack(error, next)
    Qt.callLater(forcePasswordFocus)
  }

  // Everything the check depends on; any change re-arms the debounce.
  readonly property string geometryKey: [width, height, inputField.x, inputField.y, inputField.width,
    inputField.height, dateLabel.x, dateLabel.y, dateLabel.height, clockLabel.y, clockLabel.height,
    identityBlock.y, identityBlock.height, mediaRow.x, mediaRow.y, statusFooter.x, statusFooter.width,
    JSON.stringify(shownMap())].join(",")
  onGeometryKeyChanged: geometryTimer.restart()
  onLookChanged: {
    fallbackPreset = ""
    layoutError = ""
  }

  Timer {
    id: geometryTimer
    interval: 300
    onTriggered: root.checkGeometry()
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

    // The theme's background colour (above) shows for source "theme", and
    // while no image is available.
    Rectangle {
      objectName: "blackBackground"
      anchors.fill: parent
      visible: root.effectiveLook.background.source === "black"
      color: Qt.rgba(0, 0, 0, 1)
    }

    Image {
      id: wallpaper
      objectName: "lockWallpaper"
      anchors.fill: parent
      readonly property bool wanted: ["omarchy", "picture"].indexOf(root.effectiveLook.background.source) !== -1
      source: wanted && root.loadBackground && width > 0 && height > 0 ? root.fileUrl(root.backgroundPath, root.backgroundVersion) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      sourceSize.width: width
      sourceSize.height: height
      // Blur needs a GPU renderer (DESIGN.md "Effects"); under the software
      // renderer the wallpaper stays sharp and the dim still applies.
      readonly property real blurAmount: root.backgroundPrepared ? 0 : root.effectiveLook.background.blur
      layer.enabled: blurAmount > 0 && GraphicsInfo.api !== GraphicsInfo.Software
      layer.effect: MultiEffect {
        blurEnabled: true
        blur: wallpaper.blurAmount
        blurMax: 64
        autoPaddingEnabled: false
      }
    }

    // A scrim keeps white type legible; 0.25 (the default) preserves
    // wallpaper detail. The look's `dim` sets it, but an underline or dots
    // field has no surface of its own, so it keeps at least 0.15 behind it.
    Rectangle {
      objectName: "scrim"
      anchors.fill: parent
      color: Qt.rgba(0.005, 0.01, 0.025, Math.max(root.effectiveLook.background.dim,
        ["underline", "dots"].indexOf(root.placed.password.style) !== -1 ? 0.15 : 0))
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

    DateElement {
      id: dateLabel
      view: root
      styleName: root.placed.date.style
      z: 2
      alignment: root.elementAlignment("date")
      visible: root.elementShown("date")
      width: root.textWidth("date", naturalWidth)
      x: root.placeX("date", width)
      y: root.placeY("date")
    }

    ClockElement {
      id: clockLabel
      view: root
      styleName: root.placed.clock.style
      z: 2
      alignment: root.elementAlignment("clock")
      visible: root.elementShown("clock")
      width: root.textWidth("clock", naturalWidth)
      x: root.placeX("clock", width)
      y: root.placeY("clock")
    }

    AccountElement {
      id: identityBlock
      view: root
      styleName: root.placed.account.style
      alignment: root.elementAlignment("account")
      visible: root.elementShown("account")
      width: chip ? naturalWidth : root.textWidth("account", naturalWidth)
      x: root.placeX("account", width)
      y: root.placeY("account")
    }

    // Always visible: an invisible item can't keep keyboard focus.
    PasswordElement {
      id: inputField
      view: root
      chromeVisible: root.primary
      styleName: root.placed.password.style
      alignment: root.elementAlignment("password")
      x: root.placeX("password", width)
      y: root.placeY("password")
    }

    MediaElement {
      id: mediaRow
      view: root
      styleName: root.placed.media.style
      visible: root.elementShown("media")
      x: root.placeX("media", width)
      y: root.placeY("media")
    }

    StatusElement {
      id: statusFooter
      view: root
      styleName: root.placed.status.style
      visible: root.elementShown("status")
      x: root.placeX("status", width)
      y: root.placeY("status")
    }
  }
}
