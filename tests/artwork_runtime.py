"""Exercise the real artwork controller and helper without a real desktop lock."""
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time

source = Path(__file__).resolve().parents[1]
# foamy-kit's test helpers (the harness's isolation and condition waits).
KIT = Path(os.environ.get('FOAMY_KIT', Path.home() / 'GitHub/Personal/foamy-kit'))
sys.path.insert(0, str(KIT / 'preview'))
import harness  # noqa: E402
import hostenv  # noqa: E402

# Fixture images (the helper itself is tested in artwork_test.py).
spec = importlib.util.spec_from_file_location('png_fixture', source / 'tests' / 'png_fixture.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)
base = Path(tempfile.mkdtemp(prefix='foamy-artwork-runtime-'))
app = base / 'app'
app.mkdir()
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
cache = base / 'cache'
cache.mkdir()
shutil.copy(source / 'Model.js', app)
# The worker's command, switchable to one that can't start (no exited(),
# only `running` going false).
controller = (source / 'Artwork.qml').read_text()
for before, after in [
    ('  property bool busy: false\n', '  property bool busy: false\n  property bool testUnstartable: false\n'),
    ('    command: FoamyNative.command(', '    command: root.testUnstartable ? [root.cacheHome + "/no-such-command"] : FoamyNative.command('),
]:
    assert controller.count(before) == 1, 'Artwork.qml no longer contains ' + repr(before)
    controller = controller.replace(before, after)
(app / 'Artwork.qml').write_text(controller)
# The plugin's stamped kit (FoamyNative) and a recording stand-in for the
# helper at bin/<arch>/foamy-lock-helper: it logs each real invocation and
# execs the real helper. The slow case deliberately returns after SIGTERM to
# prove that generation checks reject results from a cancelled job.
(app / 'kit').symlink_to(source / 'kit', target_is_directory=True)
machine = platform.machine()
helper = app / 'bin' / machine / 'foamy-lock-helper'
helper.parent.mkdir(parents=True)
helper.write_text('''#!/usr/bin/python3 -I
import json, os, signal, sys, time
REAL = %r
line = sys.stdin.buffer.readline()
request = json.loads(line)
with open(os.environ["HOME"] + "/jobs", "a") as record:
    record.write(request["url"] + "\\n")
if request["url"].endswith("slow.png"):
    signal.signal(signal.SIGTERM, lambda *_: None)
    time.sleep(0.8)
    print(json.dumps({"ok": True, "path": os.environ["XDG_CACHE_HOME"] + "/omarchy/foamy.lock/artwork/" + "a" * 64 + ".png"}))
else:
    read, write = os.pipe()
    os.write(write, line)
    os.close(write)
    os.dup2(read, 0)
    os.execv(REAL, [REAL, *sys.argv[1:]])
''' % str(source / 'bin' / machine / 'foamy-lock-helper'))
helper.chmod(0o755)
for name, color in [('first.png', [34, 120, 156]), ('second.png', [140, 90, 55])]:
    (cache / name).write_bytes(artwork.encode_png(bytes(color) * 256 * 256))
(app / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  QtObject {
    id: fixturePlayer
    property string uniqueId: "fixture"
    property string trackTitle: "Track"
    property string trackArtist: "Artist"
    property string trackArtUrl: ""
  }
  Artwork { id: artwork; player: fixturePlayer }
  IpcHandler {
    target: "test"
    function track(url: string, title: string): string {
      fixturePlayer.trackTitle = title; fixturePlayer.trackArtUrl = url; return "ok"
    }
    function lock(value: bool): string { artwork.locked = value; return "ok" }
    function enabled(value: bool): string { artwork.allowed = value; return "ok" }
    function unstartable(value: bool): string { artwork.testUnstartable = value; return "ok" }
    function status(): string {
      return JSON.stringify({state: artwork.state, error: artwork.error, path: artwork.path,
        busy: artwork.busy, entries: artwork.entries.length})
    }
  }
}
''')
env = dict(os.environ, HOME=str(base), XDG_RUNTIME_DIR=str(runtime), XDG_CACHE_HOME=str(cache),
           QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion')
for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'DBUS_SESSION_BUS_ADDRESS'):
    env.pop(name, None)
# No Omarchy command, audio server or system bus: the controller runs only the helper.
hostenv.isolate(env, base)


def ipc(method, *args):
    return subprocess.check_output(['quickshell', 'ipc', '-p', str(app), 'call', 'test', method, *args],
                                   env=env, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()


def status():
    return json.loads(ipc('status'))


def wait_for(predicate):
    def matching():
        try:
            value = status()
        except (ValueError, subprocess.SubprocessError):
            return None
        return value if predicate(value) else None

    value = harness.wait_for(matching, 7, interval=0.04)
    if value is None:
        raise AssertionError('Artwork state timed out: ' + repr(status()))
    return value


def jobs():
    return (base / 'jobs').read_text().splitlines() if (base / 'jobs').exists() else []


log_path = base / 'runtime.log'
with log_path.open('w') as log:
    process = subprocess.Popen(['dbus-run-session', '--', 'quickshell', '-p', str(app), '--no-color'],
                               env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        wait_for(lambda s: s['state'] == 'empty')
        first, second = (cache / 'first.png').as_uri(), (cache / 'second.png').as_uri()
        ipc('track', first, 'First')
        ready = wait_for(lambda s: s['state'] == 'ready' and not s['busy'])
        first_path = ready['path']
        assert Path(first_path).is_file()
        assert len(jobs()) == 1
        ipc('lock', 'true')
        assert status()['path'] == first_path
        ipc('track', second, 'Second')
        assert status()['state'] == 'locked-miss' and not status()['path']
        time.sleep(0.5)
        assert len(jobs()) == 1, 'a cache miss while locked started a helper'
        ipc('track', first, 'First')
        assert status()['path'] == first_path
        ipc('lock', 'false')
        before = len(jobs())
        ipc('track', 'https://images.example.com/cover.png', 'Remote')
        denied = wait_for(lambda s: s['state'] == 'fallback' and not s['busy'])
        assert denied['error'] == 'host-not-allowed'
        ipc('track', 'https://images.example.com/other.png', 'Remote 2')
        time.sleep(0.6)
        assert len(jobs()) == before, 'a host outside artworkHosts must not start the helper'
        count = len(jobs())
        ipc('lock', 'true')
        ipc('lock', 'false')
        time.sleep(0.6)
        assert len(jobs()) == count, 'failed artwork was retried without backoff'
        ipc('track', (cache / 'slow.png').as_uri(), 'Slow')
        wait_for(lambda s: s['busy'] and len(jobs()) > count)
        ipc('lock', 'true')
        wait_for(lambda s: not s['busy'])
        assert status()['state'] == 'locked-miss' and not status()['path'], 'late cancelled result was accepted'
        ipc('lock', 'false')
        # Several changes inside the debounce window should launch only the last.
        count = len(jobs())
        ipc('track', first, 'Changing 1')
        ipc('track', first, 'Changing 2')
        ipc('track', second, 'Final')
        ready = wait_for(lambda s: s['state'] == 'ready' and not s['busy'])
        assert ready['path'] != first_path
        assert len(jobs()) == count + 1
        # A worker that can't start reports no exit: the job still ends (no
        # busy left behind, well before the 10 s watchdog), and later tracks
        # still get a worker.
        for name, color in [('unstartable.png', [9, 99, 199]), ('after.png', [199, 99, 9])]:
            (cache / name).write_bytes(artwork.encode_png(bytes(color) * 256 * 256))
        count = len(jobs())
        ipc('unstartable', 'true')
        ipc('track', (cache / 'unstartable.png').as_uri(), 'Unstartable')
        started = time.monotonic()
        failed = wait_for(lambda s: s['state'] == 'fallback' and not s['busy'])
        assert failed['error'] == 'helper-exited', failed
        assert time.monotonic() - started < 5, 'settled by the watchdog, not the failed start'
        assert len(jobs()) == count
        ipc('unstartable', 'false')
        ipc('track', (cache / 'after.png').as_uri(), 'After')
        ready = wait_for(lambda s: s['state'] == 'ready' and not s['busy'])
        assert Path(ready['path']).is_file() and len(jobs()) == count + 1
        # No helper for this CPU (bash's exec exits 127): fallback, logged
        # once, and no helper is started for later tracks.
        helper.rename(helper.with_name('moved-away'))
        for index in range(3):
            (cache / f'other{index}.png').write_bytes(artwork.encode_png(bytes([index, 1, 2]) * 256 * 256))
        ipc('track', (cache / 'other0.png').as_uri(), 'Unavailable')
        unavailable = wait_for(lambda s: s['state'] == 'fallback' and not s['busy'])
        assert unavailable['error'] == 'helper-unavailable', unavailable
        for index in [1, 2]:
            ipc('track', (cache / f'other{index}.png').as_uri(), f'Unavailable {index}')
            state = status()
            assert state['state'] == 'fallback' and state['error'] == 'helper-unavailable' and not state['busy'], state
        helper.with_name('moved-away').rename(helper)
        ipc('enabled', 'false')
        assert status()['state'] == 'empty' and not status()['path']
        assert log_path.read_text().count('foamy.lock artwork: helper-unavailable') == 1, 'logged once'
        print('PASS: real thumbnail, locked cache hit/miss, denied HTTPS, failure backoff, cancellation, stale result, coalescing, unstartable worker, unavailable helper, disabled artwork')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        print(log_path.read_text())
        print('Artwork runtime evidence:', base)
