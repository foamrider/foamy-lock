"""Exercise the real artwork controller and helper without a real desktop lock."""

import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

source = Path(__file__).resolve().parents[1]
# foamy-kit's test helpers (the harness's isolation and condition waits).
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402
import hostenv  # noqa: E402

# Fixture images (the helper itself is tested in artwork_test.py).
spec = importlib.util.spec_from_file_location("png_fixture", source / "tests" / "png_fixture.py")
artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artwork)
base = Path(tempfile.mkdtemp(prefix="foamy-artwork-runtime-"))
app = base / "app"
app.mkdir()
runtime = base / "runtime"
runtime.mkdir(mode=0o700)
cache = base / "cache"
cache.mkdir()
shutil.copy(source / "Model.js", app)
# The worker's command, switchable to one that can't start (no exited(),
# only `running` going false), and a count of started jobs (the helper's own
# record misses a job cancelled before the helper read its request).
controller = (source / "Artwork.qml").read_text()
for before, after in [
    (
        "  property bool busy: false\n",
        "  property bool busy: false\n  property bool testUnstartable: false\n  property int testStarts: 0\n",
    ),
    ("    lastStarted = Date.now()\n", "    lastStarted = Date.now()\n    testStarts += 1\n"),
    (
        "    command: FoamyNative.command(",
        '    command: root.testUnstartable ? [root.cacheHome + "/no-such-command"] : FoamyNative.command(',
    ),
]:
    assert controller.count(before) == 1, "Artwork.qml no longer contains " + repr(before)
    controller = controller.replace(before, after)
(app / "Artwork.qml").write_text(controller)
# The plugin's stamped kit (FoamyNative) and a recording stand-in for the
# helper at bin/<arch>/foamy-lock-helper: it logs each real invocation and
# execs the real helper. The slow case ignores SIGTERM and answers only once
# the test creates $HOME/release-slow (or after 20 s), so the test cancels it
# while it surely runs and proves that generation checks reject the late
# result of a cancelled job.
(app / "kit").symlink_to(source / "kit", target_is_directory=True)
machine = platform.machine()
helper = app / "bin" / machine / "foamy-lock-helper"
helper.parent.mkdir(parents=True)
helper.write_text(
    """#!/usr/bin/python3 -I
import json, os, signal, sys, time
REAL = %r
line = sys.stdin.buffer.readline()
request = json.loads(line)
with open(os.environ["HOME"] + "/jobs", "a") as record:
    record.write(request["url"] + "\\n")
if request["url"].endswith("slow.png"):
    signal.signal(signal.SIGTERM, lambda *_: None)
    release = os.environ["HOME"] + "/release-slow"
    deadline = time.monotonic() + 20
    while not os.path.exists(release) and time.monotonic() < deadline:
        time.sleep(0.02)
    print(json.dumps({"ok": True, "path": os.environ["XDG_CACHE_HOME"] + "/omarchy/foamy.lock/artwork/" + "a" * 64 + ".png"}))
else:
    read, write = os.pipe()
    os.write(write, line)
    os.close(write)
    os.dup2(read, 0)
    os.execv(REAL, [REAL, *sys.argv[1:]])
"""
    % str(source / "bin" / machine / "foamy-lock-helper")
)
helper.chmod(0o755)
for name, color in [("first.png", [34, 120, 156]), ("second.png", [140, 90, 55])]:
    (cache / name).write_bytes(artwork.encode_png(bytes(color) * 256 * 256))
(app / "shell.qml").write_text("""import QtQuick
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
    // A burst of track changes in one call ("url<TAB>title" lines): separate
    // IPC calls can land further apart than the debounce window on a busy
    // machine. Not JSON: qs ipc reads a JSON array as several arguments.
    function tracks(list: string): string {
      for (const line of list.split("\n")) {
        const [url, title] = line.split("\t")
        fixturePlayer.trackTitle = title; fixturePlayer.trackArtUrl = url
      }
      return "ok"
    }
    function lock(value: bool): string { artwork.locked = value; return "ok" }
    function enabled(value: bool): string { artwork.allowed = value; return "ok" }
    function unstartable(value: bool): string { artwork.testUnstartable = value; return "ok" }
    function status(): string {
      return JSON.stringify({state: artwork.state, error: artwork.error, path: artwork.path,
        busy: artwork.busy, entries: artwork.entries.length, starts: artwork.testStarts})
    }
  }
}
""")
env = dict(
    os.environ,
    HOME=str(base),
    XDG_RUNTIME_DIR=str(runtime),
    XDG_CACHE_HOME=str(cache),
    QT_QPA_PLATFORM="offscreen",
    QT_QPA_PLATFORMTHEME="basic",
    QT_STYLE_OVERRIDE="Fusion",
)
# No Omarchy command, audio server, display or desktop bus: the controller
# runs only the helper (qs gets dbus-run-session's private bus).
hostenv.isolate(env, base)


def ipc(method, *args):
    return subprocess.check_output(
        ["quickshell", "ipc", "-p", str(app), "call", "test", method, *args],
        env=env,
        text=True,
        stderr=subprocess.DEVNULL,
        timeout=3,
    ).strip()


def status():
    return json.loads(ipc("status"))


def wait_for(predicate):
    def matching():
        try:
            value = status()
        except (ValueError, subprocess.SubprocessError):
            return None
        return value if predicate(value) else None

    value = harness.wait_for(matching, 7, interval=0.04)
    if value is None:
        raise AssertionError("Artwork state timed out: " + repr(status()))
    return value


