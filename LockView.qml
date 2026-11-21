import QtQuick
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Services.UPower
// Qualify the theme singleton to avoid QtQuick.Color taking precedence.
import qs.Commons as Commons
import "kit"
import "elements"

// The lock screen: LockLayout (elements/LockLayout.qml: the look, placed,
// and its background) with the lock's services: the theme's colours from
// Commons, the clock, network and battery (Quickshell), and the status's
// other readings (/proc, and PipeWire, Bluetooth and Hyprland in
// elements/sources). Service.qml, Lock Studio and the tests use this.
LockLayout {
  id: root

  themeBackground: Commons.Color.background
  themeForeground: Commons.Color.foreground
  accent: Commons.Color.accent
  themeMuted: Commons.Color.muted
  themeUrgent: Commons.Color.urgent
  lockBackground: Commons.Color.lock.background
  lockBorder: Commons.Color.lock.border
  lockBorderError: Commons.Color.lock.borderError
  lockPlaceholder: Commons.Color.lock.placeholder
  lockSelection: Commons.Color.lock.selection
  lockText: Commons.Color.lock.text
  lockTextError: Commons.Color.lock.textError
  // Commons.Color.lock.* always has a value (theme foreground and friends);
  // only an explicit [lock] entry replaces the glass look.
  lockThemed: {
    var values = Commons.Color.shellValues || ({})
    var themed = []
    for (const key of ["background", "border", "placeholder", "selection", "text"]) {
      const value = values["lock." + key]
      if (typeof value === "string" && value.length > 0)
        themed.push("lock" + key.charAt(0).toUpperCase() + key.slice(1))
    }
    return themed
  }
  // Omarchy's animations switch (reduced motion, CPU rendering).
  reduceMotion: Commons.Style.reduceMotion === true
  onBattery: UPower.onBattery
  // The clock and date read this; the render harness replaces lockClock.date.
  now: lockClock.date

  readonly property var batteryDevice: UPower.displayDevice
  readonly property bool hasBattery: batteryDevice && batteryDevice.ready && batteryDevice.isPresent && batteryDevice.isLaptopBattery
  readonly property int batteryPercentage: hasBattery ? Math.round(Number(batteryDevice.percentage || 0) * 100) : 0
  readonly property bool wiredConnected: hasConnectedDevice(DeviceType.Wired)
  readonly property string networkLabel: networkStatusLabel()
  readonly property string networkIcon: wiredConnected ? "\u{ef09}" : (networkLabel === "Offline" ? "\u{f092e}" : "\u{f1eb}")

  // The status element's readings beyond network and battery. Each source
  // runs only while the status shows an item that needs it (status.items,
  // or the "system" style's own rows); nothing is read or kept otherwise.
  // Every reading is a plain property here, so a host (Lock Studio) can
  // supply samples instead: with liveSources false the view opens no
  // PipeWire, Bluetooth or Hyprland connection of its own.
  property bool liveSources: true
  // The status is placed and could show (whether or not its items have
  // read anything yet: they read only while this holds).
  readonly property bool statusLive: !placed.status.hidden && (placed.status.screens !== "primary" || primary) && visible && loadBackground
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

  function networkStatusLabel() {
    if (Networking.connectivity === NetworkConnectivity.Full)
      return "Connected"
    if (Networking.connectivity === NetworkConnectivity.Portal)
      return "Sign-in required"
    if (Networking.connectivity === NetworkConnectivity.Limited)
      return "Limited connection"
    if (Networking.connectivity === NetworkConnectivity.None)
      return "Offline"

    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].connected)
        return "Connected"
    }
    return "Offline"
  }

  function hasConnectedDevice(deviceType) {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].type === deviceType && devices[i].connected)
        return true
    }
    return false
  }

  function batteryIcon(level) {
    var device = root.batteryDevice
    if (!device)
      return ""

    var index = Math.max(0, Math.min(9, Math.floor(level / 10)))
    var chargingIcons = ["\u{f089c}", "\u{f0086}", "\u{f0087}", "\u{f0088}", "\u{f089d}", "\u{f0089}", "\u{f089e}", "\u{f008a}", "\u{f008b}", "\u{f0085}"]
    var defaultIcons = ["\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}", "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}"]

    if (!UPower.onBattery && device.state === UPowerDeviceState.Charging)
      return chargingIcons[index]
    if (!UPower.onBattery && (device.state === UPowerDeviceState.FullyCharged || device.state === UPowerDeviceState.PendingCharge))
      return "\u{f17e2}"
    return defaultIcons[index]
  }

  onUptimeListedChanged: if (!uptimeListed)
    systemUptime = -1
  onLoadListedChanged: if (!loadListed)
    systemLoad = ""
  onMemoryListedChanged: {
    if (memoryListed)
      return
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
      if (root.uptimeWanted)
        uptimeFile.reload()
      if (root.loadWanted)
        loadFile.reload()
      if (root.memoryWanted)
        memoryFile.reload()
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

  FoamyWallClock {
    id: lockClock
  }
}
