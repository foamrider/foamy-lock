//@ pragma AppId foamy-lock-studio
import QtQuick
import Quickshell
import Quickshell.Io
import "kit"

// Lock Studio: a desktop app for designing the Foamy lock screen. Its own
// Quickshell process, started by `foamy-lock-helper studio` from a root it
// builds outside the plugin folder (links to these files, the lock's
// LockView, elements, kit, i18n and Omarchy's Commons); see
// native/src/studio/root.rs.
ShellRoot {
  id: app

  FloatingWindow {
    id: window
    title: FoamyI18n.t("studio.title")
    implicitWidth: 1440
    implicitHeight: 900
    minimumSize: Qt.size(1100, 680)
    color: FoamyPalette.background
    visible: true

    StudioWindow {
      id: studio
      anchors.fill: parent
      focus: true
      awake: window.visible && !window.minimized
      onQuitRequested: Qt.quit()
    }
  }

  // A second `foamy-lock-helper studio` raises this window instead of
  // starting another app (`quickshell ipc -p <root> call studio raise`).
  // Not the Omarchy shell's IPC: this is the app's own Quickshell instance,
  // so FoamyIpc and its registry don't apply.
  IpcHandler { // foamy-lint: allow raw-ipc — the studio's own Quickshell process, outside the Omarchy shell
    target: "studio"

    function raise(): string {
      window.minimized = false
      window.visible = true
      studio.Window.window?.requestActivate()
      studio.forceActiveFocus()
      return "raised"
    }
  }

  // The offscreen test harness (tests/harness `studio`) adds StudioTest.qml
  // to its own root and sets this; a root built by the helper has neither.
  Loader {
    id: testDriver
    Component.onCompleted: {
      if (Quickshell.env("FOAMY_LOCK_STUDIO_TEST") === "1")
        testDriver.setSource("StudioTest.qml", { window: window, studio: studio })
    }
  }
}
