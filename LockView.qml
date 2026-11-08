import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
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
  // The password field's "Enter password to unlock" (false in the preview
  // overlay, which isn't a lock).
  property bool showUnlockHint: true
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
  // False while the service has blanked the display: nothing moves then.
  property bool displayAwake: true
  // A video background's clip: "" without one (Service sets it only to a
  // clip the helper converted for this file and screen size). It plays
  // (elements/VideoBackdrop.qml, over the poster that backgroundPath shows)
  // only with motion "play" and GPU rendering, and holds its frame while
  // the display is blanked, the view hidden, motion reduced or, with
  // pauseOnBattery, on battery. The first error or a 2 s stall gives up
  // for the rest of this view's lock (a hidden preview tries again).
  property string videoPath: ""
  // GPU rendering; the offscreen tests set it, as they render in software.
  property bool gpuRendering: GraphicsInfo.api !== GraphicsInfo.Software
  property bool onBattery: UPower.onBattery
  property bool videoGaveUp: false
  property string videoFailure: ""
  readonly property bool videoWanted: videoPath !== "" && loadBackground && gpuRendering && !videoGaveUp
    && Layout.playsVideo(effectiveLook.background)
    && ["omarchy", "picture"].indexOf(effectiveLook.background.source) !== -1
  readonly property bool videoPlaying: videoWanted && visible && displayAwake && !reduceMotion
    && !(onBattery && Layout.pausesOnBattery(effectiveLook.background))
  readonly property bool videoShown: videoLoader.status === Loader.Ready && videoLoader.item !== null
    && videoLoader.item.frameSeen
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
  // The centre column at the view's own scale; an element uses contentWidthAt(its scale).
  readonly property real contentWidth: contentWidthAt(uiScale)
  readonly property color foreground: themeLock("text", Commons.Color.lock.text, Qt.rgba(0.98, 0.98, 1, 0.96))
  readonly property color secondary: themeLock("placeholder", Commons.Color.lock.placeholder, Qt.rgba(0.94, 0.95, 1, 0.68))
  readonly property color glassBase: themeLock("background", Commons.Color.lock.background, Qt.rgba(0.025, 0.035, 0.065, 0.34))
  readonly property color accent: Commons.Color.accent
  // The look's glass: "none" keeps the white glass, "accent" draws the edges
  // in the theme accent over a darker glass, "solid" makes it opaque without
  // edges. The opacity scales the theme's (or default) glass alpha.
  readonly property string glassTint: effectiveLook.glass.tint || "none"
  readonly property color glass: glassAt(effectiveLook.glass.opacity)
  // Free placement: false only reports geometry problems (geometryProblemCode)
  // instead of falling back, for an editor; the lock always latches.
  property bool latchFallback: true
  // The last geometry check's result: "" or a code (see Layout.lookGeometryError).
  property string geometryProblemCode: ""
  readonly property color glassEdge: themeLock("border", Commons.Color.lock.border, Qt.rgba(0.95, 0.96, 1, 0.18))
  readonly property color glassBorder: glassTint === "accent" ? Qt.rgba(accent.r, accent.g, accent.b, 0.9)
    : glassTint === "solid" ? Qt.rgba(glassEdge.r, glassEdge.g, glassEdge.b, 0) : glassEdge
  // Drawn lines (the outline clock): the accent with the accent tint.
  readonly property color lineColor: glassTint === "accent" ? accent : foreground
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
  // Omarchy's animations switch (reduced motion, CPU rendering); 4.0 has none.
  readonly property bool reduceMotion: Commons.Style.reduceMotion === true
  // A drawn background moves only while it can be seen: the view is shown,
  // the display awake, animations on and the GPU renders.
  readonly property bool motionAllowed: visible && loadBackground && displayAwake && !reduceMotion
    && GraphicsInfo.api !== GraphicsInfo.Software
  readonly property Item wallpaperItem: wallpaper
  // The background is a picture (the Omarchy wallpaper or a chosen one).
  readonly property bool pictureBackground: ["omarchy", "picture"].indexOf(effectiveLook.background.source) !== -1

  // The status element's readings beyond network and battery. Each source
  // runs only while the status shows an item that needs it (status.items,
  // or the "system" style's own rows); nothing is read or kept otherwise.
  // Every reading is a plain property here, so a host (Lock Studio) can
  // supply samples instead: with liveSources false the view opens no
  // PipeWire, Bluetooth or Hyprland connection of its own.
  property bool liveSources: true
  // The status is placed and could show (whether or not its items have
  // read anything yet: they read only while this holds).
  readonly property bool statusLive: !placed.status.hidden && (placed.status.screens !== "primary" || primary)
    && visible && loadBackground
  // /proc, read every few seconds while awake; procRoot is for the tests.
  property string procRoot: "/proc"
  // Listed: the status shows the reading. Wanted: it is also read now. A
  // reading is cleared only when it stops being listed, so a display that
  // sleeps (or Lock Studio's window losing focus) keeps the last value
  // instead of dropping the item.
  readonly property bool uptimeListed: statusLive && statusShows("uptime")
  readonly property bool loadListed: statusLive && statusShows("load")
  readonly property bool memoryListed: statusLive && statusShows("memory")
  readonly property bool uptimeWanted: uptimeListed && displayAwake
  readonly property bool loadWanted: loadListed && displayAwake
  readonly property bool memoryWanted: memoryListed && displayAwake
  readonly property bool systemShown: uptimeWanted || loadWanted || memoryWanted
  property real systemUptime: -1
  property string systemLoad: ""
  property real memoryTotal: 0
  property real memoryAvailable: 0
  // The default sink (PipeWire), read-only.
  readonly property bool volumeWanted: liveSources && statusLive && statusShows("volume")
  property bool hasVolume: volumeLoader.item ? volumeLoader.item.available : false
  property int volumePercent: volumeLoader.item ? volumeLoader.item.percent : 0
  property bool volumeMuted: volumeLoader.item ? volumeLoader.item.muted : false
  // The default adapter (Quickshell.Bluetooth), read-only.
  readonly property bool bluetoothWanted: liveSources && statusLive && statusShows("bluetooth")
  property bool hasBluetooth: bluetoothLoader.item ? bluetoothLoader.item.available : false
  property bool bluetoothEnabled: bluetoothLoader.item ? bluetoothLoader.item.enabled : false
  property int bluetoothConnected: bluetoothLoader.item ? bluetoothLoader.item.connected : 0
  // The active keyboard layout's name ("" until known), from Hyprland.
  readonly property bool keyboardWanted: liveSources && statusLive && statusShows("keyboard")
  property string keyboardLayout: keyboardLoader.item ? keyboardLoader.item.layout : ""
  // The current weather, checked (Model.parseWeather's weather) and fresh,
  // or null: the weather element shows only with one. The service fetches
  // it from Foamy Weather; Lock Studio supplies a sample.
  property var weather: null

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  signal artworkFailed(string path)
  // The geometry check replaced the look: `error` is the reason, `preset` the
  // one now shown.
  signal layoutFellBack(string error, string preset)
  // The clip failed ("error" or "stall"); the poster stays.
  signal videoFailed(string reason)

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
    case "weather": return weatherBlock
    case "calendar": return calendarBlock
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
    // "primary": only on the screen that gets the keys (see `primary`).
    if (item.screens === "primary" && !primary) return false
    if (name === "account") return showUserInfo && primary
    if (name === "media") return hasMedia
    if (name === "weather") return weather !== null && weather !== undefined
    // Items whose sources have nothing yet leave the status empty.
    if (name === "status") return statusFooter.hasContent
    return true
  }

  // Whether the status reads `item`: one of its items, or one of the
  // "system" style's own rows without them.
  function statusShows(item) {
    var status = placed.status
    if (status.items) return status.items.indexOf(item) !== -1
    return status.style === "system" && ["uptime", "memory", "load"].indexOf(item) !== -1
  }

  // The ISO week number of a date (the date's "week" style).
  function weekOf(date) {
    return Model.isoWeek(date).week
  }

  // A MET symbol code's icon group (the weather element's icons).
  function weatherGroup(code) {
    return Model.weatherGroup(code)
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
    return zoneX(name, itemWidth) + offsetX(name)
  }

  // Where the zone puts the element, before its offset.
  function zoneX(name, itemWidth) {
    var zone = placed[name].zone
    var row = Layout.zoneRow(zone)
    var column = Layout.screenColumn(zone, rightToLeft)
    // Narrow screens put the middle row's end zone under its start zone.
    if (row === "middle" && Layout.zoneColumn(zone) === "end" && middleStacked())
      column = rightToLeft ? "end" : "start"
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
    else if (row === "middle" && !center && middleStacked()) {
      var own = Layout.zoneColumn(zone)
      var above = stackHeight("middle-start", own === "start" ? name : undefined)
      var first = Math.round((height - above - 2 * zoneGap - stackHeight("middle-end", own === "end" ? name : undefined)) / 2)
      top = own === "start" ? first : first + above + 2 * zoneGap
    } else if (row === "middle") top = Math.round((height - total) / 2)
    else if (center && bottomBand)
      top = height - total - (compactLayout ? bottomReserve() : edgeMargin(row))
    else if (center) top = Math.min(height * 0.65, height - total - bottomReserve())
    else if (!compactLayout || Layout.zoneColumn(zone) === "start") top = height - edgeMargin(row) - total
    else {
      // Narrow: the end zone sits above the start zone, both centred.
      var below = stackHeight("bottom-start")
      top = height - edgeMargin(row) - (below > 0 ? below + 2 * zoneGap : 0) - total
    }
    return top + offsetInZone(name) + offsetY(name)
  }

  // Narrow screens with both middle side zones in use stack them, the start
  // zone above, both at the start edge (side by side they could collide).
  function middleStacked() {
    return compactLayout && stackHeight("middle-start") > 0 && stackHeight("middle-end") > 0
  }

  // The part of an element that draws: text centred in the full-width
  // center column is narrower than its item.
  function drawnRect(name) {
    var item = elementItem(name)
    var w = item.width
    if (item.naturalWidth !== undefined && Layout.zoneColumn(placed[name].zone) === "center")
      w = Math.min(item.width, Math.ceil(item.naturalWidth))
    return { x: item.x + (item.width - w) / 2, y: item.y, width: w, height: item.height }
  }

  // The drawn rectangle where the zone puts it, without its offset: what the
  // decorations fit and the zone keeps.
  function reservedRect(name) {
    var r = drawnRect(name)
    return { x: r.x - offsetX(name), y: r.y - offsetY(name), width: r.width, height: r.height }
  }

  // The union of the shown elements' reserved (un-offset) rectangles in
  // `zones`, or null (what a zone shape wraps; see shapeGeometry).
  function zonesRect(zones) {
    var shown = shownMap()
    var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
    for (var i = 0; i < Layout.ELEMENTS.length; i++) {
      var name = Layout.ELEMENTS[i]
      if (!shown[name] || zones.indexOf(placed[name].zone) === -1) continue
      var r = reservedRect(name)
      left = Math.min(left, r.x); top = Math.min(top, r.y)
      right = Math.max(right, r.x + r.width); bottom = Math.max(bottom, r.y + r.height)
    }
    return left === Infinity ? null : { x: left, y: top, width: right - left, height: bottom - top }
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

  // An element's scale: the view's, for its screen, times the look's.
  function elementScale(name) {
    var scale = placed[name].scale
    return uiScale * (scale === undefined ? 1 : scale)
  }

  function elementOpacity(name) {
    var opacity = placed[name].opacity
    return opacity === undefined ? 1 : opacity
  }

  // The opacity of an element's glass surface: its own, or the look's.
  function elementGlass(name) {
    var glassOpacity = placed[name].glass
    return glassOpacity === undefined ? effectiveLook.glass.opacity : glassOpacity
  }

  // The glass colour at `opacity` (which scales the theme's or the default
  // glass alpha), in the look's tint.
  function glassAt(opacity) {
    if (glassTint === "solid") return Qt.rgba(glassBase.r, glassBase.g, glassBase.b, Math.min(1, 0.9 * opacity))
    if (glassTint === "accent")
      return Qt.rgba(glassBase.r * 0.9 + accent.r * 0.1, glassBase.g * 0.9 + accent.g * 0.1, glassBase.b * 0.9 + accent.b * 0.1,
        Math.max(glassBase.a, 0.55) * opacity)
    return Qt.rgba(glassBase.r, glassBase.g, glassBase.b, glassBase.a * opacity)
  }

  // An element's move from its zone position, in pixels: a fraction of the
  // screen, x mirrored in right-to-left languages like start and end.
  function offsetX(name) {
    var offset = placed[name].offset
    return offset ? Math.round(offset.x * width) * (rightToLeft ? -1 : 1) : 0
  }

  function offsetY(name) {
    var offset = placed[name].offset
    return offset ? Math.round(offset.y * height) : 0
  }

  // The centre column's width for an element at `scale`: it grows with the
  // element, but never past the screen less its margins.
  function contentWidthAt(scale) {
    return Math.min(Math.round(560 * scale), width - Math.round(64 * uiScale))
  }

  // Full content width in the center column, natural width at the sides.
  function textWidth(name, naturalWidth) {
    var limit = contentWidthAt(elementScale(name))
    return Layout.zoneColumn(placed[name].zone) === "center" ? limit : Math.min(limit, naturalWidth)
  }

  // Each shown element's drawn rectangle, by name (for an editor's overlay
  // and the geometry check).
  function shownRects() {
    var rects = {}
    var shown = shownMap()
    for (var i = 0; i < Layout.ELEMENTS.length; i++) {
      var name = Layout.ELEMENTS[i]
      if (shown[name]) rects[name] = drawnRect(name)
    }
    return rects
  }
  readonly property var elementRects: shownRects()

  // --- shapes (Layout.js "shapes"; drawn by elements/Decoration.qml) -------
  // The bottom-center stack drops into a bottom band: from the look's data
  // alone, never from the shapes' geometry.
  readonly property bool bottomBand: Layout.bottomBand(effectiveLook.background.shapes)
  // Each shown element for the shapes: its zone and style, where it is
  // drawn (elementRects) and where its zone puts it (reserved: without the
  // offset), its surface's corner radius (-1 without one) and its glass.
  function shapeFrame() {
    var elements = {}
    var rects = elementRects
    for (var name in rects) {
      var r = rects[name]
      var item = elementItem(name)
      var dx = offsetX(name), dy = offsetY(name)
      elements[name] = { zone: placed[name].zone, style: placed[name].style, drawn: r,
        reserved: { x: r.x - dx, y: r.y - dy, width: r.width, height: r.height },
        radius: item.surfaceRadius !== undefined ? item.surfaceRadius : -1, glass: elementGlass(name) }
    }
    return { width: width, height: height, uiScale: uiScale, rightToLeft: rightToLeft, compact: compactLayout,
      middleStacked: middleStacked(), tint: glassTint, glass: effectiveLook.glass.opacity, elements: elements }
  }
  // The shapes' geometry (Layout.shapeRects): one binding over the element
  // rectangles, so a shape around modules follows an offset, a scale and
  // content that arrives late, in the same frame. Elements never read it.
  readonly property var shapeGeometry: width > 0 && height > 0
    ? Layout.shapeRects(effectiveLook.background.shapes, shapeFrame()) : []
  // The modules a shape is the background of (`absorb`): from the data and
  // what is shown, so their own surface goes without reading geometry.
  readonly property var absorbed: {
    var shown = {}
    var map = shownMap()
    for (var i = 0; i < Layout.ELEMENTS.length; i++) {
      var name = Layout.ELEMENTS[i]
      if (map[name]) shown[name] = { zone: placed[name].zone, style: placed[name].style }
    }
    return Layout.absorbedModules(effectiveLook.background.shapes, shown,
      { compact: compactLayout, middleStacked: middleStacked() })
  }
  // Whether an element draws its own surface (false under an absorbing shape).
  function surfaceShown(name) {
    return absorbed[name] !== true
  }

  // What is wrong with the geometry shown: "" or a code. The field must be
  // on screen, below the top third and uncovered; every element on screen;
  // and elements in different zones (or moved by an offset) apart. Pure: it
  // changes nothing.
  function geometryProblem() {
    // Nothing to judge before the surface has its size.
    if (!(width > 0 && height > 0)) return ""
    return Layout.lookGeometryError(placed, shownRects(), width, height, Math.round(4 * uiScale))
  }

  // Check the geometry and, unless only reporting (latchFallback false),
  // fall back a stage on a problem.
  function checkGeometry() {
    if (!(width > 0 && height > 0)) return
    var error = geometryProblem()
    geometryProblemCode = error
    if (!error || !latchFallback) return
    // The user's look falls back to plain foamy (unless it is plain foamy),
    // then to the field-only layout, then nothing more.
    var next
    if (!fallbackPreset) {
      var plainFoamy = JSON.stringify(Layout.canonical(look)) === JSON.stringify(Layout.defaults())
      next = plainFoamy ? Layout.FALLBACK_PRESET : Layout.DEFAULT_PRESET
    } else next = Layout.fallbackAfter(fallbackPreset)
    if (!next) return
    layoutError = error
    fallbackPreset = next
    layoutFellBack(error, next)
    Qt.callLater(forcePasswordFocus)
  }

  // Everything the check depends on (every shown element's rectangle, so an
  // offset or scale alone counts); any change re-arms the debounce.
  readonly property string geometryKey: [width, height, JSON.stringify(elementRects)].join(",")
  onGeometryKeyChanged: geometryTimer.restart()
  onLookChanged: {
    fallbackPreset = ""
    layoutError = ""
  }

  onUptimeListedChanged: if (!uptimeListed) systemUptime = -1
  onLoadListedChanged: if (!loadListed) systemLoad = ""
  onMemoryListedChanged: {
    if (memoryListed) return
    memoryTotal = 0
    memoryAvailable = 0
  }

  FileView {
    id: uptimeFile
    path: root.uptimeWanted ? root.procRoot + "/uptime" : ""
    printErrors: false
    onLoaded: root.systemUptime = Number(String(text()).split(" ")[0])
  }

  FileView {
    id: loadFile
    path: root.loadWanted ? root.procRoot + "/loadavg" : ""
    printErrors: false
    onLoaded: root.systemLoad = String(text()).split(" ").slice(0, 3).join(" ")
  }

  FileView {
    id: memoryFile
    path: root.memoryWanted ? root.procRoot + "/meminfo" : ""
    printErrors: false
    onLoaded: {
      var info = String(text())
      var total = /MemTotal:\s+(\d+)/.exec(info)
      var available = /MemAvailable:\s+(\d+)/.exec(info)
      root.memoryTotal = total ? Number(total[1]) : 0
      root.memoryAvailable = available ? Number(available[1]) : 0
    }
  }

  // A slow refresh, only while a reading shows.
  Timer {
    interval: 5000
    repeat: true
    running: root.systemShown
    onTriggered: {
      if (root.uptimeWanted) uptimeFile.reload()
      if (root.loadWanted) loadFile.reload()
      if (root.memoryWanted) memoryFile.reload()
    }
  }

  // The other sources, created only while an item needs them (see
  // liveSources). Their files hold the only PipeWire, Bluetooth and Hyprland
  // imports, so a lock without these items never loads those modules.
  Loader {
    id: volumeLoader
    active: root.volumeWanted
    source: "elements/sources/VolumeSource.qml"
  }

  Loader {
    id: bluetoothLoader
    active: root.bluetoothWanted
    source: "elements/sources/BluetoothSource.qml"
  }

  Loader {
    id: keyboardLoader
    active: root.keyboardWanted
    source: "elements/sources/KeyboardSource.qml"
  }

  Binding {
    target: keyboardLoader.item
    property: "awake"
    value: root.displayAwake
    when: keyboardLoader.item !== null
  }

  Timer {
    id: geometryTimer
    interval: 300
    onTriggered: root.checkGeometry()
  }

  // A preview overlay that is hidden may try the clip again next time.
  onLoadBackgroundChanged: if (!loadBackground) {
    videoGaveUp = false
    videoFailure = ""
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

    // The theme's background colour (above) shows while no image is
    // available. A solid colour source paints its colour over it: a theme
    // colour by name (it follows the theme) or a "#rrggbb" Layout checked.
    Rectangle {
      objectName: "solidBackground"
      anchors.fill: parent
      readonly property string spec: Layout.solidColor(root.effectiveLook.background)
      visible: spec !== ""
      color: spec === "background" ? Commons.Color.background
        : spec === "accent" ? Commons.Color.accent
        : spec === "muted" ? Commons.Color.muted
        : spec === "urgent" ? Commons.Color.urgent
        : spec !== "" ? spec : "transparent"
    }

    Image {
      id: wallpaper
      objectName: "lockWallpaper"
      anchors.fill: parent
      readonly property bool wanted: root.pictureBackground
      source: wanted && root.loadBackground && width > 0 && height > 0 ? root.fileUrl(root.backgroundPath, root.backgroundVersion) : ""
      // Under a playing clip, once its first frame is there.
      visible: !root.videoShown
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

    // A video background's clip over its poster: loaded (with QtMultimedia)
    // only while it may play; see videoPath.
    Loader {
      id: videoLoader
      objectName: "videoLoader"
      anchors.fill: parent
      active: root.videoWanted
      source: "elements/VideoBackdrop.qml"
    }

    Binding {
      target: videoLoader.item
      property: "path"
      value: root.videoPath
      when: videoLoader.item !== null
    }

    Binding {
      target: videoLoader.item
      property: "playing"
      value: root.videoPlaying
      when: videoLoader.item !== null
    }

    Binding {
      target: videoLoader.item
      property: "blur"
      value: wallpaper.blurAmount
      when: videoLoader.item !== null
    }

    Connections {
      target: videoLoader.item
      ignoreUnknownSignals: true
      function onFailed(reason) {
        root.videoFailure = reason
        root.videoGaveUp = true
        root.videoFailed(reason)
      }
    }

    // The drawn sources (the animations), in the theme's colours.
    Backdrop {
      anchors.fill: parent
      view: root
      readonly property string drawn: Layout.drawnSource(root.effectiveLook.background.source)
      visible: drawn !== ""
      source: visible ? drawn : "aurora"
    }

    // A scrim keeps white type legible; 0.25 (the default) preserves
    // wallpaper detail. The look's `dim` sets it, but an underline or dots
    // field has no surface of its own, so it keeps at least 0.15 behind it.
    Rectangle {
      objectName: "scrim"
      anchors.fill: parent
      // The same holds for a field shown only while typing (password.reveal
      // "typing" on a style whose default is "always"; the pill's own
      // "typing" keeps its 1.2.0 scrim).
      color: Qt.rgba(0.005, 0.01, 0.025, Math.max(root.effectiveLook.background.dim,
        ["underline", "dots"].indexOf(root.placed.password.style) !== -1 || root.placed.password.reveal === "typing" ? 0.15 : 0))
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

    // The look's shapes behind the elements (background: never checked
    // against the field, never above it, no input).
    Decoration {
      anchors.fill: parent
      view: root
    }

    DateElement {
      id: dateLabel
      view: root
      uiScale: root.elementScale("date")
      opacity: root.elementOpacity("date")
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
      uiScale: root.elementScale("clock")
      opacity: root.elementOpacity("clock")
      glassOpacity: root.elementGlass("clock")
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
      surfaceShown: root.surfaceShown("account")
      uiScale: root.elementScale("account")
      opacity: root.elementOpacity("account")
      glassOpacity: root.elementGlass("account")
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
      uiScale: root.elementScale("password")
      opacity: root.elementOpacity("password")
      glassOpacity: root.elementGlass("password")
      chromeVisible: root.primary
      styleName: root.placed.password.style
      reveal: Layout.revealOf(root.placed.password)
      alignment: root.elementAlignment("password")
      x: root.placeX("password", width)
      y: root.placeY("password")
    }

    MediaElement {
      id: mediaRow
      view: root
      surfaceShown: root.surfaceShown("media")
      uiScale: root.elementScale("media")
      opacity: root.elementOpacity("media")
      glassOpacity: root.elementGlass("media")
      styleName: root.placed.media.style
      artwork: root.placed.media.artwork !== false
      visible: root.elementShown("media")
      x: root.placeX("media", width)
      y: root.placeY("media")
    }

    CalendarElement {
      id: calendarBlock
      view: root
      surfaceShown: root.surfaceShown("calendar")
      uiScale: root.elementScale("calendar")
      opacity: root.elementOpacity("calendar")
      glassOpacity: root.elementGlass("calendar")
      styleName: root.placed.calendar.style
      alignment: root.elementAlignment("calendar")
      visible: root.elementShown("calendar")
      x: root.placeX("calendar", width)
      y: root.placeY("calendar")
    }

    StatusElement {
      id: statusFooter
      view: root
      surfaceShown: root.surfaceShown("status")
      uiScale: root.elementScale("status")
      opacity: root.elementOpacity("status")
      glassOpacity: root.elementGlass("status")
      styleName: root.placed.status.style
      items: root.placed.status.items || null
      visible: root.elementShown("status")
      x: root.placeX("status", width)
      y: root.placeY("status")
    }

    WeatherElement {
      id: weatherBlock
      view: root
      surfaceShown: root.surfaceShown("weather")
      uiScale: root.elementScale("weather")
      opacity: root.elementOpacity("weather")
      glassOpacity: root.elementGlass("weather")
      styleName: root.placed.weather.style
      details: root.placed.weather.details || "temperature"
      showLocation: root.placed.weather.location === true
      alignment: root.elementAlignment("weather")
      visible: root.elementShown("weather")
      x: root.placeX("weather", width)
      y: root.placeY("weather")
    }
  }
}
