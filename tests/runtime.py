"""Exercise service settings and lock flow with simulated PAM and compositor boundaries."""
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
base = Path(tempfile.mkdtemp(prefix='foamy-lock-runtime-'))
app = base / 'app'
app.mkdir()
(app / 'Commons').symlink_to('/usr/share/omarchy/shell/Commons', target_is_directory=True)
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
service = service.replace('  id: root', '  id: root\n  property alias testFingerprintPam: fingerprintPam\n  property alias testRetry: fingerprintRetryTimer')
service = service.replace('  WlSessionLock {', '  Mock.SessionLock {').replace('    WlSessionLockSurface {', '    Rectangle {')
service = service.replace('  PamContext {', '  Mock.PamContext {').replace('LockView {', 'Mock.LockView {')
service = service.replace('  PanelWindow {', '  Rectangle {').replace('    anchors { top: true; bottom: true; left: true; right: true }', '    width: 800; height: 600')
service = re.sub(r'^    (WlrLayershell\..*|exclusionMode:.*)\n', '', service, flags=re.M)
service = service.replace('var screens = Quickshell.screens || []', 'var screens = [{ name: "fixture", width: 1920, height: 1080 }]')
pam_path = base / 'pam-password'
pam_path.touch()
service = service.replace('/etc/pam.d/omarchy-lock-password', str(pam_path))
(app / 'Service.qml').write_text(service)
(app / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
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
        probing: service.fingerprintProbeStreak})
    }
    function fingerprintFail(): string {
      service.testFingerprintPam.active = false
      service.testFingerprintPam.error(1)
      service.testFingerprintPam.completed(1)
      return "ok"
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
  }
}
''')
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
bin_dir = base / 'bin'
bin_dir.mkdir()
# Replace every command that could affect the desktop; identity probes also use test data.
for name in ['getent', 'busctl', 'magick', 'fprintd-list', 'omarchy-hyprland-session-locked',
             'omarchy-system-wake', 'omarchy-brightness-keyboard', 'omarchy-brightness-display']:
    script = '#!/bin/sh\n'
    if name == 'getent':
        script += 'printf "fixture:x:1000:1000:Foamy User:%s:/bin/sh\\n" "$HOME"\n'
    elif name == 'fprintd-list':
        script += 'cat "$HOME/fingerprint-output" 2>/dev/null || echo no\n'
    elif name in ['busctl', 'magick', 'omarchy-hyprland-session-locked']:
        script += 'exit 1\n'
    else:
        script += 'printf "%s\\n" "' + name + '" >> "$HOME/calls"\n'
    path = bin_dir / name
    path.write_text(script)
    path.chmod(0o755)
config = base / '.config/omarchy/shell.json'
config.parent.mkdir(parents=True)
def write_config(**settings):
    config.write_text(json.dumps({'version': 1, 'plugins': [{'id': 'foamy.lock', **settings}]}))
write_config()
env = dict(os.environ, HOME=str(base), USER='fixture', LOGNAME='fixture', XDG_RUNTIME_DIR=str(runtime),
           XDG_CACHE_HOME=str(base / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic',
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
        write_config(timeFormat='12h', showUserInfo=False, showMedia=False, blankAfterSec=None)
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
        ipc('test', 'submit', 'incorrect')
        wait_for(lambda s: not s['authenticating'] and s['secure'])
        deadline = time.monotonic() + 3
        while ipc('test', 'failures') != '1' and time.monotonic() < deadline:
            time.sleep(0.05)
        assert ipc('test', 'failures') == '1'
        assert status()['secure']
        ipc('test', 'submit', 'test-password')
        wait_for(lambda s: not s['locked'])
        write_config(blankAfterSec=1)
        wait_for(lambda s: not s['configError'] and s['settings']['blankAfterSec'] == 1)
        assert ipc('lock', 'lock') == 'ok'
        wait_for(lambda s: s['secure'])
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
        generation = fingerprint_state()['generation']
        ipc('test', 'resume')
        assert fingerprint_state()['generation'] == generation + 1
        wait_for(lambda s: fingerprint_state()['active'])
        assert fingerprint_state()['streak'] == 0, 'resume clears the stale streak'
        fingerprint_output.write_text('D-Bus activation failed\n')
        ipc('test', 'fingerprintProbe')
        wait_for(lambda s: fingerprint_state()['probing'] > 0)
        assert status()['fingerprint'], 'temporary probe error must retain enrollment state'
        fingerprint_output.write_text('found 1 devices\n - #0: right-index-finger\n')
        wait_for(lambda s: fingerprint_state()['probing'] == 0)
        ipc('test', 'fingerprintMatch')
        wait_for(lambda s: not s['locked'])
        assert not fingerprint_state()['retrying'], 'unlock must stop pending retries'
        fingerprint_output.write_text('no\n')
        ipc('test', 'fingerprintProbe')
        wait_for(lambda s: not s['fingerprint'])
        print('PASS: fingerprint duplicate settlement, backoff, unavailable/recovered UI state, resume abort/retry, transient probe recovery, match unlock and retry cleanup')
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
