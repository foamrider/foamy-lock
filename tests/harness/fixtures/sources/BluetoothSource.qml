import QtQuick
import ".." as Fixture
// elements/sources/BluetoothSource.qml without Bluetooth.
Item {
  readonly property bool available: Fixture.Sources.bluetoothAvailable
  readonly property bool enabled: Fixture.Sources.bluetoothEnabled
  readonly property int connected: Fixture.Sources.bluetoothConnected
  Component.onCompleted: Fixture.Sources.bluetoothSources++
  Component.onDestruction: Fixture.Sources.bluetoothSources--
}
