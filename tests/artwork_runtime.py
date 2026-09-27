"""Exercise the real artwork controller and helper without a real desktop lock."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('artwork', source / 'artwork.py')
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)
base = Path(tempfile.mkdtemp(prefix='foamy-artwork-runtime-'))
app = base / 'app'
app.mkdir()
runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
cache = base / 'cache'
cache.mkdir()
for name in ['Artwork.qml', 'Model.js']:
    shutil.copy(source / name, app)
shutil.copy(source / 'artwork.py', app / 'implementation.py')
# Record each real helper invocation. The slow case deliberately returns after
# SIGTERM to prove that generation checks reject results from a cancelled job.
(app / 'artwork.py').write_text('''import importlib.util, io, json, os, signal, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location("implementation", Path(__file__).with_name("implementation.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
line = sys.stdin.buffer.readline()
request = json.loads(line)
with open(os.environ["HOME"] + "/jobs", "a") as record:
    record.write(request["url"] + "\\n")
if request["url"].endswith("slow.png"):
    signal.signal(signal.SIGTERM, lambda *_: None)
    time.sleep(0.8)
    print(json.dumps({"ok": True, "path": os.environ["XDG_CACHE_HOME"] + "/omarchy/foamy.lock/artwork/" + "a" * 64 + ".png"}))
else:
    sys.stdin = io.TextIOWrapper(io.BytesIO(line))
    module.main()
''')
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
    function status(): string {
      return JSON.stringify({state: artwork.state, error: artwork.error, path: artwork.path,
        busy: artwork.busy, entries: artwork.entries.length})
    }
  }
}
''')
env = dict(os.environ, HOME=str(base), XDG_RUNTIME_DIR=str(runtime), XDG_CACHE_HOME=str(cache),
           QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion')
env.pop('DISPLAY', None)
env.pop('WAYLAND_DISPLAY', None)


def ipc(method, *args):
    return subprocess.check_output(['quickshell', 'ipc', '-p', str(app), 'call', 'test', method, *args],
                                   env=env, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()


def status():
    return json.loads(ipc('status'))


def wait_for(predicate):
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        try:
            value = status()
            if predicate(value):
                return value
        except (ValueError, subprocess.SubprocessError):
            pass
        time.sleep(0.04)
    raise AssertionError('Artwork state timed out: ' + repr(status()))


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
        ipc('track', 'https://images.example.com/cover.png', 'Remote')
        denied = wait_for(lambda s: s['state'] == 'fallback' and not s['busy'])
        assert denied['error'] == 'host-not-allowed'
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
        ipc('enabled', 'false')
        assert status()['state'] == 'empty' and not status()['path']
        print('PASS: real thumbnail, locked cache hit/miss, denied HTTPS, failure backoff, cancellation, stale result, coalescing, disabled artwork')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        print(log_path.read_text())
        print('Artwork runtime evidence:', base)
