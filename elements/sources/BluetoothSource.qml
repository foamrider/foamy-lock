import QtQuick
import Quickshell.Bluetooth

// The default adapter's state and how many devices are connected, for the
// status element's bluetooth item. LockView loads it only while that item
// shows (and only with liveSources); read-only.
Item {
  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property bool available: adapter !== null
  readonly property bool enabled: available && adapter.enabled === true
  readonly property int connected: {
    var devices = Bluetooth.devices ? Bluetooth.devices.values : []
    var count = 0
    for (var i = 0; i < devices.length; i++) if (devices[i] && devices[i].connected === true) count++
    return enabled ? count : 0
  }
}
