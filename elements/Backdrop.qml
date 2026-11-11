import QtQuick
import qs.Commons as Commons
import "../kit"
import "BackdropStill.js" as Still

// The drawn background sources (the animations, Layout.DRAWN_SOURCES), in the
// theme's colours over its background; each shader in shaders/ describes its
// picture. The older "constellation" draws "stars", with a figure whose stars
// light up with the typed characters (below).
// With the GPU a fragment shader per animation draws it (shaders/, compiled
// with shaders/build.sh), every frame while `moving`: the view is shown,
// the display is awake, animations are on and the GPU renders. Otherwise it
// holds a frame: the GPU keeps the shader's last frame (it costs nothing
// until something changes), and the software renderer (CPU rendering, the
// tests) gets a still frame painted once by BackdropStill.js, the same
// picture as the shader's at `stillPhase`. A hidden backdrop loads neither.
// Every motion repeats exactly after `loop` seconds, so the loop has no seam.
Item {
  id: backdrop
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  property string source: "aurora"
  // The animation drawn: the source, the older "constellation" as "stars".
  readonly property string kind: source === "constellation" ? "stars" : source
  readonly property real unit: view.uiScale
  readonly property real loop: 120
  readonly property real stillPhase: stillPhaseOf(source)
  readonly property bool moving: visible && width > 0 && height > 0 && view.motionAllowed
  // Seconds into the loop.
  property real phase: stillPhase

  // The renderer, once the item is in a window (nothing is drawn before).
  readonly property int api: GraphicsInfo.api
  property bool shaderFailed: false
  readonly property bool shaded: api !== GraphicsInfo.Unknown && api !== GraphicsInfo.Software && !shaderFailed
  readonly property bool painted: api !== GraphicsInfo.Unknown && !shaded

  // The picture is drawn for the lock's text, which sits on it: under light
  // text (the lock's own white glass, which a theme changes only with a
  // [lock] section, so on almost every theme, light ones too) it is dark,
  // and light adds up as a glow; under dark text it is light, and light
  // paints over. Its ground is the theme's background when that already has
  // the right lightness; otherwise a tone of the theme's own text colour (a
  // light theme's dark text, deepened), so it still looks like the theme.
  readonly property color themeBase: Commons.Color.background
  readonly property color themeText: Commons.Color.foreground
  readonly property bool lightText: lightness(view.foreground) >= 0.5
  readonly property bool themeDark: lightness(themeBase) < 0.5
  readonly property color base: lightText === themeDark ? themeBase : lightText ? scaled(themeText, Math.min(0.55, 0.12 / Math.max(0.01, lightness(themeText)))) : Qt.rgba(1 - (1 - themeText.r) * 0.25, 1 - (1 - themeText.g) * 0.25, 1 - (1 - themeText.b) * 0.25, 1)
  readonly property color accent: view.accent
  readonly property color green: FoamyPalette.success
  readonly property color cyan: FoamyPalette.info
  readonly property color warm: FoamyPalette.warning
  // Light adds up over a dark picture (a glow) and paints over a light one.
  readonly property real glow: lightText ? 1 : 0
  // Stars, flakes and foam: the lock's foreground over a dark picture, the
  // theme's (dark) text colour over a light one.
  readonly property color ink: glow > 0 ? view.foreground : themeText

  function lightness(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  function scaled(c, k) {
    return Qt.rgba(c.r * k, c.g * k, c.b * k, 1)
  }

  objectName: "backdrop"
  clip: true

  // A switch of source starts from its still frame (read through the
  // function: the stillPhase binding may not have updated yet here).
  onSourceChanged: {
    phase = stillPhaseOf(source)
    shaderFailed = false
  }

  // The frame shown without motion (and in the previews), per source.
  function stillPhaseOf(name) {
    return Still.stillPhase(name === "constellation" ? "stars" : name)
  }

  // One step per frame, only while it can be seen and Omarchy's animations
  // are on (reduced motion holds the frame).
  FrameAnimation {
    running: backdrop.moving && !backdrop.view.reduceMotion
    onTriggered: backdrop.phase = (backdrop.phase + Math.min(frameTime, 0.1)) % backdrop.loop
  }

  // A stable pseudo-random number in [0, 1) for (index, salt).
  function noise(index, salt) {
    var h = Math.imul(index + 1, 374761393) ^ Math.imul(salt + 7, 668265263)
    h = Math.imul(h ^ (h >>> 13), 1274126177)
    h = h ^ (h >>> 16)
    return (h >>> 0) / 4294967296
  }

  // The GPU: the animation's shader.
  Loader {
    objectName: "backdropShader"
    anchors.fill: parent
    active: backdrop.shaded && backdrop.visible
    sourceComponent: ShaderEffect {
      vertexShader: "shaders/backdrop.vert.qsb"
      fragmentShader: "shaders/" + backdrop.kind + ".frag.qsb"
      property vector2d u_size: Qt.vector2d(width, height)
      property real u_time: backdrop.phase
      property real u_loop: backdrop.loop
      property real u_unit: backdrop.unit
      property real u_glow: backdrop.glow
      property color u_base: backdrop.base
      property color u_accent: backdrop.accent
      property color u_green: backdrop.green
      property color u_cyan: backdrop.cyan
      property color u_ink: backdrop.ink
      property color u_warm: backdrop.warm
      onStatusChanged: {
        if (status === ShaderEffect.Error) {
          console.warn("The " + backdrop.kind + " background's shader failed; showing its still frame:", log)
          backdrop.shaderFailed = true
        }
      }
    }
  }

  // The software renderer: the still frame, painted once per size, colours
  // and phase. The smooth parts at a fraction of the size, scaled up; the
  // points (stars, drops, flakes, glyphs) at the screen's size, at most
  // 1920 wide, scaled from there.
  Loader {
    objectName: "backdropStill"
    anchors.fill: parent
    active: backdrop.painted && backdrop.visible
    sourceComponent: Item {
      id: still
      readonly property var scene: Still.scene(backdrop.kind, backdrop.width, backdrop.height, backdrop.phase, backdrop.loop, backdrop.unit, backdrop.glow, {
        base: backdrop.base,
        accent: backdrop.accent,
        green: backdrop.green,
        cyan: backdrop.cyan,
        ink: backdrop.ink,
        warm: backdrop.warm
      })
      // The scene by value: a binding that recomputes the same scene paints nothing.
      readonly property string key: JSON.stringify(scene)
      readonly property real pointScale: Math.min(1, 1920 / Math.max(1, backdrop.width))

      Canvas {
        id: field
        readonly property real fraction: Still.fieldFraction(backdrop.kind)
        width: Math.max(1, Math.round(backdrop.width * fraction))
        height: Math.max(1, Math.round(backdrop.height * fraction))
        smooth: true
        transform: Scale {
          xScale: backdrop.width / field.width
          yScale: backdrop.height / field.height
        }
        // Painted once per scene (a threaded renderer makes the canvas
        // available a frame late, and a request before that is dropped).
        readonly property string want: still.key
        property string done: ""
        onWantChanged: requestPaint()
        onAvailableChanged: if (available && done !== want)
          requestPaint()
        // Qt asks again for the same scene (a grab, an expose); the picture is
        // still there.
        onPaint: {
          if (done === want)
            return
          done = want
          Still.paintField(getContext("2d"), width, height, still.scene)
        }
      }

      Canvas {
        id: points
        width: Math.max(1, Math.round(backdrop.width * still.pointScale))
        height: Math.max(1, Math.round(backdrop.height * still.pointScale))
        smooth: true
        transform: Scale {
          xScale: 1 / still.pointScale
          yScale: 1 / still.pointScale
        }
        readonly property string want: still.key
        property string done: ""
        onWantChanged: requestPaint()
        onAvailableChanged: if (available && done !== want)
          requestPaint()
        onPaint: {
          if (done === want)
            return
          done = want
          Still.paintPoints(getContext("2d"), width, height, still.scene)
        }
      }
    }
  }

  // stars: a figure across the upper half whose stars and lines light up
  // with the typed characters (over the field, on every renderer).
  Item {
    id: sky
    objectName: "backdropFigure"
    anchors.fill: parent
    visible: backdrop.kind === "stars"
    readonly property int figureSize: 12
    readonly property int lit: Math.min(backdrop.view.passwordText.length, figureSize)
    readonly property var figure: {
      var points = []
      for (var i = 0; i < figureSize; i++)
        points.push({
          x: 0.1 + 0.8 * (i + 0.5 * backdrop.noise(i, 11)) / figureSize,
          y: 0.14 + 0.32 * backdrop.noise(i, 12)
        })
      return points
    }

    Repeater {
      model: sky.visible ? sky.figureSize - 1 : 0

      Rectangle {
        required property int index
        readonly property var from: sky.figure[index]
        readonly property var to: sky.figure[index + 1]
        readonly property real dx: (to.x - from.x) * backdrop.width
        readonly property real dy: (to.y - from.y) * backdrop.height
        readonly property bool on: index + 1 < sky.lit
        x: from.x * backdrop.width
        y: from.y * backdrop.height
        width: Math.sqrt(dx * dx + dy * dy)
        height: Math.max(1, Math.round(1.2 * backdrop.unit))
        transformOrigin: Item.Left
        rotation: Math.atan2(dy, dx) * 180 / Math.PI
        color: on ? backdrop.accent : backdrop.ink
        opacity: on ? 0.6 : 0.06
      }
    }

    Repeater {
      model: sky.visible ? sky.figureSize : 0

      Rectangle {
        required property int index
        readonly property bool on: index < sky.lit
        readonly property real size: Math.round((on ? 7 : 4) * backdrop.unit)
        x: sky.figure[index].x * backdrop.width - size / 2
        y: sky.figure[index].y * backdrop.height - size / 2
        width: size
        height: size
        radius: size / 2
        color: on ? backdrop.accent : backdrop.ink
        opacity: on ? 1 : 0.5
        border.width: on ? Math.max(1, Math.round(3 * backdrop.unit)) : 0
        border.color: Qt.rgba(backdrop.accent.r, backdrop.accent.g, backdrop.accent.b, 0.35)
      }
    }
  }
}
