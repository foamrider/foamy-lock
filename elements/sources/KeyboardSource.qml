import QtQuick
import Quickshell.Hyprland
import Quickshell.Io
import "../../Model.js" as Model

// The active keyboard layout, for the status element's keyboard item: a
// password typed in the wrong layout fails, so the lock can say which one is
// active. Read the way Omarchy's KeyboardLayout widget reads it: Hyprland's
// activelayout event, then `hyprctl -j devices` (read only; nothing here
// switches a layout or dispatches anything). LockView loads it only while
// that item shows (and only with liveSources).
Item {
  id: source
  // False while the display is blanked: no retries then.
  property bool awake: true
  // "" until a reading names a layout (the item is left out until then).
  property string layout: ""
  // The keyboard the last activelayout event named.
  property string typedKeyboard: ""
  property bool again: false

  function refresh() {
    if (query.running) {
      again = true
      return
    }
    again = false
    query.running = true
  }

  Component.onCompleted: refresh()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      var named = name === "activelayout" ? Model.eventKeyboardName(event.data) : ""
      if (named) source.typedKeyboard = named
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") source.refresh()
    }
  }

  Process {
    id: query
    command: ["hyprctl", "-j", "devices"]
    onRunningChanged: {
      if (running) {
        stall.restart()
        return
      }
      stall.stop()
      if (source.again) source.refresh()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: source.layout = Model.keyboardLayout(text, source.typedKeyboard)
    }
  }

  // A query that never returns is given up, so the next refresh gets through.
  Timer {
    id: stall
    interval: 5000
    onTriggered: query.running = false
  }

  // Until a first reading lands (hyprctl may not answer at once), ask again.
  Timer {
    interval: 10000
    repeat: true
    running: source.awake && source.layout === ""
    onTriggered: source.refresh()
  }
}
