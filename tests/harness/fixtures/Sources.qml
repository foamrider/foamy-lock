pragma Singleton
import QtQuick

// Stands in for PipeWire, Bluetooth and the keyboard layout: the fixture
// sources (fixtures/sources) read these, and count how often they are made,
// so a test can check that a source exists only while an item needs it.
QtObject {
  property bool volumeAvailable: true
  property int volumePercent: 64
  property bool volumeMuted: false
  property bool bluetoothAvailable: true
  property bool bluetoothEnabled: true
  property int bluetoothConnected: 2
  // The widest sample: a long layout name.
  property string keyboardLayout: "English (US, intl., with dead keys)"
  property int volumeSources: 0
  property int bluetoothSources: 0
  property int keyboardSources: 0
}
