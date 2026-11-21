import QtQuick

// tests/greeter.sh's MainScript: the theme's real Main.qml at the asked
// size, driven into the asked state and saved as a PNG; tests/greeter.sh
// then stops the greeter (its QML can't quit it). The test's theme.conf
// holds the state (its test* keys, which only tests/greeter.sh writes)
// beside the snapshot. sddm-greeter-qt6
// --test-mode has no last user and no daemon (sddm.login() answers
// nothing), so the account's name is set on the view here, and a refused
// password is SDDM's loginFailed signal, emitted here.
Item {
  id: shot

  readonly property var settings: config
  readonly property var greeter: sddm
  readonly property int shotWidth: Number(settings.testWidth) || 1920
  readonly property int shotHeight: Number(settings.testHeight) || 1080
  readonly property string out: String(settings.testOut || "")
  // Milliseconds from the state to the picture (the Wayland run waits longer).
  readonly property int settle: Number(settings.testSettle) || 1500

  function findNamed(item, name) {
    if (!item)
      return null
    if (item.objectName === name)
      return item
    for (let i = 0; i < item.children.length; i++) {
      const found = findNamed(item.children[i], name)
      if (found)
        return found
    }
    return null
  }

  function drive() {
    const view = findNamed(loader.item as Item, "greeterView")
    if (!view) {
      console.error("GREETER_FAIL no greeterView")
      return
    }
    if (settings.testUser) {
      view.userName = String(settings.testUser)
      view.userDisplayName = String(settings.testRealName || "")
      view.showUserInfo = settings.testShowUser !== "false"
      if (settings.testAvatar)
        view.avatarPath = String(settings.testAvatar)
    }
    if (settings.testFailed === "true") {
      view.passwordTextEdited("wrong password")
      view.submitCurrentPassword()
      // SDDM's own answer, as the daemon sends it.
      shot.greeter.loginFailed()
    } else if (settings.testTyped === "true") {
      view.passwordTextEdited("typed")
    }
    console.log("GREETER_STATE preset=" + view.effectiveLook.preset + " fallback=" + view.fallbackPreset + " primary=" + view.primary + " size=" + view.width + "x" + view.height)
    grabTimer.start()
  }

  Loader {
    id: loader
    width: shot.shotWidth
    height: shot.shotHeight
    source: "Main.qml"
    onStatusChanged: {
      if (status === Loader.Error) {
        console.error("GREETER_FAIL Main.qml did not load")
      }
    }
  }

  // The geometry check settles 300 ms after the last change; then the state.
  Timer {
    interval: 800
    running: loader.status === Loader.Ready
    onTriggered: shot.drive()
  }

  Timer {
    id: grabTimer
    interval: shot.settle
    onTriggered: {
      const main = loader.item as Item
      const view = shot.findNamed(main, "greeterView")
      console.log("GREETER_GEOMETRY problem=" + view.geometryProblemCode + " fallback=" + view.fallbackPreset)
      main.grabToImage(function (result) {
        console.log("GREETER_SHOT " + (result.saveToFile(shot.out) ? "saved " : "FAILED ") + shot.out)
      })
    }
  }
}
