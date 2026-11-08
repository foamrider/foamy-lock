.pragma library
.import "Layout.js" as Layout
// Lock Studio's pure model: the draft look, its undo history, and the
// snapping maths the canvas runs on every pointer move. No I/O, no QML
// types: node tests load it (tests/studio-draft.test.cjs) with Layout.js
// as `Layout`.
//
// The draft is a look entry, the four keys the lock saves: { preset, layout,
// background, glass }, `layout` holding only what differs from the preset
// (see entry()). Every edit takes an entry and returns a new one, so undo is
// a list of entries, the same shape `foamy-lock-helper studio draft-save`
// keeps on disk.
//
// Geometry is in the lock view's pixels (its logical screen size); the
// canvas converts pointer moves by its zoom before calling in. Rectangles are
// { x, y, width, height }. Anchors are the drawn rectangles an element would
// have in each zone's current stack, measured by the canvas on a probe view:
// { zone, x, y, width, height }.

// Library order (the lock's ELEMENTS order is its tie-break, not a reading order).
var DISPLAY_ORDER = ["clock", "date", "calendar", "account", "password", "media", "status"]
// The grid: square cells of 1/48 of the screen height.
var GRID_DIVISIONS = 48
// Snapping reaches this far in canvas pixels, whatever the zoom.
var SNAP_RADIUS = 8
// Undo steps kept (the helper keeps at most 100 on disk).
var HISTORY_LIMIT = 100
// Offsets are stored to this many decimals (1e-6 of 4000 px is 0.004 px).
var OFFSET_DECIMALS = 6
var ORDER_LIMIT = 99
// The zone grid's rows and logical columns (Layout.js names zones by them).
var ROWS = ["top", "middle", "bottom"]
var COLUMNS = ["start", "center", "end"]

// An element's ranges (the password's are tighter; Layout.js keeps both).
function limitsFor(name) {
  return name === "password" ? Layout.PASSWORD_LIMITS : Layout.LIMITS
}

function copy(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value))
}

// JSON with every object's keys sorted: QML `var` properties hand objects
// back as maps in key order, so comparisons ignore the order.
function stable(value) {
  if (Array.isArray(value)) return "[" + value.map(stable).join(",") + "]"
  if (value !== null && typeof value === "object") {
    return "{" + Object.keys(value).sort().filter(function(key) { return value[key] !== undefined })
      .map(function(key) { return JSON.stringify(key) + ":" + stable(value[key]) }).join(",") + "}"
  }
  return JSON.stringify(value)
}

function same(a, b) {
  return stable(a) === stable(b)
}

