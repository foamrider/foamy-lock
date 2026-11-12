// Video shell: a video background's switching on the real LockView, with
// clips the harness generated (never a user's file). The renderer here is
// software, so the tests set `gpuRendering` to reach the GPU path. Cases:
// what loads the clip (motion, a clip, GPU, the source), the poster shown
// until the first frame, what pauses it (blanked, hidden, on battery with
// and without pauseOnBattery), giving up after an error or a stall (once,
// poster back, never again for that view) and a hidden preview trying again.
// Written into a temporary app by the harness.
import QtQuick
import Quickshell
import "Layout.js" as Layout

ShellRoot {
  id: shellRoot
  property string label: ""
  property int caseAt: 0
  property int phase: 0
  property int failures: 0
  property string lastFailure: ""
  property var saved: null
  readonly property string clip: Quickshell.env("FOAMY_VIDEO_CLIP")
  readonly property string corrupt: Quickshell.env("FOAMY_VIDEO_CORRUPT")
  readonly property string poster: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")

  FloatingWindow {
    visible: true
    implicitWidth: 960
    implicitHeight: 540
    color: "black"
    LockView {
      id: view
      width: 960
      height: 540
      userName: "foamy"
      backgroundPath: shellRoot.poster
      fingerprintConfigured: true
      gpuRendering: true
      onBattery: false
      onVideoFailed: function (reason) {
        shellRoot.failures++
        shellRoot.lastFailure = reason
      }
    }
  }

  function findNamed(item, name) {
    if (item.objectName === name)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findNamed(item.children[i], name)
      if (found)
        return found
    }
    return null
  }
  function fail(message) {
    console.error("VIDEO_FAIL [" + label + "] " + message)
    step.running = false
    Qt.exit(1)
  }
  function expect(condition, message) {
    if (!condition)
      fail(message)
  }
  function look(background) {
    var parsed = Layout.parseLook({
      background: background
    })
    if (!parsed.valid)
      fail("invalid look: " + parsed.error)
    return parsed.look
  }
  function player() {
    return findNamed(view, "videoBackdrop")
  }
  function loaded() {
    return player() !== null
  }
  function wallpaper() {
    return findNamed(view, "lockWallpaper")
  }
  function playLook(extra) {
    var background = {
      source: "picture",
      path: "/videos/loop.mp4",
      motion: "play"
    }
    for (var key in extra || {})
      background[key] = extra[key]
    return look(background)
  }
  function reset() {
    view.videoPath = ""
    view.look = Layout.defaults()
    view.displayAwake = true
    view.visible = true
    view.onBattery = false
    view.gpuRendering = true
    view.loadBackground = true
    view.videoGaveUp = false
    failures = 0
    lastFailure = ""
  }

  // Each case: phases 0, 1, … one step apart; next() moves to the next case.
  property var cases: [
    {
      name: "what loads the clip",
      run: function (p) {
        if (p === 0) {
          reset()
          view.look = look({
            source: "picture",
            path: "/videos/loop.mp4"
          })
          view.videoPath = clip
          return false
        }
        if (p === 1) {
          expect(!loaded() && !view.videoWanted, "still: no clip loaded")
          view.look = playLook()
          view.videoPath = ""
          return false
        }
        if (p === 2) {
          expect(!loaded(), "play without a clip: nothing loaded")
          view.videoPath = clip
          view.gpuRendering = false
          return false
        }
        if (p === 3) {
          expect(!loaded(), "play under the software renderer: nothing loaded")
          view.gpuRendering = true
          view.look = look({
            source: "theme",
            motion: "play"
          })
          return false
        }
        if (p === 4) {
          expect(!loaded(), "play on a theme colour: nothing loaded")
          view.look = look({
            source: "omarchy",
            motion: "play"
          })
          return false
        }
        if (p === 5) {
          expect(loaded() && view.videoPlaying, "an Omarchy video wallpaper plays")
          view.loadBackground = false
          return false
        }
        expect(!loaded(), "a view that doesn't load its background loads no clip")
        return true
      }
    },
    {
      name: "poster first, then the clip",
      run: function (p) {
        if (p === 0) {
          reset()
          view.look = playLook()
          view.videoPath = clip
          return false
        }
        if (p === 1) {
          expect(loaded(), "the clip loads")
          expect(wallpaper().source.toString() !== "", "the poster is set")
          return false
        }
        // Up to a few steps for the first frame.
        expect(loaded(), "still loaded (failures " + failures + ": " + lastFailure + ")")
        if (!player().frameSeen && p < 16)
          return false
        expect(player().frameSeen, "a frame arrived from the clip (offscreen software playback)")
        expect(view.videoShown && !wallpaper().visible && player().visible, "the clip covers the poster once it has a frame")
        expect(player().playing, "it plays")
        return true
      }
    },
    {
      name: "what pauses it",
      run: function (p) {
        var item = player()
        if (p === 0) {
          expect(item && item.playing, "playing at the start")
          view.displayAwake = false
          return false
        }
        if (p === 1) {
          expect(loaded() && !item.playing && !view.videoPlaying, "blanked: paused, still loaded")
          saved = item.frames
          return false
        }
        if (p === 2) {
          expect(item.frames - saved <= 1, "no new frames while paused: " + (item.frames - saved))
          expect(view.videoShown, "the last frame stays")
          view.displayAwake = true
          return false
        }
        if (p === 3) {
          expect(item.playing, "awake: plays again")
          view.visible = false
          return false
        }
        if (p === 4) {
          expect(!item.playing, "hidden: paused")
          view.visible = true
          view.onBattery = true
          return false
        }
        if (p === 5) {
          expect(!item.playing, "on battery: paused (pauseOnBattery by default)")
          view.look = playLook({
            pauseOnBattery: false
          })
          return false
        }
        if (p === 6) {
          expect(player() && player().playing, "on battery with pauseOnBattery false: plays")
          view.onBattery = false
          view.look = playLook({
            motion: "still"
          })
          return false
        }
        expect(!loaded(), "back to still: the clip is unloaded")
        return true
      }
    },
    {
      name: "an error gives up for good",
      run: function (p) {
        if (p === 0) {
          reset()
          view.look = playLook()
          view.videoPath = corrupt
          return false
        }
        if (failures === 0 && p < 12)
          return false
        expect(failures === 1 && lastFailure === "error", "one failure, an error: " + failures + " " + lastFailure)
        expect(view.videoGaveUp && !loaded(), "gave up: unloaded")
        expect(wallpaper().visible, "the poster is back")
        if (p < 14)
          return false
        view.videoPath = clip
        if (p < 16)
          return false
        expect(!loaded() && failures === 1, "no second try in the same lock")
        return true
      }
    },
    {
      name: "a stall gives up",
      run: function (p) {
        if (p === 0) {
          reset()
          view.look = playLook()
          view.videoPath = clip
          return false
        }
        if (p === 1) {
          expect(loaded(), "loaded")
          player().stallMs = 0
          return false
        }
        if (failures === 0 && p < 8)
          return false
        expect(failures === 1 && lastFailure === "stall", "a stall: " + failures + " " + lastFailure)
        expect(!loaded() && view.videoFailure === "stall", "unloaded after the stall")
        return true
      }
    },
    {
      name: "a hidden preview tries again",
      run: function (p) {
        if (p === 0) {
          expect(view.videoGaveUp, "still given up")
          view.loadBackground = false
          return false
        }
        if (p === 1) {
          expect(!view.videoGaveUp && view.videoFailure === "", "hidden: reset")
          view.loadBackground = true
          return false
        }
        expect(loaded(), "shown again: the clip loads")
        return true
      }
    }
  ]

  Timer {
    id: step
    interval: 250
    repeat: true
    running: true
    onTriggered: {
      if (shellRoot.caseAt >= shellRoot.cases.length) {
        running = false
        console.log("VIDEO_PASS " + shellRoot.cases.length + " cases")
        Qt.exit(0)
        return
      }
      var current = shellRoot.cases[shellRoot.caseAt]
      shellRoot.label = current.name
      if (current.run(shellRoot.phase)) {
        console.log("video ok: " + current.name)
        shellRoot.caseAt++
        shellRoot.phase = 0
      } else {
        shellRoot.phase++
      }
    }
  }
}
