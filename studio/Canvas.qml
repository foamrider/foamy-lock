pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons as Commons
import "kit"
import "Layout.js" as Layout
import "Draft.js" as Draft

// The live canvas: the real lock screen (SampleView) at the chosen screen's
// logical size, scaled to fit, with the editor drawn over it: zones, the
// selection and its handles, snap guides and problem outlines.
//
// Editing: drag a module to move it (snapping; Shift held is free, Alt
// holds the axis it started along), drag a corner to scale it, or use the
// keyboard (see keyPressed). Mid-drag the module moves by an offset in its
// own zone; the drop picks the zone (Draft.drop) and emits `edited` once.
// Shift and Alt are read from key presses and releases as well as from the
// pointer, so pressing one mid-drag takes effect without moving.
FocusScope {
  id: canvas

  property var draft: ({ preset: Layout.DEFAULT_PRESET })
  property string selected: ""
  property int screenWidth: 1920
  property int screenHeight: 1080
  // "idle", "typing", "wrong" or "noMedia".
  property string previewState: "idle"
  property bool showZones: true
  property bool snapping: true
  // The window can be seen: drawn backgrounds move only then.
  property bool awake: true
  // Modules to outline as a problem on this screen.
  property var problemNames: []
  // Accessible description of the selection (the window words it).
  property string selectionText: ""

  signal edited(var draft)
  signal selectRequested(string name)

  readonly property var look: Draft.lookOf(draft)
  // The look while a drag or resize is shown; null otherwise.
  property var liveLook: null
  // { mode: "move" | "resize", name, start, … } while one runs.
  property var gesture: null
  property bool shiftHeld: false
  property bool altHeld: false
  readonly property bool rightToLeft: view.rightToLeft
  readonly property real zoom: Math.max(0.01, Math.min((stageArea.width - 2) / screenWidth, (stageArea.height - 2) / screenHeight))
  readonly property alias view: view
  readonly property var rects: view.elementRects
  readonly property var selectedRect: selected && rects[selected] ? rects[selected] : null

  activeFocusOnTab: true
  Accessible.role: Accessible.Graphic
  Accessible.name: FoamyI18n.t("studio.canvas")
  Accessible.description: selectionText

  Keys.onPressed: function(event) { if (canvas.keyPressed(event.key, event.modifiers)) event.accepted = true }
  Keys.onReleased: function(event) { if (canvas.keyReleased(event.key, event.modifiers)) event.accepted = true }
  onActiveFocusChanged: if (!activeFocus) { shiftHeld = false; altHeld = false }

  function geometry() {
    return { width: screenWidth, height: screenHeight, margin: Math.round(4 * view.uiScale), rightToLeft: rightToLeft }
  }

  // The topmost module under a point in view pixels: the selected one when
  // it's there, else the smallest.
  function hit(x, y) {
    var best = "", area = Infinity
    for (var name in rects) {
      var r = rects[name]
      if (x < r.x || y < r.y || x > r.x + r.width || y > r.y + r.height) continue
      if (name === selected) return name
      if (r.width * r.height < area) {
        best = name
        area = r.width * r.height
      }
    }
    return best
  }

  // Where `name` would sit in each zone it may use, measured on the probe
  // view with the lock's own placement code.
  function measureAnchors(name) {
    var zones = Draft.zonesFor(name)
    var anchors = []
    for (var i = 0; i < zones.length; i++) {
      probe.look = Draft.probeLook(look, name, zones[i])
      var r = probe.drawnRect(name)
      anchors.push({ zone: zones[i], x: r.x, y: r.y, width: r.width, height: r.height })
    }
    return anchors
  }

  function snapInput(g) {
    var geo = geometry()
    return { name: g.name, width: geo.width, height: geo.height, margin: geo.margin, rightToLeft: geo.rightToLeft,
      start: g.start, delta: g.delta, axis: altHeld ? g.axis : "", snapping: snapping && !shiftHeld,
      radius: Draft.snapRadius(zoom), anchors: g.anchors, others: g.others }
  }

  // Start moving `name` (the pointer pressed on it, or a test).
  function beginMove(name) {
    if (!rects[name]) return false
    cancelGesture()
    selectRequested(name)
    forceActiveFocus(Qt.MouseFocusReason)
    var anchors = measureAnchors(name)
    var zone = look.elements[name].zone
    var current = null
    for (var i = 0; i < anchors.length; i++) if (anchors[i].zone === zone) current = anchors[i]
    if (!current) return false
    var others = []
    for (var other in rects) if (other !== name) others.push(rects[other])
    gesture = { mode: "move", name: name, start: view.drawnRect(name), anchors: anchors, current: current,
      others: others, axis: "", delta: { x: 0, y: 0 }, result: null }
    updateGesture()
    return true
  }

  // Start scaling the selection from a corner (`handle` { x, y }: -1 or 1).
  function beginResize(handle) {
    if (!selectedRect) return false
    cancelGesture()
    forceActiveFocus(Qt.MouseFocusReason)
    gesture = { mode: "resize", name: selected, start: view.drawnRect(selected), handle: handle,
      startScale: Draft.elementValue(look.elements[selected], "scale"), delta: { x: 0, y: 0 }, scale: undefined }
    return true
  }

  // The pointer moved by (dx, dy) canvas pixels since the gesture began.
  // `modifiers` (when known) are the pointer's.
  function moveGesture(dx, dy, modifiers) {
    if (!gesture) return
    if (modifiers !== undefined) {
      shiftHeld = (modifiers & Qt.ShiftModifier) !== 0
      altHeld = (modifiers & Qt.AltModifier) !== 0
    }
    var g = Object.assign({}, gesture)
    g.delta = { x: dx / zoom, y: dy / zoom }
    // The axis the drag started along, for Alt (two view pixels decide it).
    if (!g.axis && Math.max(Math.abs(g.delta.x), Math.abs(g.delta.y)) >= 2) g.axis = Draft.dragAxis(g.delta.x, g.delta.y)
    gesture = g
    updateGesture()
  }

  // Recompute the shown result from the last movement (also after Shift or
  // Alt changes with the pointer still).
  function updateGesture() {
    if (!gesture) return
    var g = Object.assign({}, gesture)
    if (g.mode === "move") {
      g.result = Draft.snap(snapInput(g))
      liveLook = Draft.draggedLook(look, g.name, g.result.rect, g.current, geometry())
    } else {
      g.scale = Draft.resizeScale(g.name, g.startScale, g.start, g.handle, g.delta, shiftHeld)
      liveLook = Draft.scaledLook(look, g.name, g.scale)
    }
    gesture = g
  }

  // The drop: one edit (zone, order and offset, or the scale on its step).
  function finishGesture() {
    var g = gesture
    if (!g) return
    gesture = null
    var next = draft
    if (g.mode === "move" && g.result) {
      var placed = Draft.drop(g.result.rect, snapInput(g))
      if (placed) next = Draft.place(draft, g.name, placed.zone, placed.offset)
    } else if (g.mode === "resize" && g.scale !== undefined) {
      next = Draft.setScale(draft, g.name, g.scale)
    }
    liveLook = null
    if (!Draft.same(next, draft)) edited(next)
  }

  function cancelGesture() {
    gesture = null
    liveLook = null
  }

  function setModifier(key, held) {
    if (key === Qt.Key_Shift) shiftHeld = held
    else if (key === Qt.Key_Alt) altHeld = held
    else return false
    updateGesture()
    return true
  }

  // Keys on the canvas; true when handled. With a module selected: arrows
  // move one grid step (Shift: one pixel), Ctrl+arrows to the neighbouring
  // zone, + and - scale, Delete hides (not the password field).
  function keyPressed(key, modifiers) {
    if (setModifier(key, true)) return false
    if (key === Qt.Key_Escape && gesture) {
      cancelGesture()
      return true
    }
    if (!selected || gesture) return false
    var directions = {}
    directions[Qt.Key_Left] = "left"
    directions[Qt.Key_Right] = "right"
    directions[Qt.Key_Up] = "up"
    directions[Qt.Key_Down] = "down"
    var direction = directions[key]
    if (direction) {
      if (modifiers & Qt.ControlModifier) {
        var zone = look.elements[selected].zone
        var next = Draft.neighbourZone(zone, direction, rightToLeft, selected)
        if (next !== zone) edited(Draft.setZone(draft, selected, next))
        return true
      }
      if (!selectedRect) return true
      var rect = view.drawnRect(selected), anchor = view.reservedRect(selected)
      var sign = direction === "left" || direction === "up" ? -1 : 1
      var across = direction === "left" || direction === "right"
      var step = Draft.gridStep(screenHeight)
      var delta = (modifiers & Qt.ShiftModifier) ? sign
        : across ? Draft.gridMove(rect.x + rect.width / 2, anchor.x + anchor.width / 2, sign, step)
        : Draft.gridMove(rect.y, anchor.y, sign, step)
      var moved = Draft.nudge(draft, selected, across ? delta : 0, across ? 0 : delta, rect, anchor, geometry())
      if (!Draft.same(moved, draft)) edited(moved)
      return true
    }
    if (key === Qt.Key_Plus || key === Qt.Key_Equal || key === Qt.Key_Minus) {
      var scaled = Draft.scaleBy(draft, selected, key === Qt.Key_Minus ? -1 : 1)
      if (!Draft.same(scaled, draft)) edited(scaled)
      return true
    }
    if (key === Qt.Key_Delete) {
      var hidden = Draft.setHidden(draft, selected, true)
      if (!Draft.same(hidden, draft)) edited(hidden)
      return true
    }
    return false
  }

  function keyReleased(key) {
    setModifier(key, false)
    return false
  }

  function zoneCell(zone) {
    var column = Layout.screenColumn(zone, rightToLeft)
    return { column: ["start", "center", "end"].indexOf(column), row: ["top", "middle", "bottom"].indexOf(Layout.zoneRow(zone)) }
  }

  Item {
    id: stageArea
    anchors.fill: parent

    Rectangle {
      id: stage
      objectName: "studioStage"
      anchors.centerIn: parent
      width: Math.round(canvas.screenWidth * canvas.zoom)
      height: Math.round(canvas.screenHeight * canvas.zoom)
      clip: true
      color: Commons.Color.background
      // Outside the lock: never mirrored (it mirrors itself).
      LayoutMirroring.enabled: false
      LayoutMirroring.childrenInherit: true

      SampleView {
        id: view
        objectName: "studioView"
        width: canvas.screenWidth
        height: canvas.screenHeight
        transformOrigin: Item.TopLeft
        scale: canvas.zoom
        look: canvas.liveLook || canvas.look
        previewState: canvas.previewState
        displayAwake: canvas.awake
        loadBackground: canvas.awake
        rightToLeft: FoamyI18n.rightToLeft
      }

      Item {
        id: overlay
        anchors.fill: parent

        // The zone grid, and the zone a drop would pick.
        Repeater {
          model: canvas.showZones ? 4 : 0
          Rectangle {
            required property int index
            readonly property bool vertical: index < 2
            x: vertical ? Math.round(overlay.width * (index % 2 + 1) / 3) : 0
            y: vertical ? 0 : Math.round(overlay.height * (index % 2 + 1) / 3)
            width: vertical ? 1 : overlay.width
            height: vertical ? overlay.height : 1
            color: Qt.rgba(1, 1, 1, 0.2)
          }
        }

        Rectangle {
          id: targetZone
          readonly property string zone: canvas.gesture && canvas.gesture.mode === "move" && canvas.gesture.result ? canvas.gesture.result.zone : ""
          readonly property var cell: zone ? canvas.zoneCell(zone) : null
          visible: zone !== "" && canvas.showZones
          x: cell ? Math.round(overlay.width * cell.column / 3) : 0
          y: cell ? Math.round(overlay.height * cell.row / 3) : 0
          width: Math.round(overlay.width / 3)
          height: Math.round(overlay.height / 3)
          color: Qt.alpha(FoamyPalette.accent, 0.14)
          border.width: 2
          border.color: FoamyPalette.accent

          Tag {
            x: FoamyStyle.gap
            y: FoamyStyle.gap
            text: targetZone.zone ? FoamyI18n.t("studio.zone." + targetZone.zone) : ""
          }
        }

        // Problem outlines.
        Repeater {
          model: canvas.problemNames
          Rectangle {
            required property var modelData
            readonly property var r: canvas.rects[modelData]
            visible: r !== undefined
            x: r ? r.x * canvas.zoom - 3 : 0
            y: r ? r.y * canvas.zoom - 3 : 0
            width: r ? r.width * canvas.zoom + 6 : 0
            height: r ? r.height * canvas.zoom + 6 : 0
            color: "transparent"
            radius: 3
            border.width: 2
            border.color: FoamyPalette.error
          }
        }

        // Snap guides.
        Rectangle {
          readonly property var snapX: canvas.gesture && canvas.gesture.result ? canvas.gesture.result.x : null
          visible: snapX !== null && snapX.kind !== "grid"
          x: snapX ? Math.round(snapX.at * canvas.zoom) : 0
          width: 1
          height: overlay.height
          color: FoamyPalette.accent
        }
        Rectangle {
          readonly property var snapY: canvas.gesture && canvas.gesture.result ? canvas.gesture.result.y : null
          visible: snapY !== null && snapY.kind !== "grid"
          y: snapY ? Math.round(snapY.at * canvas.zoom) : 0
          height: 1
          width: overlay.width
          color: FoamyPalette.accent
        }

        // The selection, its tag and corner handles.
        Rectangle {
          id: selection
          objectName: "studioSelection"
          readonly property var r: canvas.selectedRect
          visible: r !== null
          x: r ? r.x * canvas.zoom - 4 : 0
          y: r ? r.y * canvas.zoom - 4 : 0
          width: r ? r.width * canvas.zoom + 8 : 0
          height: r ? r.height * canvas.zoom + 8 : 0
          color: "transparent"
          radius: 2
          border.width: canvas.activeFocus ? 2 : 1.5
          border.color: FoamyPalette.accent

          Tag {
            x: 0
            y: selection.y >= height + 4 ? -height - 4 : selection.height + 4
            text: canvas.selectionText
          }

          Repeater {
            model: [{ x: -1, y: -1 }, { x: 1, y: -1 }, { x: -1, y: 1 }, { x: 1, y: 1 }]
            Rectangle {
              id: handle
              required property var modelData
              width: 9
              height: 9
              radius: 2
              x: (modelData.x < 0 ? 0 : selection.width) - width / 2
              y: (modelData.y < 0 ? 0 : selection.height) - height / 2
              color: FoamyPalette.onAccent
              border.width: 1.5
              border.color: FoamyPalette.accent

              // A larger grip than the drawn square.
              Item {
                anchors.centerIn: parent
                width: 20
                height: 20
                HoverHandler {
                  cursorShape: handle.modelData.x === handle.modelData.y ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                }
                DragHandler {
                  target: null
                  dragThreshold: 2
                  onActiveChanged: {
                    if (active) canvas.beginResize(handle.modelData)
                    else canvas.finishGesture()
                  }
                  onActiveTranslationChanged: if (active) canvas.moveGesture(activeTranslation.x, activeTranslation.y, centroid.modifiers)
                }
              }
            }
          }
        }

        TapHandler {
          onTapped: function(eventPoint) {
            canvas.forceActiveFocus(Qt.MouseFocusReason)
            canvas.selectRequested(canvas.hit(eventPoint.position.x / canvas.zoom, eventPoint.position.y / canvas.zoom))
          }
        }

        DragHandler {
          id: moveDrag
          target: null
          dragThreshold: 4
          onActiveChanged: {
            if (active) {
              var press = centroid.pressPosition
              var name = canvas.hit(press.x / canvas.zoom, press.y / canvas.zoom)
              if (name) canvas.beginMove(name)
            } else canvas.finishGesture()
          }
          onActiveTranslationChanged: if (active) canvas.moveGesture(activeTranslation.x, activeTranslation.y, centroid.modifiers)
        }
      }
    }

    // Focus is always visible.
    Rectangle {
      anchors.fill: stage
      anchors.margins: -3
      color: "transparent"
      radius: FoamyStyle.radiusSmall
      border.width: 2
      border.color: FoamyPalette.accent
      visible: canvas.activeFocus
    }
  }

  // Measures anchors (never shown): the same lock, sized and filled like
  // the canvas, given a look per zone.
  SampleView {
    id: probe
    visible: false
    width: canvas.screenWidth
    height: canvas.screenHeight
    previewState: canvas.previewState
    displayAwake: false
    loadBackground: false
    rightToLeft: FoamyI18n.rightToLeft
  }

  component Tag: Rectangle {
    property string text: ""
    visible: text !== ""
    width: tagLabel.implicitWidth + 2 * FoamyStyle.gapSmall + 4
    height: tagLabel.implicitHeight + FoamyStyle.gapTiny * 2
    radius: FoamyStyle.radiusSmall / 2
    color: FoamyPalette.accent
    Text {
      id: tagLabel
      anchors.centerIn: parent
      text: parent.text
      color: FoamyPalette.onAccent
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.caption
      font.weight: Font.DemiBold
    }
  }
}
