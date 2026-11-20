import QtQuick

// Stands in for Quickshell.Wayland's IdleMonitor (ext-idle-notify): the test
// sets isIdle as the compositor would report input. Like the real monitor, a
// disabled one reports no idle state.
QtObject {
  property bool enabled: true
  property real timeout: 0
  property bool respectInhibitors: true
  property bool isIdle: false
  onEnabledChanged: if (!enabled)
    isIdle = false
}
