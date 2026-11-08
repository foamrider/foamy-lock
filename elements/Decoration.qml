pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// The look's shapes (background.shapes, Layout.js "shapes"): over the
// background and under the elements, in the order Layout.shapeRects gives
// (frosted shapes first, so their blur never cuts into another shape).
// Boxes and panels are a fill with a border; a panel's border can be only
// its inner edge. Frames are a bezel (a dark band to the screen's edge and
// a hairline), a glow in the accent (a line with fading rings) or the
// hairline alone. The geometry is LockView's `shapeGeometry` binding, so a
// shape around modules follows them in the same frame; nothing here
// animates. Shapes are background: no input, no focus, never checked
// against the field. Frost blurs the wallpaper behind a shape with a GPU
// renderer only (a Loader: nothing is created otherwise), and only over a
// picture: the drawn and solid sources have nothing to blur.
Item {
  id: decoration
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  readonly property var shapes: view.shapeGeometry || []
  readonly property bool gpu: view.gpuRendering && GraphicsInfo.api !== GraphicsInfo.Software
  readonly property bool canFrost: gpu && view.wallpaperItem !== null && view.pictureBackground

  // What it draws, in view coordinates and drawing order, for the tests:
  // { x, y, width, height, index, kind }, and `frame` for a frame.
  readonly property var surfaces: shapes.map(function(s) {
    var out = { x: s.x, y: s.y, width: s.width, height: s.height, index: s.index, kind: s.kind }
    if (s.kind === "frame") out.frame = true
    return out
  })

  // A shape's fill: the look's glass ("glass": the theme's glass at the
  // shape's opacity times the look's, opaque under the solid tint), the
  // modules' own glass ("surface") or black.
  function fillColor(spec) {
    if (!spec) return "transparent"
    if (spec.fill === "black") return Qt.rgba(0, 0, 0, spec.opacity)
    if (spec.fill === "surface") {
      const own = view.glassAt(spec.glass)
      return Qt.rgba(own.r, own.g, own.b, own.a * spec.opacity)
    }
    var base = view.glassBase
    var a = view.glassTint === "solid" ? Math.max(spec.opacity, 0.9) : spec.opacity
    return Qt.rgba(base.r, base.g, base.b, Math.min(1, a * view.effectiveLook.glass.opacity))
  }

  function borderColor(spec) {
    return spec && spec.border && spec.border.color === "accent" ? view.accent : view.glassBorder
  }

  objectName: "decoration"
  visible: shapes.length > 0
  clip: true

  // The wallpaper behind a shape, blurred.
  Component {
    id: frostComponent

    Item {
      id: frost
      readonly property var shape: parent
      anchors.fill: parent

      ShaderEffectSource {
        id: behind
        anchors.fill: parent
        visible: false
        sourceItem: decoration.view.wallpaperItem
        sourceRect: Qt.rect(frost.shape.x, frost.shape.y, frost.width, frost.height)
      }

      Rectangle {
        id: frostMask
        anchors.fill: parent
        radius: frost.shape && frost.shape.spec ? frost.shape.spec.radius : 0
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        anchors.fill: parent
        source: behind
        blurEnabled: true
        blur: 1
        blurMax: 48
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: frostMask
      }
    }
  }

  // One item per shape drawn: the count makes the delegates, so a shape
  // that moves only updates its geometry.
  Repeater {
    model: decoration.shapes.length

    Item {
      id: shape
      required property int index
      readonly property var spec: decoration.shapes[index] || null
      readonly property bool frame: spec !== null && spec.kind === "frame"
      objectName: "shape" + index
      // A frame draws over the whole view (its bezel reaches the edges).
      x: !spec || frame ? 0 : spec.x
      y: !spec || frame ? 0 : spec.y
      width: !spec ? 0 : frame ? decoration.view.width : spec.width
      height: !spec ? 0 : frame ? decoration.view.height : spec.height

      Loader {
        anchors.fill: parent
        active: shape.spec !== null && !shape.frame && shape.spec.frost && decoration.canFrost
        sourceComponent: frostComponent
      }

      Rectangle {
        objectName: "shapeFill"
        anchors.fill: parent
        visible: shape.spec !== null && !shape.frame
        radius: visible ? shape.spec.radius : 0
        color: visible ? decoration.fillColor(shape.spec) : "transparent"
        border.width: visible && shape.spec.border.sides === "all" ? shape.spec.border.width : 0
        border.color: decoration.borderColor(shape.spec)
      }

      // A panel's inner edge (its line is in view coordinates).
      Rectangle {
        objectName: "shapeLine"
        readonly property var line: shape.spec && !shape.frame ? shape.spec.line : null
        visible: !!line
        x: visible ? line.x - shape.x : 0
        y: visible ? line.y - shape.y : 0
        width: visible ? line.width : 0
        height: visible ? line.height : 0
        color: decoration.borderColor(shape.spec)
      }

      // A frame: the bezel from the screen edge to the inset (a wide border
      // whose inner edge has the frame's radius; the outer part is
      // clipped), then a hairline; or the accent glow, a line with fading
      // rings on both sides; or the hairline alone.
      Item {
        id: frameItem
        objectName: "shapeFrame"
        anchors.fill: parent
        visible: shape.frame
        readonly property string style: shape.frame ? shape.spec.style : ""
        readonly property real inset: shape.frame ? shape.spec.inset : 0
        readonly property real radius: shape.frame ? shape.spec.radius : 0
        readonly property bool glow: style === "glow"

        Rectangle {
          readonly property real band: frameItem.inset + frameItem.radius
          visible: frameItem.style === "bezel"
          x: frameItem.inset - band
          y: frameItem.inset - band
          width: frameItem.width - 2 * x
          height: frameItem.height - 2 * y
          radius: frameItem.radius + band
          color: "transparent"
          border.width: band
          border.color: Qt.rgba(0.008, 0.01, 0.018, 0.94)
        }

        Repeater {
          // Rings by offset from the frame line: negative ones lie outside it.
          model: !shape.frame ? [] : frameItem.glow ? [-5, -4, -3, -2, -1, 1, 2, 3, 4, 5, 0] : [0]

          Rectangle {
            required property int modelData
            readonly property real step: Math.max(1, Math.round(2 * decoration.view.uiScale))
            readonly property real offset: modelData * step
            x: frameItem.inset + offset
            y: frameItem.inset + offset
            width: frameItem.width - 2 * x
            height: frameItem.height - 2 * y
            radius: Math.max(0, frameItem.radius - offset)
            color: "transparent"
            border.width: modelData === 0 && frameItem.glow ? Math.max(2, Math.round(2.5 * decoration.view.uiScale)) : step
            border.color: !frameItem.glow ? decoration.view.glassBorder
              : Qt.rgba(decoration.view.accent.r, decoration.view.accent.g, decoration.view.accent.b,
                modelData === 0 ? 1 : 0.32 / Math.abs(modelData))
          }
        }
      }
    }
  }
}
