"""Exercise service settings and lock flow with simulated PAM and compositor boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('artwork', source / 'artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)
commons = Path(os.environ.get('FOAMY_TEST_COMMONS', '/usr/share/omarchy/shell/Commons'))
has_registry = (commons / 'IpcRegistry.qml').exists()
base = Path(tempfile.mkdtemp(prefix='foamy-lock-runtime-'))
app = base / 'app'
app.mkdir()
(app / 'Commons').symlink_to(commons, target_is_directory=True)
# The plugin's stamped kit (FoamyIpc, FoamyI18n) and catalogs, unmodified.
(app / 'kit').symlink_to(source / 'kit', target_is_directory=True)
(app / 'i18n').symlink_to(source / 'i18n', target_is_directory=True)
(app / 'qmldir').write_text('')
shutil.copy(source / 'Model.js', app)
shutil.copy(source / 'FingerprintModel.js', app)
shutil.copy(source / 'Artwork.qml', app)
shutil.copy(source / 'artwork.py', app)
mock = app / 'mocks'
mock.mkdir()
(mock / 'SessionLock.qml').write_text('''import QtQuick
Item {
  property bool locked: false
  property bool secure: false
  signal lockStateChanged()
  signal secureStateChanged()
  onLockedChanged: { secure = locked; lockStateChanged(); secureStateChanged() }
}
''')
(mock / 'PamContext.qml').write_text('''import QtQuick
import Quickshell.Services.Pam
QtObject {
  id: pam
  property string config: ""
  property string user: ""
  property bool active: false
  property bool messageIsError: false
  property int starts: 0
  property bool responseRequired: false
  property int generation: 0
  // Report a failed password through both signals, as one PAM conversation may.
  property bool doubleReport: false
  signal completed(int result)
  signal error(int error)
  signal pamMessage()
  function start() {
    active = true
    starts++
    if (config === "omarchy-lock-fingerprint") return true
    Qt.callLater(function() { if (pam.active) pam.responseRequired = true })
    return true
  }
  function abort() { generation++; active = false; responseRequired = false }
  function respond(value) {
    responseRequired = false
    var attempt = generation
    Qt.callLater(function() {
      if (!pam.active || attempt !== generation) return
      pam.active = false
      if (value !== "test-password" && pam.doubleReport) pam.error(1)
      pam.completed(value === "test-password" ? PamResult.Success : PamResult.Failed)
    })
  }
}
''')
# The real view is exercised separately by render.py; no session-lock surface is created here.
(mock / 'LockView.qml').write_text('''import QtQuick
Item {
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool fingerprintUnavailable: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property var activePlayer: null
  property string artworkPath: ""
  property bool showUserInfo: true
  property string timeFormat: "24h"
  property string passwordText: ""
  property string userName: ""
  property string userDisplayName: ""
  property string avatarPath: ""
  property int avatarVersion: 0
  signal passwordTextEdited(string password)
  signal submitPassword(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  signal artworkFailed(string path)
}
''')
service = (source / 'Service.qml').read_text().replace('import Quickshell.Wayland', 'import "mocks" as Mock')
service = service.replace('  id: root', '  id: root\n  property alias testPasswordPam: passwordPam\n  property alias testFingerprintPam: fingerprintPam\n  property alias testRetry: fingerprintRetryTimer\n  property alias testProbeRetry: fingerprintRecheckTimer\n  property alias testResume: fingerprintResumeTimer\n  property bool testStaleLocked: false')
service = service.replace('readonly property bool locked: lockRequested', 'readonly property bool locked: testStaleLocked || lockRequested')
service = service.replace('  WlSessionLock {', '  Mock.SessionLock {').replace('    WlSessionLockSurface {', '    Rectangle {')
service = service.replace('  PamContext {', '  Mock.PamContext {').replace('LockView {', 'Mock.LockView {')
service = service.replace('  PanelWindow {', '  Rectangle {').replace('    anchors { top: true; bottom: true; left: true; right: true }', '    width: 800; height: 600')
service = re.sub(r'^    (WlrLayershell\..*|exclusionMode:.*)\n', '', service, flags=re.M)
service = service.replace('var screens = Quickshell.screens || []', 'var screens = [{ name: "fixture", width: 1920, height: 1080 }]')
pam_path = base / 'pam-password'
pam_path.touch()
# Both PAM services are fixtures; enrollment must not depend on host setup.
service = service.replace('/etc/pam.d/omarchy-lock-password', str(pam_path))
service = service.replace('/etc/pam.d/omarchy-lock-fingerprint', str(pam_path))
(app / 'Service.qml').write_text(service)
(app / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: shell
  property var stock: null
  Service { id: service }
  IpcHandler {
    target: "test"
    function submit(value: string): string { service.submitPassword(value); return "ok" }
    function failures(): string { return String(service.failedAttempts) }
    function fingerprintState(): string {
      return JSON.stringify({starts: service.testFingerprintPam.starts,
        generation: service.testFingerprintPam.generation,
        streak: service.fingerprintUnreachedStreak,
        delay: service.testRetry.interval, retrying: service.testRetry.running,
        active: service.testFingerprintPam.active,
        probing: service.fingerprintProbeStreak,
        probeRetrying: service.testProbeRetry.running,
        backoff: service.fingerprintRetryBackoffMs, due: service.fingerprintRetryDueMs,
        resumeWatching: service.testResume.running})
    }
    function fingerprintFail(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.error(1)
      service.testFingerprintPam.completed(1)
      return "ok"
    }
    function blank(): string { service.runBlank(); return "ok" }
    function wake(): string { service.runWake(); return "ok" }
    function unpause(): string { service.resumeFingerprint(); return "ok" }
    function sleepGap(): string { service.testResume.lastTickMs -= 10000; return "ok" }
    function strandedCheck(): string { service.strandedLockResolved = false; service.checkStrandedLock(); return "ok" }
    function strandedResolved(): string { return String(service.strandedLockResolved) }
    function staleLock(value: bool): string { service.testStaleLocked = value; return "ok" }
    function fingerprintMismatch(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.completed(1)
      return "ok"
    }
    function oldPrompt(): string { service.fingerprintAttemptPromptedAtMs -= 3000; return "ok" }
    function wallpaperRefresh(): string { service.refreshBackground(); return "ok" }
    function wallpaperState(): string {
      return JSON.stringify({path: service.lockWallpaperPath, version: service.backgroundVersion,
        source: service.backgroundPath, error: service.wallpaperError})
    }
    function fingerprintPrompt(): string { service.testFingerprintPam.pamMessage(); return "ok" }
    function fingerprintMatch(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.completed(0)
      return "ok"
    }
    function fingerprintProbe(): string { service.refreshFingerprintStatus(); return "ok" }
    function resume(): string { service.restartFingerprintAfterSleep(); return "ok" }
    function missingPam(): string { service.passwordPamConfigured = false; return "ok" }
    function doubleReport(value: bool): string { service.testPasswordPam.doubleReport = value; return "ok" }
    function previewState(): string { return String(service.previewVisible) }
    function previewKey(): string { var event = { accepted: false }; service.previewKeyPressed(event); return String(event.accepted) }
    // 4.5 only: what the omarchy-shell socket would answer, with a second
    // "lock" handler (standing in for omarchy.lock) registered ahead of foamy.
    function registry() {
      var probe = Qt.createQmlObject('import QtQuick; import qs.Commons; QtObject { function registry() { return IpcRegistry } }', service, "RegistryProbe")
      var found = probe.registry()
      probe.destroy()
      return found
    }
    function registryDirect(): string {
      var found = registry()
      return JSON.stringify({direct: found.call("lock", "status", []), refused: found.call("lock", "destroy", [])})
    }
    // Put the stand-in ahead of foamy without telling foamy, as if another
    // service (or a later prefer()) had promoted itself.
    function registryShadow(): string {
      var found = registry()
      shell.stock = Qt.createQmlObject('import qs.Commons; ShellIpc { target: "lock"; function status(): string { return "stock" } function lock(): string { return "stock" } function isLocked(): string { return "stock" } }', service, "StockLock")
      found.unregister(shell.stock)
      found.handlers.unshift(shell.stock)
      return String(found.handlerFor("lock") === shell.stock)
    }
    function registryRoute(): string {
      var found = registry()
      return JSON.stringify({first: found.handlerFor("lock") !== shell.stock,
        status: found.call("lock", "status", []), isLocked: found.call("lock", "isLocked", []),
        lock: found.call("lock", "lock", [])})
    }
    function registryCleanup(): string {
      var found = registry()
      found.unregister(shell.stock)
      shell.stock.destroy()
      shell.stock = null
      service.checkLockRoute()
      return "ok"
    }
  }
}
''')
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
bin_dir = base / 'bin'
bin_dir.mkdir()
# Replace every command that could affect the desktop; identity probes also use test data.
for name in ['getent', 'busctl', 'magick', 'fprintd-list', 'omarchy-hyprland-session-lock-stranded',
             'omarchy-system-wake', 'omarchy-brightness-keyboard', 'omarchy-brightness-display']:
    script = '#!/bin/sh\n'
    if name == 'getent':
        script += 'printf "fixture:x:1000:1000:Foamy User:%s:/bin/sh\\n" "$HOME"\n'
    elif name == 'fprintd-list':
        script += 'cat "$HOME/fingerprint-output" 2>/dev/null || echo no\n'
    elif name == 'omarchy-hyprland-session-lock-stranded':
        script += 'printf "%s\\n" "$1" > "$HOME/stranded-parent"\nexit "$(cat "$HOME/stranded-result" 2>/dev/null || echo 1)"\n'
    elif name in ['busctl', 'magick']:
        script += 'exit 1\n'
    else:
        script += 'printf "%s\\n" "' + name + '" >> "$HOME/calls"\n'
    path = bin_dir / name
    path.write_text(script)
    path.chmod(0o755)
host = base / 'omarchy'
poster = host / 'shell/plugins/lock/poster.sh'
poster.parent.mkdir(parents=True)
background = base / '.local/state/omarchy/current/background'
background.parent.mkdir(parents=True)
config = base / '.config/omarchy/shell.json'
config.parent.mkdir(parents=True)
def write_config(disabled=('omarchy.lock',), **settings):
    config.write_text(json.dumps({'version': 1, 'plugins': [{'id': 'foamy.lock', **settings}],
                                  'disabledPlugins': list(disabled)}))
write_config()
# A real account picture goes through the sandboxed helper into the cache.
(base / '.face').write_bytes(artwork.encode_png(bytes([200, 80, 40]) * 256 * 256))
avatar_cache = base / 'cache/omarchy/foamy.lock/avatar.png'
# Register generated view types beside the explicit singleton in this fixture.
with (app / 'qmldir').open('a') as registry:
    for qml in app.glob('*.qml'):
        if qml.name[0].isupper():
            registry.write(f'{qml.stem} 1.0 {qml.name}\n')

env = dict(os.environ, HOME=str(base), USER='fixture', LOGNAME='fixture', XDG_RUNTIME_DIR=str(runtime),
           XDG_CACHE_HOME=str(base / 'cache'), OMARCHY_PATH=str(host), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic',
           QT_STYLE_OVERRIDE='Fusion', PATH=str(bin_dir) + ':' + os.environ['PATH'])
env.pop('DISPLAY', None)
env.pop('WAYLAND_DISPLAY', None)
def ipc(target, method, *args):
    return subprocess.check_output(['quickshell', 'ipc', '-p', str(app), 'call', target, method, *args],
                                   env=env, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
def status():
    return json.loads(ipc('lock', 'status'))
def wait_for(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            value = status()
            if predicate(value):
                return value
        except (ValueError, subprocess.SubprocessError):
            pass
        time.sleep(0.05)
    raise AssertionError('Timed out waiting for state')
log_path = base / 'runtime.log'
with log_path.open('w') as log:
    process = subprocess.Popen(['dbus-run-session', '--', 'quickshell', '-p', str(app), '--no-color'],
                               env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        wait_for(lambda s: s['passwordPam'] and not s['configError'])
        state = wait_for(lambda s: s['avatarRenderPath'] or s['avatarError'])
        assert state['avatarRenderPath'] == str(avatar_cache) and not state['avatarError'], state
        assert avatar_cache.read_bytes()[:8] == artwork.PNG_MAGIC
        assert not state['conflict'] and state['conflictReasons'] == [], state
        assert json.loads(ipc('foamy.lock', 'status'))['secure'] is False, 'foamy.lock status target answers'
        write_config(disabled=())
        state = wait_for(lambda s: s['conflict'])
        assert state['conflictReasons'] == ['stock-lock-enabled'], state
        write_config()
        wait_for(lambda s: not s['conflict'])
        if has_registry:
            direct = json.loads(ipc('test', 'registryDirect'))
            assert direct['direct']['ran'] and json.loads(direct['direct']['output'])['passwordPam'], direct
            assert direct['refused'] == {'ran': False}, 'undeclared functions stay unreachable'
            assert status()['ipcRouteFirst'] is True
            assert ipc('test', 'registryShadow') == 'true', 'fixture put the stand-in handler first'
            # FoamyIpcPreference re-claims the route on its own (5 s timer), no call needed.
            deadline = time.monotonic() + 7
            while time.monotonic() < deadline:
                route = json.loads(ipc('test', 'registryRoute'))
                if route['first']:
                    break
                time.sleep(0.25)
            assert route['first'], 'foamy-lock did not re-claim the lock route'
            routed = json.loads(route['status']['output'])
            assert routed['conflict'] and 'lock-target-shared' in routed['conflictReasons'] and routed['ipcRouteFirst'], route
            assert route['isLocked'] == {'ran': True, 'output': 'false'}, route
            assert route['lock'] == {'ran': True, 'output': 'ok'}, 'lock must reach foamy-lock, not the second handler'
            wait_for(lambda s: s['secure'])
            ipc('test', 'submit', 'test-password')
            wait_for(lambda s: not s['locked'])
            ipc('test', 'registryCleanup')
            wait_for(lambda s: not s['conflict'])
            assert status()['ipcFastPath'] is True
            print('PASS: 4.5 IpcRegistry routes lock to foamy, keeps it ahead of a second lock handler and reports the conflict')
        else:
            assert status()['ipcFastPath'] is False
        print('PASS: sandboxed avatar thumbnail, conflict flag from disabledPlugins, foamy.lock status target')
        assert ipc('lock', 'preview') == 'ok' and ipc('test', 'previewState') == 'true'
        assert ipc('test', 'previewKey') == 'true' and ipc('test', 'previewState') == 'false'
        assert ipc('lock', 'preview') == 'ok'
        def wallpaper_state():
            return json.loads(ipc('test', 'wallpaperState'))
        def refresh_wallpaper():
            ipc('test', 'wallpaperRefresh')
        static = base / 'static # wallpaper.svg'
        static.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>')
        background.symlink_to(static)
        refresh_wallpaper()
        wait_for(lambda s: wallpaper_state()['path'] == str(static))
        version = wallpaper_state()['version']
        static.write_text(static.read_text().replace('16', '32'))
        refresh_wallpaper()
        wait_for(lambda s: wallpaper_state()['version'] > version)
        version = wallpaper_state()['version']
        refresh_wallpaper()
        time.sleep(0.2)
        assert wallpaper_state()['version'] == version, 'unchanged wallpaper should reuse cache'
        video = base / 'movie.MP4'
        video.touch()
        background.unlink()
        background.symlink_to(video)
        refresh_wallpaper()
        wait_for(lambda s: s['wallpaperError'] == 'video-poster-unavailable')
        assert wallpaper_state()['path'] == '', '4.0.6 must never send video to Image'
        poster.write_text('#!/bin/sh\nexit 1\n')
        refresh_wallpaper()
        wait_for(lambda s: s['wallpaperError'] == 'video-poster-failed')
        assert wallpaper_state()['path'] == ''
        poster.write_text('#!/bin/sh\nsleep 0.2\nprintf "%s\\n" "$HOME/static # wallpaper.svg"\n')
        refresh_wallpaper()
        wait_for(lambda s: wallpaper_state()['path'] == str(static) and not s['wallpaperError'])
        # A stale video result must launch extraction for the newest video as well.
        second_video = base / 'second.mp4'
        second_video.touch()
        second_poster = base / 'second.svg'
        second_poster.write_text(static.read_text())
        marker = base / 'poster-started'
        poster.write_text('#!/bin/sh\n: > "$HOME/poster-started"\nsleep 0.3\ncase "$1" in *second.mp4) printf "%s\\n" "$HOME/second.svg";; *) printf "%s\\n" "$HOME/static # wallpaper.svg";; esac\n')
        refresh_wallpaper()
        wait_for(lambda s: marker.exists())
        background.unlink()
        background.symlink_to(second_video)
        refresh_wallpaper()
        wait_for(lambda s: wallpaper_state()['source'] == str(second_video))
        wait_for(lambda s: wallpaper_state()['path'] == str(second_poster))
        # Change the selection while extraction is still running; reject its stale output.
        refresh_wallpaper()
        time.sleep(0.1)
        background.unlink()
        background.symlink_to(static)
        refresh_wallpaper()
        wait_for(lambda s: wallpaper_state()['source'] == str(static))
        time.sleep(0.3)
        assert wallpaper_state()['path'] == str(static)
        background.unlink()
        refresh_wallpaper()
        wait_for(lambda s: s['wallpaperError'] == 'wallpaper-unavailable')
        assert wallpaper_state()['path'] == ''
        assert not status()['locked'], 'wallpaper failures must not change lock state'
        print('PASS: static wallpaper invalidation/cache reuse, optional video poster success/failure/missing helper, stale result rejection')
        # Simulate a stale QML property binding during a pre-suspend IPC call.
        ipc('test', 'staleLock', 'true')
        assert ipc('lock', 'isLocked') == 'false'
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['requested'] and s['secure'])
        assert ipc('test', 'previewState') == 'false', 'a real lock hides the preview overlay'
        ipc('test', 'staleLock', 'false')
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        (base / 'calls').unlink(missing_ok=True)
        write_config(timeFormat='12h' , showUserInfo=False, showMedia=False, blankAfterSec=None)
        wait_for(lambda s: s['settings']['timeFormat'] == '12h' and s['settings']['blankAfterSec'] is None)
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['secure'])
        time.sleep(1.1)
        assert not (base / 'calls').exists(), 'null blank timeout should not blank the display'
        config.write_text('{invalid')
        state = wait_for(lambda s: bool(s['configError']))
        assert state['secure'] and state['settings']['timeFormat'] == '12h'
        write_config(blankAfterSec=0)
        wait_for(lambda s: 'blankAfterSec' in s['configError'])
        ipc('test', 'doubleReport', 'true')
        ipc('test', 'submit', 'incorrect')
        wait_for(lambda s: not s['authenticating'] and s['secure'])
        deadline = time.monotonic() + 3
        while ipc('test', 'failures') != '1' and time.monotonic() < deadline:
            time.sleep(0.05)
        time.sleep(0.2)
        assert ipc('test', 'failures') == '1', 'onError plus onCompleted must count one failure'
        ipc('test', 'doubleReport', 'false')
        assert status()['secure']
        # A picture the sandbox refuses never reaches Qt: the initial is shown.
        (base / '.face').write_bytes(b'not an image')
        ipc('test', 'submit', 'incorrect')
        wait_for(lambda s: ipc('test', 'failures') == '2')
        assert status()['secure']
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        write_config(blankAfterSec=1)
        wait_for(lambda s: not s['configError'] and s['settings']['blankAfterSec'] == 1)
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['secure'])
        state = wait_for(lambda s: s['avatarError'])
        assert state['avatarError'] == 'unsupported-format' and state['avatarRenderPath'] == '', state
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if (base / 'calls').exists() and 'omarchy-brightness-display' in (base / 'calls').read_text():
                break
            time.sleep(0.05)
        assert 'omarchy-brightness-display' in (base / 'calls').read_text()
        assert status()['secure'], 'blanking must not unlock the session'
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        replacement = config.with_suffix('.new')
        replacement.write_text(json.dumps({'version': 1, 'plugins': [{'id': 'foamy.lock', 'showMedia': False}]}))
        replacement.replace(config)
        wait_for(lambda s: not s['settings']['showMedia'] and s['settings']['blankAfterSec'] == 30)
        config.unlink()
        wait_for(lambda s: bool(s['configError']))
        assert ipc('lock', 'lock') == 'ok', 'missing preferences must not disable locking'
        wait_for(lambda s: s['secure'])
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        fingerprint_output = base / 'fingerprint-output'
        write_config(blankAfterSec=None)
        wait_for(lambda s: s['settings']['blankAfterSec'] is None)
        fingerprint_output.write_text('found 1 devices\n - #0: right-index-finger\n')
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['secure'] and s['fingerprint'] and s['authenticating'])
        def fingerprint_state():
            return json.loads(ipc('test', 'fingerprintState'))
        for expected_streak, delay in [(1, 1000), (2, 2000), (3, 4000)]:
            wait_for(lambda s: fingerprint_state()['active'])
            ipc('test', 'fingerprintFail')
            state = fingerprint_state()
            assert state['streak'] == expected_streak, 'error plus completed must settle once'
            assert state['delay'] == delay
        assert status()['fingerprintUnavailable'] and status()['secure']
        ipc('test', 'submit', 'incorrect')
        wait_for(lambda s: ipc('test', 'failures') == '1')
        assert status()['secure'], 'wrong password while reader is unavailable must not unlock'
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        assert not fingerprint_state()['retrying'], 'password fallback must stop fingerprint retries'
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['secure'] and fingerprint_state()['active'])
        wait_for(lambda s: fingerprint_state()['active'])
        ipc('test', 'fingerprintPrompt')
        assert not status()['fingerprintUnavailable'], 'prompt clears notice immediately'
        # A prompt followed immediately by a device error is still an unusable attempt.
        ipc('test', 'fingerprintFail')
        assert fingerprint_state()['streak'] == 1 and fingerprint_state()['delay'] == 1000
        wait_for(lambda s: fingerprint_state()['active'])
        ipc('test', 'fingerprintPrompt')
        ipc('test', 'fingerprintMismatch')
        assert fingerprint_state()['streak'] == 0 and fingerprint_state()['delay'] == 250
        wait_for(lambda s: fingerprint_state()['active'])
        ipc('test', 'fingerprintPrompt')
        ipc('test', 'oldPrompt')
        ipc('test', 'fingerprintFail')
        assert fingerprint_state()['streak'] == 0, 'normal full-window error should retry fast'
        wait_for(lambda s: fingerprint_state()['active'])
        starts = fingerprint_state()['starts']
        ipc('test', 'blank')
        assert status()['fingerprintPaused'] and fingerprint_state()['active'], 'blanking preserves the active attempt'
        ipc('test', 'fingerprintFail')
        time.sleep(1.2)
        assert fingerprint_state()['starts'] == starts and not fingerprint_state()['retrying']
        ipc('test', 'unpause')
        assert fingerprint_state()['backoff'] == 1000, 'wake must preserve the backoff tier'
        wait_for(lambda s: fingerprint_state()['active'])
        ipc('test', 'fingerprintFail')
        ipc('test', 'blank')
        due = fingerprint_state()['due']
        time.sleep(0.1)
        ipc('test', 'unpause')
        assert fingerprint_state()['due'] == due and fingerprint_state()['backoff'] == 2000
        assert 250 <= fingerprint_state()['delay'] < 2000, 'wake resumes the remaining delay'
        ipc('test', 'blank')
        assert ipc('lock', 'lock') == 'ok'
        assert fingerprint_state()['resumeWatching'], 'repeat pre-suspend lock must watch for resume while blank'
        ipc('test', 'sleepGap')
        wait_for(lambda s: not s['fingerprintPaused'] and fingerprint_state()['active'])
        assert fingerprint_state()['streak'] == 0
        ipc('test', 'fingerprintPrompt')
        generation = fingerprint_state()['generation']
        ipc('test', 'resume')
        assert fingerprint_state()['generation'] == generation + 1
        wait_for(lambda s: fingerprint_state()['active'])
        assert fingerprint_state()['streak'] == 0, 'resume clears the stale streak'
        fingerprint_output.write_text('D-Bus activation failed\n')
        ipc('test', 'fingerprintProbe')
        time.sleep(0.2)
        assert fingerprint_state()['probing'] == 0 and not fingerprint_state()['probeRetrying'], 'known enrollment must not spawn competing probes'
        assert status()['fingerprint'], 'temporary probe error must retain enrollment state'
        fingerprint_output.write_text('found 1 devices\n - #0: right-index-finger\n')
        ipc('test', 'fingerprintProbe')
        wait_for(lambda s: fingerprint_state()['probing'] == 0)
        ipc('test', 'fingerprintMatch')
        wait_for(lambda s: not s['locked'])
        assert not fingerprint_state()['retrying'], 'unlock must stop pending retries'
        fingerprint_output.write_text('no\n')
        ipc('test', 'fingerprintProbe')
        wait_for(lambda s: not s['fingerprint'])
        fingerprint_output.write_text('D-Bus activation failed\n')
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['secure'] and s['fingerprintUnavailable'])
        assert not status()['fingerprint'], 'unknown initial enrollment must remain unknown'
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        assert not fingerprint_state()['probeRetrying'] and not fingerprint_state()['resumeWatching']
        print('PASS: fingerprint pause/in-flight completion, deadline/backoff preservation, blank suspend recovery, fast device errors, initial probe failures')
        print('PASS: fingerprint duplicate settlement, backoff, unavailable/recovered UI state, resume abort/retry, transient probe recovery, match unlock and retry cleanup')
        (base / 'stranded-result').write_text('1')
        ipc('test', 'strandedCheck')
        wait_for(lambda s: ipc('test', 'strandedResolved') == 'true')
        assert not status()['locked'], 'another live locker must not be taken over'
        assert int((base / 'stranded-parent').read_text()) > 0, 'stranded helper receives the shell PID'
        (base / 'stranded-result').write_text('2')
        ipc('test', 'strandedCheck')
        time.sleep(0.6)
        assert not status()['locked'] and ipc('test', 'strandedResolved') == 'false'
        (base / 'stranded-result').write_text('0')
        wait_for(lambda s: s['secure'])
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        print('PASS: direct lock-state decisions, live-owner refusal, unknown-output retry and orphan recovery')
        ipc('test', 'missingPam')
        assert ipc('lock', 'lock') == 'missing-pam'
        assert not status()['locked']
        print('PASS: settings reload/atomic save, invalid/missing settings retain policy and locking, disabled/timed blanking, simulated wrong/right password, missing PAM refuses lock')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        print(log_path.read_text())
        print('Runtime evidence:', base)
