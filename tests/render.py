"""Render LockView with synthetic identity, media, power, and network data only."""
import os
import signal
from pathlib import Path
import shutil
import subprocess
import tempfile
import struct
import importlib.util

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('artwork', source / 'artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)
base = Path(tempfile.mkdtemp(prefix='foamy-lock-render-'))
app = base / 'app'
app.mkdir()
# The view receives only a generated thumbnail, exactly as in production.
pixels = bytes(channel for y in range(256) for x in range(256)
               for channel in (30 + x // 3, 70 + y // 2, 130 + x // 4))
(app / 'artwork.png').write_bytes(artwork.encode_png(pixels))
(app / 'Commons').symlink_to('/usr/share/omarchy/shell/Commons', target_is_directory=True)
shutil.copy(source / 'Model.js', app)
view = (source / 'LockView.qml').read_text()
view = view.replace('import Quickshell.Networking', 'import "fixtures" as Fixture').replace('import Quickshell.Services.UPower\n', '')
view = view.replace('Networking.', 'Fixture.Networking.').replace('NetworkConnectivity.', 'Fixture.Networking.').replace('DeviceType.', 'Fixture.Networking.')
view = view.replace('UPower.', 'Fixture.Power.').replace('UPowerDeviceState.', 'Fixture.Power.')
view = view.replace('lockClock.date', 'new Date(2026, 8, 26, 10, 24)')
(app / 'LockView.qml').write_text(view)
fixtures = app / 'fixtures'
fixtures.mkdir()
(fixtures / 'qmldir').write_text('module Fixture\nsingleton Networking 1.0 Networking.qml\nsingleton Power 1.0 Power.qml\n')
(fixtures / 'Networking.qml').write_text('''pragma Singleton
import QtQuick
QtObject {
  enum State { Full, Portal, Limited, None, Wired }
  property int connectivity: Networking.Full
  property var devices: ({values: []})
}
''')
(fixtures / 'Power.qml').write_text('''pragma Singleton
import QtQuick
QtObject {
  enum State { Charging, FullyCharged, PendingCharge }
  property bool onBattery: true
  property var displayDevice: ({ready: true, isPresent: true, isLaptopBattery: true, percentage: 0.82, state: 0})
}
''')
# This neutral vector wallpaper is test data, not the user's wallpaper.
(app / 'wallpaper.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
<defs><linearGradient id="g" x2="0.9" y2="1"><stop stop-color="#15394f"/><stop offset=".6" stop-color="#24405a"/><stop offset="1" stop-color="#171e3d"/></linearGradient><linearGradient id="w"><stop stop-color="#367782"/><stop offset="1" stop-color="#273356"/></linearGradient></defs>
<path fill="url(#g)" d="M0 0h1920v1080H0z"/><path fill="url(#w)" opacity=".5" d="M0 640C500 300 700 950 1250 500S1760 250 1920 350v730H0z"/><path fill="#49717f" opacity=".18" d="M0 880C550 410 900 1150 1450 760s400-260 470-250v570H0z"/>
</svg>''')
(app / 'shell.qml').write_text('''import QtQuick
import Quickshell
import "fixtures" as Fixture
ShellRoot {
  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 1920; implicitHeight: 1080
    color: "#182638"
    LockView {
      id: view
      width: 1920; height: 1080
      userName: "foamy"
      userDisplayName: "Foamy User"
      avatarPath: ""
      backgroundPath: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
      activePlayer: player
      artworkPath: Qt.resolvedUrl("artwork.png").toString().replace("file://", "")
      fingerprintConfigured: true
      onPasswordTextEdited: function(value) { passwordText = value }
      onClearFailureRequested: failureMessage = ""
    }
    QtObject {
      id: player
      property string trackTitle: "Evening Light"
      property string trackArtist: "Sample Artist"
      property string trackArtUrl: "https://must-not-be-fetched.invalid/original.png"
      property bool isPlaying: true
      property bool canGoPrevious: true
      property bool canGoNext: true
      property bool canTogglePlaying: true
      property bool canPlay: true
      property bool canPause: true
      property int actions: 0
      function previous() { actions++ }
      function next() { actions++ }
      function togglePlaying() { actions++ }
    }
    Timer {
      id: step
      property int index: 0
      interval: 700
      repeat: false
      running: true
      onTriggered: {
        var input = view.children[0] // Locate the editor by objectName below.
        function findNamed(item, name) {
          if (item.objectName === name) return item
          for (var i = 0; i < item.children.length; i++) {
            var found = findNamed(item.children[i], name)
            if (found) return found
          }
          return null
        }
        input = findNamed(view, "passwordInput")
        var artImage = findNamed(view, "artworkImage")
        var fallback = findNamed(view, "artworkFallback")
        if (index < 2 && (artImage.status !== Image.Ready || fallback.visible))
          throw new Error("Validated artwork was not displayed")
        if (index >= 4 && (!fallback.visible || artImage.visible))
          throw new Error("Artwork icon fallback was not displayed")
        if (String(artImage.source).indexOf("https:") === 0)
          throw new Error("Original artwork URL reached the view")
        if (!input || (!view.authenticatingPassword && !input.activeFocus)) throw new Error("Password input lost focus")
        if (index === 1 && input.text !== "example") throw new Error("Password binding did not update")
        if (!view.grabToImage(function(result) {
          if (!result.saveToFile(Qt.resolvedUrl("capture-" + step.index + ".png").toString().replace("file://", "")))
            throw new Error("Screenshot save failed")
          step.index++
          if (step.index === 1) {
            view.width = 800; view.height = 1000
            view.passwordText = "example"
            view.runMediaAction("next")
            if (player.actions !== 1) throw new Error("Media transport did not reach player")
          } else if (step.index === 2) {
            view.width = 1280; view.height = 720
            view.timeFormat = "12h"
            view.passwordText = ""
            view.failureMessage = "Authentication failed (1)"
            view.fingerprintConfigured = false
            view.activePlayer = null
            Fixture.Networking.connectivity = Fixture.Networking.None
          } else if (step.index === 3) {
            view.showUserInfo = false
            view.failureMessage = ""
            view.authenticatingPassword = true
            Fixture.Power.displayDevice = null
          } else if (step.index === 4) {
            view.width = 1920; view.height = 1080
            view.activePlayer = player
            view.showUserInfo = true
            view.authenticatingPassword = false
            view.artworkPath = ""
          } else if (step.index === 5) {
            view.width = 800; view.height = 1000
            view.artworkPath = Qt.resolvedUrl("missing-thumbnail.png").toString().replace("file://", "")
          } else {
            console.log("PASS: wide/narrow artwork, empty/error icon fallback, media action, password focus/binding, failure, busy, hidden identity, no media/battery")
            Qt.quit()
            return
          }
          step.restart()
        })) throw new Error("Screenshot capture failed")
      }
    }
  }
}
''')
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
home = base / 'home'
home.mkdir()
env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen',
           QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', LC_TIME='en_US.UTF-8')
env.pop('DISPLAY', None)
env.pop('WAYLAND_DISPLAY', None)
log_path = base / 'render.log'
with log_path.open('w') as log:
    process = subprocess.Popen(['dbus-run-session', '--', 'quickshell', '-p', str(app), '--no-color'],
                               env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        print(log_path.read_text())
        raise
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
output = log_path.read_text()
print(output)
assert process.returncode == 0 and 'PASS:' in output, output
for i, size in enumerate([(1920, 1080), (800, 1000), (1280, 720), (1280, 720), (1920, 1080), (800, 1000)]):
    image = (app / f'capture-{i}.png').read_bytes()
    assert struct.unpack('>II', image[16:24]) == size
print('Renders:', app)
