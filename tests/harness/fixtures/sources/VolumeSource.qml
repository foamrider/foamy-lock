import QtQuick
import ".." as Fixture
// elements/sources/VolumeSource.qml without PipeWire.
Item {
  readonly property bool available: Fixture.Sources.volumeAvailable
  readonly property int percent: Fixture.Sources.volumePercent
  readonly property bool muted: Fixture.Sources.volumeMuted
  Component.onCompleted: Fixture.Sources.volumeSources++
  Component.onDestruction: Fixture.Sources.volumeSources--
}