def jobs():
    return (base / "jobs").read_text().splitlines() if (base / "jobs").exists() else []


log_path = base / "runtime.log"
with log_path.open("w") as log:
    # The group takes dbus-run-session, its bus, qs and the helpers qs started.
    shell = hostenv.ProcessGroup(
        ["dbus-run-session", "--", "quickshell", "-p", str(app), "--no-color"],
        env=env,
        stdout=log,
        stderr=log,
    )
    try:
        wait_for(lambda s: s["state"] == "empty")
        first, second = (cache / "first.png").as_uri(), (cache / "second.png").as_uri()
        ipc("track", first, "First")
        ready = wait_for(lambda s: s["state"] == "ready" and not s["busy"])
        first_path = ready["path"]
        assert Path(first_path).is_file()
        assert len(jobs()) == 1
        ipc("lock", "true")
        assert status()["path"] == first_path
        ipc("track", second, "Second")
        assert status()["state"] == "locked-miss" and not status()["path"]
        time.sleep(0.5)
        assert len(jobs()) == 1, "a cache miss while locked started a helper"
        ipc("track", first, "First")
        assert status()["path"] == first_path
        ipc("lock", "false")
        before = len(jobs())
        ipc("track", "https://images.example.com/cover.png", "Remote")
        denied = wait_for(lambda s: s["state"] == "fallback" and not s["busy"])
        assert denied["error"] == "host-not-allowed"
        ipc("track", "https://images.example.com/other.png", "Remote 2")
        time.sleep(0.6)
        assert len(jobs()) == before, "a host outside artworkHosts must not start the helper"
        count = len(jobs())
        ipc("lock", "true")
        ipc("lock", "false")
        time.sleep(0.6)
        assert len(jobs()) == count, "failed artwork was retried without backoff"
        ipc("track", (cache / "slow.png").as_uri(), "Slow")
        wait_for(lambda s: s["busy"] and len(jobs()) > count)
        ipc("lock", "true")
        (base / "release-slow").touch()
        wait_for(lambda s: not s["busy"])
        assert status()["state"] == "locked-miss" and not status()["path"], "late cancelled result was accepted"
        # Unlocking retries the cancelled track (released, so it answers at
        # once); let it settle so its job can't count towards the burst.
        ipc("lock", "false")
        wait_for(lambda s: s["state"] == "ready" and not s["busy"])
        # Several changes inside the debounce window should launch only the last.
        count, starts = len(jobs()), status()["starts"]
        burst = [(first, "Changing 1"), (first, "Changing 2"), (second, "Final")]
        # qs ipc exits 0 when a call is refused; only the answer says it ran.
        assert ipc("tracks", "\n".join(url + "\t" + title for url, title in burst)) == "ok"
        ready = wait_for(lambda s: s["state"] == "ready" and not s["busy"])
        assert ready["path"] != first_path and Path(ready["path"]).is_file()
        assert ready["starts"] == starts + 1 and len(jobs()) == count + 1, "a burst started more than one job"
        # A worker that can't start reports no exit: the job still ends (no
        # busy left behind, well before the 10 s watchdog), and later tracks
        # still get a worker.
        for name, color in [("unstartable.png", [9, 99, 199]), ("after.png", [199, 99, 9])]:
            (cache / name).write_bytes(artwork.encode_png(bytes(color) * 256 * 256))
        count = len(jobs())
        ipc("unstartable", "true")
        ipc("track", (cache / "unstartable.png").as_uri(), "Unstartable")
        started = time.monotonic()
        failed = wait_for(lambda s: s["state"] == "fallback" and not s["busy"])
        assert failed["error"] == "helper-exited", failed
        assert time.monotonic() - started < 5, "settled by the watchdog, not the failed start"
        assert len(jobs()) == count
        ipc("unstartable", "false")
        ipc("track", (cache / "after.png").as_uri(), "After")
        ready = wait_for(lambda s: s["state"] == "ready" and not s["busy"])
        assert Path(ready["path"]).is_file() and len(jobs()) == count + 1
        # No helper for this CPU (bash's exec exits 127): fallback, logged
        # once, and no helper is started for later tracks.
        helper.rename(helper.with_name("moved-away"))
        for index in range(3):
            (cache / f"other{index}.png").write_bytes(artwork.encode_png(bytes([index, 1, 2]) * 256 * 256))
        ipc("track", (cache / "other0.png").as_uri(), "Unavailable")
        unavailable = wait_for(lambda s: s["state"] == "fallback" and not s["busy"])
        assert unavailable["error"] == "helper-unavailable", unavailable
        for index in [1, 2]:
            ipc("track", (cache / f"other{index}.png").as_uri(), f"Unavailable {index}")
            state = status()
            assert state["state"] == "fallback" and state["error"] == "helper-unavailable" and not state["busy"], state
        helper.with_name("moved-away").rename(helper)
        ipc("enabled", "false")
        assert status()["state"] == "empty" and not status()["path"]
        assert log_path.read_text().count("foamy.lock artwork: helper-unavailable") == 1, "logged once"
        print(
            "PASS: real thumbnail, locked cache hit/miss, denied HTTPS, failure backoff, cancellation, stale result, coalescing, unstartable worker, unavailable helper, disabled artwork"
        )
    finally:
        shell.stop()
        print(log_path.read_text())
        print("Artwork runtime evidence:", base)
