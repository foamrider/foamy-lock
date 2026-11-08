import QtQuick
import ".." as Fixture
// elements/sources/KeyboardSource.qml without Hyprland or hyprctl.
Item {
  property bool awake: true
  readonly property string layout: Fixture.Sources.keyboardLayout
  Component.onCompleted: Fixture.Sources.keyboardSources++
  Component.onDestruction: Fixture.Sources.keyboardSources--
}
