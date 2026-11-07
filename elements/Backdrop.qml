import QtQuick
import "../kit"

// The drawn background sources, in the theme's colours over its background:
// - "aurora": soft bands of the accent, green and cyan drifting slowly;
// - "rain": thin streaks falling at different speeds;
// - "constellation": a field of stars and one figure of lines; each typed
//   character lights the next star of the figure, as the dots in the field do.
// Everything is plain Rectangles and a few Canvas gradients painted once, so
// every renderer draws it. It moves only while `moving`: the view is shown,
// the display is awake, animations are on and the GPU renders (a software
// renderer would repaint the whole screen for every step). Otherwise it holds
// a still frame, the same one the previews show. Each motion repeats exactly
// after `loop` seconds, so the loop has no seam.
Item {
  id: backdrop
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  property string source: "aurora"
  readonly property real unit: view.uiScale
  readonly property real loop: 60
  readonly property real stillPhase: stillPhaseOf(source)
  readonly property bool moving: visible && width > 0 && height > 0 && view.motionAllowed
  // Seconds into the loop.
  property real phase: stillPhase
  readonly property real turn: 2 * Math.PI * phase / loop

  readonly property color accent: view.accent
  readonly property color green: FoamyPalette.success
  readonly property color cyan: FoamyPalette.info

  objectName: "backdrop"
  clip: true

  // A switch of source starts from its still frame (read through the
  // function: the stillPhase binding may not have updated yet here).
  onSourceChanged: phase = stillPhaseOf(source)

  // The frame shown without motion (and in the previews), per source.
  function stillPhaseOf(name) {
    return name === "aurora" ? 21 : name === "rain" ? 4.4 : 7
  }

  // A cheap stand-in for an animation: one step per tick, only while it can
  // be seen and Omarchy's animations are on (reduced motion holds the frame).
  Timer {
    interval: backdrop.source === "rain" ? 40 : backdrop.source === "aurora" ? 66 : 100
    repeat: true
    running: backdrop.moving && !backdrop.view.reduceMotion
    onTriggered: backdrop.phase = (backdrop.phase + interval / 1000) % backdrop.loop
  }

  // A stable pseudo-random number in [0, 1) for (index, salt).
  function noise(index, salt) {
    var h = Math.imul(index + 1, 374761393) ^ Math.imul(salt + 7, 668265263)
    h = Math.imul(h ^ (h >>> 13), 1274126177)
    h = h ^ (h >>> 16)
    return (h >>> 0) / 4294967296
  }

  // aurora: wide soft bands, each a radial gradient painted once at a small
  // size and stretched (the GPU or the software rasteriser smooths it).
  Item {
    id: aurora
    objectName: "backdropAurora"
    anchors.fill: parent
    visible: backdrop.source === "aurora"

    Repeater {
      model: aurora.visible ? [
        { tint: backdrop.accent, x: 0.22, y: 0.3, w: 1.05, h: 0.6, ax: 0.1, ay: 0.06, fx: 1, fy: 2, p: 0.4, a: 0.6 },
        { tint: backdrop.green, x: 0.68, y: 0.22, w: 0.95, h: 0.5, ax: 0.12, ay: 0.05, fx: 2, fy: 1, p: 2.1, a: 0.5 },
        { tint: backdrop.cyan, x: 0.5, y: 0.62, w: 1.15, h: 0.55, ax: 0.14, ay: 0.07, fx: 1, fy: 1, p: 4.0, a: 0.42 },
        { tint: Qt.lighter(backdrop.accent, 1.35), x: 0.86, y: 0.72, w: 0.8, h: 0.5, ax: 0.08, ay: 0.08, fx: 3, fy: 2, p: 1.2, a: 0.36 },
        { tint: backdrop.green, x: 0.1, y: 0.82, w: 0.8, h: 0.45, ax: 0.07, ay: 0.05, fx: 2, fy: 3, p: 5.2, a: 0.3 }
      ] : []

      Item {
        id: band
        required property var modelData
        readonly property real bandWidth: backdrop.width * modelData.w
        readonly property real bandHeight: backdrop.height * modelData.h
        x: backdrop.width * (modelData.x + modelData.ax * Math.sin(modelData.fx * backdrop.turn + modelData.p)) - bandWidth / 2
        y: backdrop.height * (modelData.y + modelData.ay * Math.cos(modelData.fy * backdrop.turn + modelData.p)) - bandHeight / 2
        width: bandWidth
        height: bandHeight

        Canvas {
          readonly property string paintKey: String(band.modelData.tint) + band.modelData.a
          width: 128
          height: 128
          smooth: true
          transform: Scale { xScale: band.bandWidth / 128; yScale: band.bandHeight / 128 }
          onPaintKeyChanged: requestPaint()
          // A threaded (GPU) renderer makes the canvas available a frame
          // late; a request before that is dropped.
          onAvailableChanged: if (available) requestPaint()
          Component.onCompleted: requestPaint()
          onPaint: {
            var context = getContext("2d")
            context.reset()
            var tint = band.modelData.tint
            var gradient = context.createRadialGradient(64, 64, 0, 64, 64, 64)
            gradient.addColorStop(0, Qt.rgba(tint.r, tint.g, tint.b, band.modelData.a))
            gradient.addColorStop(0.45, Qt.rgba(tint.r, tint.g, tint.b, band.modelData.a * 0.45))
            gradient.addColorStop(1, Qt.rgba(tint.r, tint.g, tint.b, 0))
            context.fillStyle = gradient
            context.fillRect(0, 0, 128, 128)
          }
        }
      }
    }
  }

  // rain: streaks with a bright head, each falling a whole number of times
  // per loop.
  Item {
    id: rain
    objectName: "backdropRain"
    anchors.fill: parent
    visible: backdrop.source === "rain"
    readonly property real spacing: Math.round(26 * backdrop.unit)

    Repeater {
      model: rain.visible ? Math.ceil(backdrop.width / rain.spacing) : 0

      Rectangle {
        id: streak
        required property int index
        readonly property real length: backdrop.height * (0.1 + 0.22 * backdrop.noise(index, 1))
        readonly property int laps: 5 + Math.floor(backdrop.noise(index, 2) * 9)
        readonly property real start: backdrop.noise(index, 3)
        readonly property real travel: backdrop.height + length
        readonly property real progress: (start + laps * backdrop.phase / backdrop.loop) % 1
        x: (index + 0.5 * backdrop.noise(index, 4)) * rain.spacing
        y: progress * travel - length
        width: Math.max(1, Math.round((backdrop.noise(index, 5) > 0.7 ? 3 : 2) * backdrop.unit))
        height: length
        radius: width / 2
        opacity: 0.25 + 0.55 * backdrop.noise(index, 6)
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(backdrop.accent.r, backdrop.accent.g, backdrop.accent.b, 0) }
          GradientStop { position: 0.85; color: Qt.rgba(backdrop.accent.r, backdrop.accent.g, backdrop.accent.b, 0.7) }
          GradientStop { position: 1; color: Qt.lighter(backdrop.accent, 1.5) }
        }
      }
    }
  }

  // constellation: faint stars that twinkle, and a figure across the upper
  // half whose stars and lines light up with the typed characters.
  Item {
    id: sky
    objectName: "backdropConstellation"
    anchors.fill: parent
    visible: backdrop.source === "constellation"
    readonly property int figureSize: 12
    readonly property int lit: Math.min(backdrop.view.passwordText.length, figureSize)
    readonly property var figure: {
      var points = []
      for (var i = 0; i < figureSize; i++)
        points.push({ x: 0.1 + 0.8 * (i + 0.5 * backdrop.noise(i, 11)) / figureSize, y: 0.14 + 0.32 * backdrop.noise(i, 12) })
      return points
    }

    Repeater {
      model: sky.visible ? 150 : 0

      Rectangle {
        required property int index
        readonly property real size: Math.max(1, Math.round((1 + 2.2 * Math.pow(backdrop.noise(index, 21), 3)) * backdrop.unit))
        readonly property real twinkle: 0.7 + 0.3 * Math.sin((1 + index % 4) * backdrop.turn + 6.28 * backdrop.noise(index, 22))
        x: backdrop.noise(index, 23) * backdrop.width
        y: backdrop.noise(index, 24) * backdrop.height
        width: size
        height: size
        radius: size / 2
        color: backdrop.view.foreground
        opacity: (0.18 + 0.5 * backdrop.noise(index, 25)) * twinkle
      }
    }

    Repeater {
      model: sky.visible ? sky.figureSize - 1 : 0

      Rectangle {
        required property int index
        readonly property var from: sky.figure[index]
        readonly property var to: sky.figure[index + 1]
        readonly property real dx: (to.x - from.x) * backdrop.width
        readonly property real dy: (to.y - from.y) * backdrop.height
        x: from.x * backdrop.width
        y: from.y * backdrop.height
        width: Math.sqrt(dx * dx + dy * dy)
        height: Math.max(1, Math.round(1.5 * backdrop.unit))
        transformOrigin: Item.Left
        rotation: Math.atan2(dy, dx) * 180 / Math.PI
        color: index + 1 < sky.lit ? backdrop.accent : backdrop.view.foreground
        opacity: index + 1 < sky.lit ? 0.7 : 0.14
      }
    }

    Repeater {
      model: sky.visible ? sky.figureSize : 0

      Rectangle {
        required property int index
        readonly property bool on: index < sky.lit
        readonly property real size: Math.round((on ? 9 : 5) * backdrop.unit)
        x: sky.figure[index].x * backdrop.width - size / 2
        y: sky.figure[index].y * backdrop.height - size / 2
        width: size
        height: size
        radius: size / 2
        color: on ? backdrop.accent : backdrop.view.foreground
        opacity: on ? 1 : 0.45
        border.width: on ? Math.max(1, Math.round(3 * backdrop.unit)) : 0
        border.color: Qt.rgba(backdrop.accent.r, backdrop.accent.g, backdrop.accent.b, 0.35)
      }
    }
  }
}
