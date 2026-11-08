import QtQuick
import QtQuick.Effects

// Shapes over the background and under the elements, fitted to the zones
// they belong to, so they follow the elements to narrow screens and mirror
// with them in right-to-left languages. The geometry check treats them as
// background: they never take part in it and never cover anything. Kinds:
// - "split": a solid panel on the start side, at least 38% wide and as wide
//   as the start column needs, with an accent edge; past 62% of the width
//   (a narrow screen) it fills the screen.
// - "sheet": a frosted panel on the end side around the end column.
// - "cinema": black bars at the top and bottom, tall enough for the top and
//   bottom rows.
// - "strip": a band behind the bottom row.
// - "island": a pill around the top-center stack.
// - "frame": a border inset from the screen's edges: a glow in the accent
//   with the accent tint, otherwise a dark bezel with a hairline.
// - "card": a glass card behind the middle-center stack.
// Positions are plain x/y bindings (no anchors switched at runtime). The
// frosting of the sheet and card needs a GPU renderer; without one they are
// the same translucent glass, unblurred.
Item {
  id: decoration
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  property string kind: "none"
  readonly property real unit: view.uiScale
  readonly property bool rtl: view.rightToLeft
  readonly property bool gpu: GraphicsInfo.api !== GraphicsInfo.Software
  readonly property bool glow: view.glassTint === "accent"

  readonly property var topRow: kind === "cinema" ? view.zonesRect(["top-start", "top-center", "top-end"]) : null
  readonly property var bottomRow: kind === "cinema" || kind === "strip"
    ? view.zonesRect(["bottom-start", "bottom-center", "bottom-end"]) : null

  readonly property var splitRect: {
    if (kind !== "split") return null
    // Narrow screens centre the bottom corners: the panel widens to hold them.
    var held = view.zonesRect(["top-start", "middle-start", "bottom-start"].concat(view.compactLayout ? ["bottom-end"] : []))
    var extent = !held ? 0 : rtl ? view.width - held.x : held.x + held.width
    var width = Math.max(Math.round(view.width * 0.38), Math.round(extent + 56 * unit))
    if (width > view.width * 0.62) width = view.width
    return { x: rtl ? view.width - width : 0, y: 0, width: width, height: view.height }
  }
  readonly property var sheetRect: {
    if (kind !== "sheet") return null
    var margin = Math.round(24 * unit)
    // Narrow screens centre the bottom corners: the panel widens to hold them.
    var held = view.zonesRect(["top-end", "middle-end"].concat(view.compactLayout ? ["bottom-start", "bottom-end"] : ["bottom-end"]))
    var extent = !held ? 0 : rtl ? held.x + held.width : view.width - held.x
    var width = Math.min(view.width - 2 * margin, Math.max(Math.round(420 * unit), Math.round(extent - margin + 44 * unit)))
    return { x: rtl ? margin : view.width - margin - width, y: margin, width: width, height: view.height - 2 * margin }
  }
  readonly property var cinemaRects: {
    if (kind !== "cinema") return null
    var pad = Math.round(26 * unit)
    var least = Math.round(view.height * 0.12), most = Math.round(view.height * 0.4)
    var top = Math.min(most, Math.max(least, topRow ? Math.ceil(topRow.y + topRow.height + pad) : 0))
    var bottom = Math.min(most, Math.max(least, bottomRow ? Math.ceil(view.height - bottomRow.y + pad) : 0))
    return [{ x: 0, y: 0, width: view.width, height: top },
      { x: 0, y: view.height - bottom, width: view.width, height: bottom }]
  }
  readonly property var stripRect: {
    if (kind !== "strip" || !bottomRow) return null
    var margin = Math.round(16 * unit), pad = Math.round(14 * unit)
    var top = Math.floor(bottomRow.y - pad)
    var bottom = Math.min(view.height - margin, Math.ceil(bottomRow.y + bottomRow.height + pad))
    return { x: margin, y: top, width: view.width - 2 * margin, height: bottom - top }
  }
  readonly property var islandRect: {
    if (kind !== "island") return null
    var held = view.zonesRect(["top-center"])
    if (!held) return null
    var padX = Math.round(34 * unit), padY = Math.round(12 * unit)
    return { x: Math.floor(held.x - padX), y: Math.floor(held.y - padY),
      width: Math.ceil(held.width + 2 * padX), height: Math.ceil(held.height + 2 * padY) }
  }
  readonly property var cardRect: {
    if (kind !== "card") return null
    var held = view.zonesRect(["middle-center"])
    if (!held) return null
    var pad = Math.round(36 * unit)
    return { x: Math.floor(held.x - pad), y: Math.floor(held.y - pad),
      width: Math.ceil(held.width + 2 * pad), height: Math.ceil(held.height + 2 * pad) }
  }
  readonly property real frameInset: Math.round(12 * unit)
  readonly property real frameRadius: Math.round(22 * unit)
  readonly property var frameRect: kind !== "frame" ? null
    : { x: frameInset, y: frameInset, width: view.width - 2 * frameInset, height: view.height - 2 * frameInset }

  // What it draws, in view coordinates, for the tests: each element must sit
  // wholly inside or wholly outside a surface, and inside the frame.
  readonly property var surfaces: {
    var out = []
    var single = [splitRect, sheetRect, stripRect, islandRect, cardRect]
    for (var i = 0; i < single.length; i++) if (single[i]) out.push(single[i])
    if (cinemaRects) out = out.concat(cinemaRects)
    if (frameRect) out.push({ x: frameRect.x, y: frameRect.y, width: frameRect.width, height: frameRect.height, frame: true })
    return out
  }

  // The glass colour at `alpha` (scaled by the look's glass opacity); the
  // solid tint makes it opaque.
  function fill(alpha) {
    var base = view.glassBase
    var a = view.glassTint === "solid" ? Math.max(alpha, 0.9) : alpha
    return Qt.rgba(base.r, base.g, base.b, Math.min(1, a * view.effectiveLook.glass.opacity))
  }

  objectName: "decoration"
  visible: kind !== "none"
  clip: true

  // The wallpaper behind a panel, blurred (GPU only; never the drawn
  // sources, which are soft already).
  component Frost: Item {
    id: frost
    property real cornerRadius: 0
    visible: decoration.gpu && decoration.view.wallpaperItem !== null && width > 0 && height > 0

    ShaderEffectSource {
      id: behind
      anchors.fill: parent
      visible: false
      sourceItem: frost.visible ? decoration.view.wallpaperItem : null
      sourceRect: Qt.rect(frost.x, frost.y, frost.width, frost.height)
    }

    Rectangle {
      id: frostMask
      anchors.fill: parent
      radius: frost.cornerRadius
      visible: false
      layer.enabled: frost.visible
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

  // split
  Rectangle {
    objectName: "decorSplit"
    visible: decoration.splitRect !== null
    x: visible ? decoration.splitRect.x : 0
    y: 0
    width: visible ? decoration.splitRect.width : 0
    height: decoration.view.height
    color: decoration.fill(0.9)
  }

  Rectangle {
    visible: decoration.splitRect !== null && decoration.splitRect.width < decoration.view.width
    width: Math.max(2, Math.round(3 * decoration.unit))
    x: !visible ? 0 : decoration.rtl ? decoration.splitRect.x : decoration.splitRect.x + decoration.splitRect.width - width
    height: decoration.view.height
    color: decoration.view.accent
  }

  // sheet
  Frost {
    visible: decoration.sheetRect !== null && decoration.gpu && decoration.view.wallpaperItem !== null
    x: decoration.sheetRect ? decoration.sheetRect.x : 0
    y: decoration.sheetRect ? decoration.sheetRect.y : 0
    width: decoration.sheetRect ? decoration.sheetRect.width : 0
    height: decoration.sheetRect ? decoration.sheetRect.height : 0
    cornerRadius: Math.round(28 * decoration.unit)
  }

  Rectangle {
    objectName: "decorSheet"
    visible: decoration.sheetRect !== null
    x: visible ? decoration.sheetRect.x : 0
    y: visible ? decoration.sheetRect.y : 0
    width: visible ? decoration.sheetRect.width : 0
    height: visible ? decoration.sheetRect.height : 0
    radius: Math.round(28 * decoration.unit)
    color: decoration.fill(0.55)
    border.width: 1
    border.color: decoration.view.glassBorder
  }

  // cinema
  Repeater {
    model: decoration.cinemaRects ? decoration.cinemaRects : []

    Rectangle {
      required property var modelData
      objectName: "decorCinema"
      x: modelData.x
      y: modelData.y
      width: modelData.width
      height: modelData.height
      color: Qt.rgba(0, 0, 0, 1)
    }
  }

  // strip
  Rectangle {
    objectName: "decorStrip"
    visible: decoration.stripRect !== null
    x: visible ? decoration.stripRect.x : 0
    y: visible ? decoration.stripRect.y : 0
    width: visible ? decoration.stripRect.width : 0
    height: visible ? decoration.stripRect.height : 0
    radius: Math.round(20 * decoration.unit)
    color: decoration.fill(0.72)
    border.width: 1
    border.color: decoration.view.glassBorder
  }

  // island
  Rectangle {
    objectName: "decorIsland"
    visible: decoration.islandRect !== null
    x: visible ? decoration.islandRect.x : 0
    y: visible ? decoration.islandRect.y : 0
    width: visible ? decoration.islandRect.width : 0
    height: visible ? decoration.islandRect.height : 0
    radius: Math.min(height / 2, Math.round(40 * decoration.unit))
    color: decoration.view.glassTint === "none" ? Qt.rgba(0, 0, 0, 0.82) : decoration.fill(0.86)
    border.width: 1
    border.color: decoration.view.glassBorder
  }

  // card
  Frost {
    visible: decoration.cardRect !== null && decoration.gpu && decoration.view.wallpaperItem !== null
    x: decoration.cardRect ? decoration.cardRect.x : 0
    y: decoration.cardRect ? decoration.cardRect.y : 0
    width: decoration.cardRect ? decoration.cardRect.width : 0
    height: decoration.cardRect ? decoration.cardRect.height : 0
    cornerRadius: Math.round(30 * decoration.unit)
  }

  Rectangle {
    objectName: "decorCard"
    visible: decoration.cardRect !== null
    x: visible ? decoration.cardRect.x : 0
    y: visible ? decoration.cardRect.y : 0
    width: visible ? decoration.cardRect.width : 0
    height: visible ? decoration.cardRect.height : 0
    radius: Math.round(30 * decoration.unit)
    color: decoration.fill(0.5)
    border.width: 1
    border.color: decoration.view.glassBorder
  }

  // frame: a bezel from the screen edge to the inset (a wide border whose
  // inner edge has the frame's radius; the outer part is clipped), then a
  // hairline, or the accent glow: a line with fading rings on both sides.
  Item {
    objectName: "decorFrame"
    visible: decoration.frameRect !== null
    anchors.fill: parent

    Rectangle {
      readonly property real band: decoration.frameInset + decoration.frameRadius
      visible: !decoration.glow
      x: decoration.frameInset - band
      y: decoration.frameInset - band
      width: decoration.view.width - 2 * x
      height: decoration.view.height - 2 * y
      radius: decoration.frameRadius + band
      color: "transparent"
      border.width: band
      border.color: Qt.rgba(0.008, 0.01, 0.018, 0.94)
    }

    Repeater {
      // Rings by offset from the frame line: negative ones lie outside it.
      model: decoration.glow ? [-5, -4, -3, -2, -1, 1, 2, 3, 4, 5, 0] : [0]

      Rectangle {
        required property int modelData
        readonly property real step: Math.max(1, Math.round(2 * decoration.unit))
        readonly property real offset: modelData * step
        x: decoration.frameInset + offset
        y: decoration.frameInset + offset
        width: decoration.view.width - 2 * x
        height: decoration.view.height - 2 * y
        radius: Math.max(0, decoration.frameRadius - offset)
        color: "transparent"
        border.width: modelData === 0 && decoration.glow ? Math.max(2, Math.round(2.5 * decoration.unit)) : step
        border.color: !decoration.glow ? decoration.view.glassBorder
          : Qt.rgba(decoration.view.accent.r, decoration.view.accent.g, decoration.view.accent.b,
            modelData === 0 ? 1 : 0.32 / Math.abs(modelData))
      }
    }
  }
}