// An entry in the lock's key order (preset, layout, background, glass),
// for saving.
function ordered(draft) {
  var out = { preset: draft.preset }
  var keys = ["layout", "background", "glass"]
  for (var i = 0; i < keys.length; i++) if (draft[keys[i]] !== undefined) out[keys[i]] = copy(draft[keys[i]])
  return out
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// --- the draft entry -------------------------------------------------------

// A key's value with its default filled in, for comparing an element with
// its preset (canonical elements omit defaults).
function elementValue(item, key) {
  var value = item[key]
  if (value !== undefined) return value
  switch (key) {
  case "scale": return 1
  case "opacity": return 1
  case "screens": return "all"
  case "hidden": return false
  case "offset": return { x: 0, y: 0 }
  }
  return undefined
}

// The sparse entry for an effective look (Layout.merge's shape): only what
// differs from its preset, so a look made of defaults is { preset }.
function entry(look) {
  if (!look || !look.elements) return { preset: look && Layout.PRESETS[look.preset] ? look.preset : Layout.DEFAULT_PRESET }
  var name = look && Layout.PRESETS[look.preset] ? look.preset : Layout.DEFAULT_PRESET
  var base = Layout.preset(name)
  var current = Layout.canonical(look)
  var result = { preset: name }
  var layout = {}
  for (var i = 0; i < Layout.ELEMENTS.length; i++) {
    var element = Layout.ELEMENTS[i]
    var item = current.elements[element]
    var preset = base.elements[element]
    if (!item) continue
    var changes = {}
    for (var k = 0; k < Layout.ELEMENT_KEYS.length; k++) {
      var key = Layout.ELEMENT_KEYS[k]
      var value = elementValue(item, key)
      if (value === undefined) continue
      if (!same(value, elementValue(preset, key))) changes[key] = copy(value)
    }
    if (Object.keys(changes).length > 0) layout[element] = changes
  }
  if (Object.keys(layout).length > 0) result.layout = layout
  var background = shallowDiff(current.background, base.background)
  if (background) result.background = background
  var glass = shallowDiff(current.glass, base.glass)
  if (glass) result.glass = glass
  return result
}

function shallowDiff(value, base) {
  var out = {}
  var any = false
  for (var key in value || {}) {
    if (!same(value[key], base[key])) {
      out[key] = copy(value[key])
      any = true
    }
  }
  return any ? out : null
}

// The lock's reading of an entry: { valid, look, error } (Layout.parseLook).
function parse(draft) {
  return Layout.parseLook(draft)
}

// The effective look of an entry; the default look when it isn't valid.
function lookOf(draft) {
  var parsed = Layout.parseLook(draft)
  return parsed.valid ? parsed.look : Layout.defaults()
}

// How many keys differ from the preset (elements' keys, background, glass).
function changeCount(draft) {
  var count = 0
  for (var name in (draft && draft.layout) || {}) count += Object.keys(draft.layout[name]).length
  count += Object.keys((draft && draft.background) || {}).length
  count += Object.keys((draft && draft.glass) || {}).length
  return count
}

// The order that puts `name` last in `zone` (after every other element there,
// hidden ones included, so showing one later never jumps the queue).
function lastOrder(elements, zone, name) {
  var order = -Infinity
  for (var i = 0; i < Layout.ELEMENTS.length; i++) {
    var other = Layout.ELEMENTS[i]
    if (other === name || !elements[other] || elements[other].zone !== zone) continue
    order = Math.max(order, elements[other].order)
  }
  return order === -Infinity ? 0 : Math.min(ORDER_LIMIT, order + 1)
}

// Apply `edit(item, look)` to one element of the entry's look and return the
// new entry. The result is checked: an edit the lock would refuse returns
// the entry unchanged.
function editElement(draft, name, edit) {
  var look = lookOf(draft)
  if (!look.elements[name]) return draft
  edit(look.elements[name], look)
  var next = entry(look)
  return Layout.parseLook(next).valid ? next : draft
}

function roundTo(value, decimals) {
  var factor = Math.pow(10, decimals)
  var rounded = Math.round(value * factor) / factor
  return rounded === 0 ? 0 : rounded
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// An offset within the element's limits, rounded for storage.
function cleanOffset(name, offset) {
  var limits = limitsFor(name).offset
  return {
    x: roundTo(clamp(Number(offset.x) || 0, limits.min, limits.max), OFFSET_DECIMALS),
    y: roundTo(clamp(Number(offset.y) || 0, limits.min, limits.max), OFFSET_DECIMALS)
  }
}

// A scale within the element's limits; on its 0.05 step unless `free`.
function cleanScale(name, scale, free) {
  var limits = limitsFor(name).scale
  var value = clamp(Number(scale) || 1, limits.min, limits.max)
  return free ? value : clamp(Math.round(value / limits.step) / Math.round(1 / limits.step), limits.min, limits.max)
}

// Move to `zone` (last in its stack when the zone changes) without an offset.
function setZone(draft, name, zone) {
  return place(draft, name, zone, { x: 0, y: 0 })
}

// The drop: `zone`, last in its stack when it changes, and `offset`; with
// `show`, also shown (a module dragged in from the library), in one step.
function place(draft, name, zone, offset, show) {
  if (name === "password" && Layout.PASSWORD_ZONES.indexOf(zone) === -1) return draft
  if (Layout.ZONES.indexOf(zone) === -1) return draft
  return editElement(draft, name, function(item, look) {
    if (item.zone !== zone) {
      item.order = lastOrder(look.elements, zone, name)
      item.zone = zone
    }
    item.offset = cleanOffset(name, offset || { x: 0, y: 0 })
    if (show) item.hidden = false
  })
}

function setOffset(draft, name, offset) {
  return editElement(draft, name, function(item) { item.offset = cleanOffset(name, offset) })
}

function setScale(draft, name, scale) {
  return editElement(draft, name, function(item) { item.scale = cleanScale(name, scale, false) })
}

// Change the scale by `steps` of 0.05.
function scaleBy(draft, name, steps) {
  var current = elementValue(lookOf(draft).elements[name] || {}, "scale")
  return setScale(draft, name, current + steps * limitsFor(name).scale.step)
}

function setOrder(draft, name, order) {
  return editElement(draft, name, function(item) { item.order = clamp(Math.round(order), -ORDER_LIMIT, ORDER_LIMIT) })
}

// Hide or show; the password field can't be hidden.
function setHidden(draft, name, hidden) {
  if (name === "password" && hidden) return draft
  return editElement(draft, name, function(item) { item.hidden = !!hidden })
}

// Start over from a preset: its look without any of the draft's changes.
function setPreset(draft, name) {
  return Layout.SELECTABLE_PRESETS.indexOf(name) === -1 ? draft : { preset: name }
}

// The draft's changes carried over to another preset: its layout,
// background and glass overrides on `name`, kept sparse against it. null
// when the lock would refuse the result (or `name` isn't selectable).
function presetKeeping(draft, name) {
  if (Layout.SELECTABLE_PRESETS.indexOf(name) === -1) return null
  var next = { preset: name }
  var keys = ["layout", "background", "glass"]
  for (var i = 0; i < keys.length; i++) if (draft && draft[keys[i]] !== undefined) next[keys[i]] = copy(draft[keys[i]])
  var parsed = Layout.parseLook(next)
  return parsed.valid ? entry(parsed.look) : null
}

// --- the inspector's edits -------------------------------------------------

function setStyle(draft, name, style) {
  if (!Layout.STYLES[name] || Layout.STYLES[name].indexOf(style) === -1) return draft
  return editElement(draft, name, function(item) { item.style = style })
}

// An opacity within the element's limits, in hundredths.
function cleanOpacity(name, value) {
  var limits = limitsFor(name).opacity
  return roundTo(clamp(Number(value), limits.min, limits.max), 2)
}

function setOpacity(draft, name, value) {
  if (value === null || value === "" || !isFinite(Number(value))) return draft
  return editElement(draft, name, function(item) { item.opacity = cleanOpacity(name, value) })
}

// The element's own glass (hundredths, within its limits), or with null the
// look's glass again. Only elements with a glass style take one.
function setGlass(draft, name, value) {
  if (!Layout.GLASS_STYLES[name]) return draft
  var clear = value === null || value === undefined
  if (!clear && (value === "" || !isFinite(Number(value)))) return draft
  var limits = limitsFor(name).glass
  return editElement(draft, name, function(item) {
    if (clear) delete item.glass
    else item.glass = roundTo(clamp(Number(value), limits.min, limits.max), 2)
  })
}

// The glass the element shows: its own, else the look's.
function glassOf(look, name) {
  var item = look.elements[name]
  return item && item.glass !== undefined ? item.glass : look.glass.opacity
}

// Whether the element's current style draws a glass surface.
function hasGlass(look, name) {
  var item = look.elements[name]
  return !!item && !!Layout.GLASS_STYLES[name] && Layout.GLASS_STYLES[name].indexOf(item.style) !== -1
}

function setScreens(draft, name, screens) {
  if (Layout.SCREENS_ELEMENTS.indexOf(name) === -1 || Layout.SCREENS.indexOf(screens) === -1) return draft
  return editElement(draft, name, function(item) { item.screens = screens })
}

// Back to the zone position (no offset).
function resetOffset(draft, name) {
  return setOffset(draft, name, { x: 0, y: 0 })
}

// An offset in whole pixels of a `width` × `height` screen: the inspector
// shows grid steps and pixels, the look keeps fractions.
function offsetPixels(offset, width, height) {
  return { x: Math.round((offset ? offset.x : 0) * width), y: Math.round((offset ? offset.y : 0) * height) }
}

// Pixels in grid steps (one decimal), and grid steps in whole pixels.
function pixelsToSteps(pixels, height) {
  return roundTo(pixels / gridStep(height), 1)
}

function stepsToPixels(steps, height) {
  return Math.round(steps * gridStep(height))
}

// --- the scene: background and glass ----------------------------------------

// Apply `edit(look)` to the entry's look; an edit the lock would refuse
// returns the entry unchanged.
function editLook(draft, edit) {
  var look = lookOf(draft)
  edit(look)
  var next = entry(look)
  return Layout.parseLook(next).valid ? next : draft
}

// The ranges the scene's sliders keep to (the lock's, in its own units).
var SCENE_LIMITS = { blur: { min: 0, max: 1 }, dim: { min: 0, max: 0.9 }, opacity: { min: 0, max: 1 } }

function cleanScene(key, value) {
  var limits = SCENE_LIMITS[key]
  return limits ? roundTo(clamp(Number(value), limits.min, limits.max), 2) : value
}

function isNumber(value) {
  return value !== null && value !== "" && typeof value !== "boolean" && isFinite(Number(value))
}

// One background key: source, blur, dim or decor. The picture source needs
// a path, so it is refused here without one (see setPicture).
function setBackground(draft, key, value) {
  if (Layout.BACKGROUND_KEYS.indexOf(key) === -1 || key === "path") return draft
  if ((key === "blur" || key === "dim") && !isNumber(value)) return draft
  return editLook(draft, function(look) { look.background[key] = cleanScene(key, value) })
}

// The picture background: source "picture" with `path`, in one step.
function setPicture(draft, path) {
  return editLook(draft, function(look) {
    look.background.source = "picture"
    look.background.path = String(path || "")
  })
}

// One glass key: opacity or tint.
function setGlassLook(draft, key, value) {
  if (Layout.GLASS_KEYS.indexOf(key) === -1) return draft
  if (key === "opacity" && !isNumber(value)) return draft
  return editLook(draft, function(look) { look.glass[key] = cleanScene(key, value) })
}

// --- undo history ------------------------------------------------------------

// { past: [entry…] oldest first, present: entry, future: [entry…] next first }.
function history(draft) {
  return { past: [], present: copy(draft), future: [] }
}

// Record a new present; an unchanged entry records nothing. The oldest steps
// beyond `limit` (HISTORY_LIMIT) are dropped.
function push(h, draft, limit) {
  if (same(draft, h.present)) return h
  var past = h.past.concat([h.present])
  var keep = limit === undefined ? HISTORY_LIMIT : limit
  if (past.length > keep) past = past.slice(past.length - keep)
  return { past: past, present: copy(draft), future: [] }
}

function canUndo(h) { return h.past.length > 0 }
function canRedo(h) { return h.future.length > 0 }

function undo(h) {
  if (!canUndo(h)) return h
  return { past: h.past.slice(0, -1), present: h.past[h.past.length - 1], future: [h.present].concat(h.future) }
}

function redo(h) {
  if (!canRedo(h)) return h
  return { past: h.past.concat([h.present]), present: h.future[0], future: h.future.slice(1) }
}

// --- geometry -------------------------------------------------------------------

function gridStep(height) {
  return height / GRID_DIVISIONS
}

// The snap radius in view pixels for a canvas shown at `zoom`.
function snapRadius(zoom) {
  return SNAP_RADIUS / (zoom > 0 ? zoom : 1)
}

// The axis a drag started along, for the Alt lock: "x", "y", or "" before
// it has moved.
function dragAxis(dx, dy) {
  if (dx === 0 && dy === 0) return ""
  return Math.abs(dx) >= Math.abs(dy) ? "x" : "y"
}

function zonesFor(name) {
  return name === "password" ? Layout.PASSWORD_ZONES.slice() : Layout.ZONES.slice()
}

// Where an element's drawn rectangle may go: on screen; the password field
// also `margin` from the edges and with its top at least a third down
// (the lock's password-offscreen and password-high rules).
function bounds(name, width, height, margin) {
  if (name !== "password") return { left: 0, top: 0, right: width, bottom: height }
  var m = margin || 0
  return { left: m, top: Math.ceil(height / 3), right: width - m, bottom: height - m }
}

function clampRect(rect, box) {
  var x = rect.width > box.right - box.left ? box.left : clamp(rect.x, box.left, box.right - rect.width)
  var y = rect.height > box.bottom - box.top ? box.top : clamp(rect.y, box.top, box.bottom - rect.height)
  return { x: x, y: y, width: rect.width, height: rect.height }
}

function centreX(r) { return r.x + r.width / 2 }
function centreY(r) { return r.y + r.height / 2 }

// The anchor nearest to the rectangle (centre to centre) among those whose
// zone `name` may use; null without any.
function nearestAnchor(rect, anchors, name) {
  var allowed = zonesFor(name)
  var best = null, bestDistance = Infinity
  for (var i = 0; i < (anchors || []).length; i++) {
    var a = anchors[i]
    if (allowed.indexOf(a.zone) === -1) continue
    var dx = centreX(a) - centreX(rect), dy = centreY(a) - centreY(rect)
    var distance = dx * dx + dy * dy
    if (distance < bestDistance) {
      best = a
      bestDistance = distance
    }
  }
  return best
}

// Edges and centre of a rectangle along one axis.
function features(r, axis) {
  return axis === "x" ? [r.x, r.x + r.width / 2, r.x + r.width] : [r.y, r.y + r.height / 2, r.y + r.height]
}

// The best snap along one axis: { kind, at, delta } or null. Anchors and
// guides within `radius` beat the grid; the nearest wins, anchors before
// guides on a tie.
function snapAxis(rect, axis, input, anchor) {
  var own = features(rect, axis)
  var best = null
  function consider(kind, feature, line, extra) {
    var delta = line - own[feature]
    var distance = Math.abs(delta)
    if (distance > input.radius) return
    var rank = kind === "anchor" ? 0 : 1
    if (!best || distance < best.distance - 1e-9 || (Math.abs(distance - best.distance) <= 1e-9 && rank < best.rank)) {
      best = { kind: kind, at: line, delta: delta, distance: distance, rank: rank }
      if (extra) best.zone = extra
    }
  }
  var anchors = input.anchors || []
  var allowed = zonesFor(input.name)
  for (var i = 0; i < anchors.length; i++) {
    if (allowed.indexOf(anchors[i].zone) === -1) continue
    var target = features(anchors[i], axis)
    for (var f = 0; f < 3; f++) consider("anchor", f, target[f], anchors[i].zone)
  }
  // The screen's centre line, and the other modules' edges and centres.
  consider("guide", 1, (axis === "x" ? input.width : input.height) / 2)
  var others = input.others || []
  for (var j = 0; j < others.length; j++) {
    var lines = features(others[j], axis)
    for (var l = 0; l < 3; l++)
      for (var g = 0; g < 3; g++) consider("guide", g, lines[l])
  }
  if (best) return { kind: best.kind, at: best.at, delta: best.delta, zone: best.zone }
  // The grid: offsets from the nearest anchor in whole cells (centres
  // across, tops down, as the drop measures them).
  if (!anchor) return null
  var step = gridStep(input.height)
  var from = axis === "x" ? centreX(anchor) : anchor.y
  var mine = axis === "x" ? centreX(rect) : rect.y
  var snapped = from + Math.round((mine - from) / step) * step
  if (Math.abs(snapped - mine) > input.radius) return null
  return { kind: "grid", at: snapped, delta: snapped - mine }
}

// One pointer move of a drag. `input`:
//   name, width, height, margin, rightToLeft
//   start     the element's drawn rectangle when the drag began
//   delta     { x, y } pointer movement, view pixels
//   axis      "", "x" or "y": Alt holds the drag to the axis it started along
//   snapping  false while Shift is held (or snapping is switched off)
//   radius    snap radius in view pixels (snapRadius(zoom))
//   anchors   where the element would sit in each zone
//   others    the other shown modules' rectangles
// Returns { rect, x, y, zone }: the rectangle to show, the snap on each axis
// ({ kind: "anchor" | "guide" | "grid", at } or null: `at` is the line to
// draw) and the zone a drop here would pick.
function snap(input) {
  var dx = input.delta.x, dy = input.delta.y
  if (input.axis === "x") dy = 0
  else if (input.axis === "y") dx = 0
  var rect = { x: input.start.x + dx, y: input.start.y + dy, width: input.start.width, height: input.start.height }
  var box = bounds(input.name, input.width, input.height, input.margin)
  rect = clampRect(rect, box)
  var snapX = null, snapY = null
  if (input.snapping) {
    var anchor = nearestAnchor(rect, input.anchors, input.name)
    if (input.axis !== "y") snapX = snapAxis(rect, "x", input, anchor)
    if (input.axis !== "x") snapY = snapAxis(rect, "y", input, anchor)
    if (snapX) rect.x += snapX.delta
    if (snapY) rect.y += snapY.delta
    var clamped = clampRect(rect, box)
    // A snap the limits push back off isn't shown as a snap.
    if (snapX && clamped.x !== rect.x) snapX = null
    if (snapY && clamped.y !== rect.y) snapY = null
    rect = clamped
  }
  var nearest = nearestAnchor(rect, input.anchors, input.name)
  return {
    rect: rect,
    x: snapX ? { kind: snapX.kind, at: snapX.at } : null,
    y: snapY ? { kind: snapY.kind, at: snapY.at } : null,
    zone: nearest ? nearest.zone : ""
  }
}

// The offset that puts an element's drawn `rect` where it is, measured from
// `anchor` (its rectangle in the zone without an offset): centres across,
// tops down, in whole pixels, x mirrored right-to-left. The password field's
// top is kept at least a third down.
function offsetFrom(rect, anchor, input) {
  var dx = Math.round(centreX(rect) - centreX(anchor))
  var dy = Math.round(rect.y - anchor.y)
  if (input.name === "password") dy = Math.max(dy, Math.ceil(input.height / 3 - anchor.y))
  return cleanOffset(input.name, {
    x: dx * (input.rightToLeft ? -1 : 1) / input.width,
    y: dy / input.height
  })
}

// The drop of `rect` (from snap()): the nearest allowed anchor decides the
// zone, the rest is the offset. { zone, offset } or null without anchors.
function drop(rect, input) {
  var anchor = nearestAnchor(rect, input.anchors, input.name)
  if (!anchor) return null
  return { zone: anchor.zone, offset: offsetFrom(rect, anchor, input) }
}

// The neighbouring zone on screen in `direction` ("left", "right", "up",
// "down"), or `zone` at the edge (or into a row the element can't use).
function neighbourZone(zone, direction, rightToLeft, name) {
  var row = ROWS.indexOf(Layout.zoneRow(zone))
  var logical = COLUMNS.indexOf(Layout.zoneColumn(zone))
  if (row === -1 || logical === -1) return zone
  // Screen columns left to right; start and end swap right-to-left.
  var column = rightToLeft ? 2 - logical : logical
  if (direction === "left") column--
  else if (direction === "right") column++
  else if (direction === "up") row--
  else if (direction === "down") row++
  if (row < 0 || row > 2 || column < 0 || column > 2) return zone
  var next = ROWS[row] + "-" + COLUMNS[rightToLeft ? 2 - column : column]
  return zonesFor(name).indexOf(next) === -1 ? zone : next
}

// Move by whole pixels on screen (an arrow key), kept within bounds():
// `rect` is the drawn rectangle now, `anchor` the one without the offset.
function nudge(draft, name, dx, dy, rect, anchor, input) {
  var box = bounds(name, input.width, input.height, input.margin)
  var moved = clampRect({ x: rect.x + dx, y: rect.y + dy, width: rect.width, height: rect.height }, box)
  return setOffset(draft, name, offsetFrom(moved, anchor, { name: name, width: input.width, height: input.height,
    rightToLeft: input.rightToLeft }))
}

// The move to the next grid line in `direction` (-1 or 1) from `position`,
// on the grid that starts at `origin` (the anchor; centres across, tops
// down), so repeated arrow presses never drift off the grid.
function gridMove(position, origin, direction, step) {
  var cells = (position - origin) / step
  var target = direction > 0 ? Math.floor(cells + 1e-6) + 1 : Math.ceil(cells - 1e-6) - 1
  return origin + target * step - position
}

// The scale while dragging a corner handle: `handle` { x, y } is -1 or 1 for
// the corner's side on screen, `delta` the pointer movement, `rect` the drawn
// rectangle when the resize began. The larger relative growth wins; on the
// 0.05 step unless `free` (Shift), always within the limits.
function resizeScale(name, startScale, rect, handle, delta, free) {
  var grow = Math.max((rect.width + handle.x * delta.x) / Math.max(1, rect.width),
    (rect.height + handle.y * delta.y) / Math.max(1, rect.height))
  return cleanScale(name, startScale * Math.max(0.01, grow), free)
}

// A look for the probe view that measures an anchor: `name` in `zone`
// without an offset, shown, last in the stack unless it's already there.
function probeLook(look, name, zone) {
  var result = copy(look)
  var item = result.elements[name]
  if (item.zone !== zone) {
    item.order = lastOrder(result.elements, zone, name)
    item.zone = zone
  }
  delete item.offset
  item.hidden = false
  return result
}

// The look while a drag is shown: `name` kept in its zone, moved by `offset`
// (no limits: mid-drag it may be far from its zone; the drop picks the zone).
function draggedLook(look, name, rect, anchor, input) {
  var result = copy(look)
  var dx = Math.round(centreX(rect) - centreX(anchor))
  var dy = Math.round(rect.y - anchor.y)
  result.elements[name].offset = { x: dx * (input.rightToLeft ? -1 : 1) / input.width, y: dy / input.height }
  return result
}

// The look with `name` at `scale` unrounded, for a resize in progress.
function scaledLook(look, name, scale) {
  var result = copy(look)
  result.elements[name].scale = scale
  return result
}

// The modules a geometry `code` (Layout.lookGeometryError) is about, for
// outlining them: the field and what covers it, the module off screen, or
// the overlapping pair. Follows lookGeometryError's rules and order.
function problemElements(code, elements, rects, width, height) {
  if (!code) return []
  var names = []
  for (var i = 0; i < Layout.ELEMENTS.length; i++) if (rects[Layout.ELEMENTS[i]]) names.push(Layout.ELEMENTS[i])
  if (code === "password-overlap") {
    for (var j = 0; j < names.length; j++)
      if (names[j] !== "password" && Layout.intersects(rects.password, rects[names[j]], 1)) return ["password", names[j]]
    return ["password"]
  }
  if (code.indexOf("password-") === 0) return ["password"]
  if (code === "element-offscreen") {
    for (var k = 0; k < names.length; k++) {
      var r = rects[names[k]]
      if (r.x < -1 || r.y < -1 || r.x + r.width > width + 1 || r.y + r.height > height + 1) return [names[k]]
    }
    return []
  }
  if (code === "element-overlap") {
    for (var a = 0; a < names.length; a++) {
      for (var b = a + 1; b < names.length; b++) {
        var first = elements[names[a]], second = elements[names[b]]
        if (first.zone === second.zone && !Layout.isOffset(first) && !Layout.isOffset(second)) continue
        if (Layout.intersects(rects[names[a]], rects[names[b]], 1)) return [names[a], names[b]]
      }
    }
  }
  return []
}

// The module before or after `name` in the library order (wrapping).
function neighbourModule(name, step) {
  var index = DISPLAY_ORDER.indexOf(name)
  if (index === -1) return DISPLAY_ORDER[0]
  var count = DISPLAY_ORDER.length
  return DISPLAY_ORDER[((index + step) % count + count) % count]
}

// --- screens -------------------------------------------------------------------

// The sizes the canvas can show: the connected screens, then the reference
// sizes. `screens` are Quickshell's ({ name, width, height }, logical
// pixels: what the lock lays out at); `natives` maps a monitor name to what
// Hyprland reports for it ({ width, height, scale, transform }: the mode in
// device pixels, before the transform). Qt only knows the integer wl_output
// scale (2 at 1.25), so the native size comes from Hyprland, and a screen
// Hyprland doesn't report keeps its logical size with scale 1. A rotated
// screen (odd transform) swaps the mode's width and height. Entries:
// { key, name, index, width, height, nativeWidth, nativeHeight, scale,
// reference }; `name` is "" for a screen without one (the window labels it
// by `index`).
var REFERENCE_SIZES = [[1280, 720], [1920, 1080]]

function monitorEntries(screens, natives) {
  var list = []
  for (var i = 0; i < (screens ? screens.length : 0); i++) {
    var screen = screens[i]
    if (!screen || !(screen.width > 0 && screen.height > 0)) continue
    var name = screen.name ? String(screen.name) : ""
    var native = name && natives && Object.prototype.hasOwnProperty.call(natives, name) ? natives[name] : null
    var width = screen.width, height = screen.height, scale = 1
    if (native && native.width > 0 && native.height > 0) {
      var turned = Math.abs(Math.round(Number(native.transform) || 0)) % 2 === 1
      width = turned ? native.height : native.width
      height = turned ? native.width : native.height
      scale = Number(native.scale) > 0 ? Number(native.scale) : 1
    }
    list.push({ key: "screen:" + (name || i), name: name, index: i, width: screen.width, height: screen.height,
      nativeWidth: Math.round(width), nativeHeight: Math.round(height), scale: scale, reference: false })
  }
  for (var j = 0; j < REFERENCE_SIZES.length; j++) {
    var w = REFERENCE_SIZES[j][0], h = REFERENCE_SIZES[j][1]
    list.push({ key: "reference:" + w + "x" + h, name: "", index: -1, width: w, height: h,
      nativeWidth: w, nativeHeight: h, scale: 1, reference: true })
  }
  return list
}

// A scale as a whole percentage (1.25 → 125); 0 when the screen isn't scaled.
function scalePercent(scale) {
  var percent = Math.round(Number(scale) * 100)
  return percent > 0 && percent !== 100 ? percent : 0
}

// --- saving: the draft on disk and the lock ----------------------------------
//
// The helper's replies (`foamy-lock-helper studio …`, see native/src/studio)
// become small reports that the window puts into words; nothing here passes
// the helper's own English text on.

// The keys of the lock's entry that make its look.
var LOOK_KEYS = ["preset", "layout", "background", "glass"]

// The saved look as a sparse entry, from the foamy.lock entry in shell.json
// (Model.parseConfig's `entry`): the default preset when there is no entry
// or it has no look keys; null when the lock refuses its look (the lock then
// keeps the look it had, and so does the app).
function savedEntry(configEntry) {
  var source = {}
  for (var i = 0; i < LOOK_KEYS.length; i++)
    if (isPlainObject(configEntry) && configEntry[LOOK_KEYS[i]] !== undefined) source[LOOK_KEYS[i]] = configEntry[LOOK_KEYS[i]]
  var parsed = Layout.parseLook(source)
  return parsed.valid ? entry(parsed.look) : null
}

// Two entries give the lock the same look (sparse or not, any key order).
function sameLook(a, b) {
  return same(entry(lookOf(a)), entry(lookOf(b)))
}

// What `studio draft-save` keeps: the look and the undo steps before it
// (oldest first), in the lock's key order. Redo steps aren't kept.
function diskDraft(h) {
  return { look: ordered(h.present), history: h.past.map(ordered) }
}

// A history from a loaded draft ({ look, history }), every step read as the
// lock reads it; steps the lock refuses are dropped. Null when it refuses
// the look itself.
function restore(saved) {
  if (!saved || !isPlainObject(saved.look)) return null
  var present = parse(saved.look)
  if (!present.valid) return null
  var past = []
  var steps = Array.isArray(saved.history) ? saved.history : []
  for (var i = 0; i < steps.length; i++) {
    var step = isPlainObject(steps[i]) ? parse(steps[i]) : null
    if (step && step.valid) past.push(entry(step.look))
  }
  if (past.length > HISTORY_LIMIT) past = past.slice(past.length - HISTORY_LIMIT)
  return { past: past, present: entry(present.look), future: [] }
}

// The last line of a helper's stdout as a JSON object, or null.
function replyOf(text) {
  var lines = String(text || "").trim().split("\n")
  try {
    var data = JSON.parse(lines[lines.length - 1])
    return isPlainObject(data) ? data : null
  } catch (error) {
    return null
  }
}

// A failure's code: the helper's own (`IO`, `NO_HOME`, …), else "FAILED".
function codeOf(data) {
  return data && typeof data.code === "string" && /^[A-Z_]{1,40}$/.test(data.code) ? data.code : "FAILED"
}

// A helper that couldn't start (FoamyNative.unavailable).
function unavailable(exitCode) {
  return exitCode === 126 || exitCode === 127
}

// `studio draft-load`: { status } is "loaded" (with `history` and
// `savedAt`), "none", "corrupt" (the helper moved the file aside) or
// "failed" (with `code`, "helper-unavailable" when it couldn't start). A
// loaded draft the lock wouldn't read counts as corrupt.
function loadReport(exitCode, text) {
  if (unavailable(exitCode)) return { status: "failed", code: "helper-unavailable" }
  var data = replyOf(text)
  if (exitCode === 0 && data && data.ok === true) {
    if (data.status === "none") return { status: "none" }
    if (data.status === "corrupt") return { status: "corrupt" }
    if (data.status === "loaded") {
      var restored = restore(data.draft)
      var savedAt = data.draft && typeof data.draft.savedAt === "string" ? data.draft.savedAt : ""
      return restored ? { status: "loaded", history: restored, savedAt: savedAt } : { status: "corrupt" }
    }
  }
  return { status: "failed", code: codeOf(data) }
}

// `studio draft-save` and `draft-clear`: "" when done, else a code.
function draftError(exitCode, text) {
  if (unavailable(exitCode)) return "helper-unavailable"
  var data = replyOf(text)
  return exitCode === 0 && data && data.ok === true ? "" : codeOf(data)
}

// The answers `studio apply` tells apart (native/src/studio/apply.rs).
var APPLY_RESULTS = ["ok", "unchanged", "invalid-json", "invalid", "locked", "unsupported", "no-entry", "unexpected",
  "not-responding", "not-ready", "not-running", "target-not-found", "function-not-found", "no-omarchy-shell", "failed"]

// `studio apply`: { result, saved, confirmed, reason, code }. `result` is
// one of APPLY_RESULTS, "helper-unavailable", or "error" (the helper didn't
// carry the request out; `code` says why). `saved`: the lock has the look.
// `confirmed`: the outcome is certain (false: it may or may not be saved).
// `reason` is the lock's own text for "invalid".
function applyReport(exitCode, text) {
  if (unavailable(exitCode)) return { result: "helper-unavailable", saved: false, confirmed: true, reason: "", code: "" }
  var data = replyOf(text)
  if (exitCode === 0 && data && APPLY_RESULTS.indexOf(data.result) !== -1) {
    var saved = data.ok === true && (data.result === "ok" || data.result === "unchanged")
    return { result: data.result, saved: saved, confirmed: data.confirmed === true,
      reason: data.result === "invalid" && typeof data.reason === "string" ? data.reason.slice(0, 300) : "", code: "" }
  }
  // Exit 1 comes before anything is called; anything else may not.
  return { result: "error", saved: false, confirmed: exitCode === 1, reason: "", code: codeOf(data) }
}

// The lock's `previewLook` through omarchy-shell, from its exit code,
// stdout and stderr (124 and 137 are `timeout`'s, 127 a missing
// omarchy-shell): { result, reason }, `result` as for applyReport ("ok": the
// preview shows).
function previewReport(exitCode, stdout, stderr) {
  var out = String(stdout || "").trim().split("\n")[0].trim()
  var err = String(stderr || "").trim().split("\n")[0].trim()
  if (exitCode === 124 || exitCode === 137) return { result: "not-responding", reason: "" }
  var failures = {
    "omarchy-shell is not responding": "not-responding",
    "omarchy-shell is not ready": "not-ready",
    "omarchy-shell is not running": "not-running",
    "Target not found.": "target-not-found",
    "Function not found.": "function-not-found"
  }
  var text = exitCode === 0 ? out : err
  if (failures.hasOwnProperty(text)) return { result: failures[text], reason: "" }
  if (exitCode === 127) return { result: "no-omarchy-shell", reason: "" }
  if (exitCode !== 0) return { result: "failed", reason: "" }
  if (out === "ok" || out === "invalid-json" || out === "locked") return { result: out, reason: "" }
  if (out.indexOf("invalid:") === 0) return { result: "invalid", reason: out.slice(8).trim().slice(0, 300) }
  return { result: "unexpected", reason: "" }
}

if (typeof module !== "undefined") module.exports = {
  LOOK_KEYS: LOOK_KEYS, APPLY_RESULTS: APPLY_RESULTS, savedEntry: savedEntry, sameLook: sameLook, diskDraft: diskDraft,
  restore: restore, replyOf: replyOf, loadReport: loadReport, draftError: draftError, applyReport: applyReport,
  previewReport: previewReport,
  DISPLAY_ORDER: DISPLAY_ORDER, GRID_DIVISIONS: GRID_DIVISIONS, SNAP_RADIUS: SNAP_RADIUS, HISTORY_LIMIT: HISTORY_LIMIT,
  same: same, stable: stable, ordered: ordered, entry: entry, parse: parse, elementValue: elementValue, lookOf: lookOf, changeCount: changeCount, lastOrder: lastOrder,
  place: place, setZone: setZone, setOffset: setOffset, setScale: setScale, scaleBy: scaleBy, setOrder: setOrder,
  setHidden: setHidden, setPreset: setPreset, presetKeeping: presetKeeping, cleanOffset: cleanOffset, cleanScale: cleanScale,
  setStyle: setStyle, setOpacity: setOpacity, cleanOpacity: cleanOpacity, setGlass: setGlass, glassOf: glassOf, hasGlass: hasGlass,
  setScreens: setScreens, resetOffset: resetOffset, offsetPixels: offsetPixels, pixelsToSteps: pixelsToSteps, stepsToPixels: stepsToPixels,
  SCENE_LIMITS: SCENE_LIMITS, setBackground: setBackground, setPicture: setPicture, setGlassLook: setGlassLook,
  history: history, push: push, undo: undo, redo: redo, canUndo: canUndo, canRedo: canRedo,
  gridStep: gridStep, snapRadius: snapRadius, dragAxis: dragAxis, zonesFor: zonesFor, bounds: bounds, clampRect: clampRect,
  nearestAnchor: nearestAnchor, snap: snap, drop: drop, offsetFrom: offsetFrom, neighbourZone: neighbourZone, nudge: nudge, gridMove: gridMove,
  resizeScale: resizeScale, probeLook: probeLook, draggedLook: draggedLook, scaledLook: scaledLook,
  problemElements: problemElements, neighbourModule: neighbourModule,
  REFERENCE_SIZES: REFERENCE_SIZES, monitorEntries: monitorEntries, scalePercent: scalePercent
}
