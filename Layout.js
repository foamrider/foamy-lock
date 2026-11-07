// The lock-screen layout model: elements, zones, styles, presets, the
// settings group (preset, layout, background, glass) and the rules the view
// relies on. Pure functions over plain data; the view does the geometry.
//
// A layout maps each element to { zone, style, order, hidden }. Zones are a
// 3×3 grid named by row (top, middle, bottom) and column (start, center,
// end); start and end mean left and right in left-to-right languages and
// mirror in right-to-left ones. Elements in one zone stack by `order`.

var ELEMENTS = ["date", "clock", "account", "password", "media", "status"]
var ROWS = ["top", "middle", "bottom"]
var COLUMNS = ["start", "center", "end"]
var ZONES = (function() {
  var zones = []
  for (var r = 0; r < ROWS.length; r++)
    for (var c = 0; c < COLUMNS.length; c++) zones.push(ROWS[r] + "-" + COLUMNS[c])
  return zones
})()
var STYLES = {
  date: ["long", "caps", "short", "serif"],
  clock: ["thin", "bold", "stacked", "mono", "outline", "dots", "flip", "analog"],
  account: ["avatar", "chip"],
  password: ["pill", "underline"],
  media: ["card", "line"],
  status: ["text", "icons"]
}
// The field stays where a hand and an eye expect it: never in the top row.
var PASSWORD_ZONES = ["middle-start", "middle-center", "middle-end", "bottom-start", "bottom-center", "bottom-end"]
var ELEMENT_KEYS = ["zone", "style", "order", "hidden"]
var BACKGROUND_SOURCES = ["omarchy", "picture", "theme", "black"]
var PICTURE_PATTERN = /\.(png|jpe?g|webp)$/i

function element(zone, style, order, hidden) {
  return { zone: zone, style: style, order: order, hidden: !!hidden }
}

// Built-in presets. `foamy` is the 1.2.0 lock screen and the default;
// `field-only` is the last-resort fallback and can't be chosen.
var PRESETS = {
  "foamy": {
    elements: {
      date: element("top-center", "long", 0),
      clock: element("top-center", "thin", 1),
      account: element("bottom-center", "avatar", 0),
      password: element("bottom-center", "pill", 1),
      media: element("bottom-start", "card", 0),
      status: element("top-end", "text", 0)
    },
    background: { source: "omarchy", path: "", blur: 0, dim: 0.25 }
  },
  "corner": {
    elements: {
      date: element("bottom-start", "caps", 0),
      clock: element("bottom-start", "bold", 1),
      account: element("bottom-end", "chip", 0),
      password: element("bottom-end", "underline", 1),
      media: element("top-start", "line", 0),
      status: element("top-end", "icons", 0)
    },
    background: { source: "omarchy", path: "", blur: 0, dim: 0.3 }
  },
  "editorial": {
    elements: {
      date: element("middle-start", "caps", 0),
      clock: element("middle-start", "bold", 1),
      account: element("middle-start", "chip", 2),
      password: element("middle-start", "underline", 3),
      media: element("bottom-start", "line", 0),
      status: element("top-end", "text", 0)
    },
    background: { source: "omarchy", path: "", blur: 0, dim: 0.45 }
  },
  "zen": {
    elements: {
      date: element("top-center", "long", 0, true),
      clock: element("top-center", "thin", 1, true),
      account: element("bottom-center", "avatar", 0, true),
      password: element("middle-center", "underline", 0),
      media: element("bottom-start", "card", 0, true),
      status: element("top-end", "text", 0, true)
    },
    background: { source: "omarchy", path: "", blur: 1, dim: 0.4 }
  },
  "field-only": {
    elements: {
      date: element("top-center", "long", 0, true),
      clock: element("top-center", "thin", 1, true),
      account: element("bottom-center", "avatar", 0, true),
      password: element("middle-center", "pill", 0),
      media: element("bottom-start", "card", 0, true),
      status: element("top-end", "text", 0, true)
    },
    background: { source: "theme", path: "", blur: 0, dim: 0.25 }
  }
}
var SELECTABLE_PRESETS = ["foamy", "corner", "editorial", "zen"]
var DEFAULT_PRESET = "foamy"
var FALLBACK_PRESET = "field-only"

function copy(value) {
  return JSON.parse(JSON.stringify(value))
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function zoneRow(zone) { return String(zone).split("-")[0] }
function zoneColumn(zone) { return String(zone).split("-")[1] }

// The column on screen: start and end swap in right-to-left languages.
function screenColumn(zone, rightToLeft) {
  var column = zoneColumn(zone)
  if (!rightToLeft || column === "center") return column
  return column === "start" ? "end" : "start"
}

// One element's overrides: only known keys, with valid values. Returns an
// error string ("" when valid).
function elementError(name, value) {
  if (!isPlainObject(value)) return "layout." + name + " must be an object"
  for (var key in value) {
    if (ELEMENT_KEYS.indexOf(key) === -1) return "layout." + name + " has an unknown key: " + key
  }
  if (value.zone !== undefined && ZONES.indexOf(value.zone) === -1)
    return "layout." + name + ".zone must be one of " + ZONES.join(", ")
  if (value.style !== undefined && STYLES[name].indexOf(value.style) === -1)
    return "layout." + name + ".style must be one of " + STYLES[name].join(", ")
  if (value.order !== undefined && (typeof value.order !== "number" || Math.floor(value.order) !== value.order
      || value.order < -99 || value.order > 99))
    return "layout." + name + ".order must be an integer from -99 to 99"
  if (value.hidden !== undefined && typeof value.hidden !== "boolean")
    return "layout." + name + ".hidden must be true or false"
  return ""
}

// The rules every effective layout must meet, built in or merged. "" when
// valid.
function layoutError(elements) {
  for (var i = 0; i < ELEMENTS.length; i++) {
    var name = ELEMENTS[i]
    var item = elements[name]
    if (!item) return "layout has no " + name
    if (ZONES.indexOf(item.zone) === -1 || STYLES[name].indexOf(item.style) === -1)
      return "layout." + name + " is incomplete"
  }
  var password = elements.password
  if (password.hidden) return "the password field can't be hidden"
  if (PASSWORD_ZONES.indexOf(password.zone) === -1)
    return "the password field belongs in the middle or bottom row (" + PASSWORD_ZONES.join(", ") + ")"
  return ""
}

function backgroundError(value) {
  if (!isPlainObject(value)) return "background must be an object"
  for (var key in value) {
    if (["source", "path", "blur", "dim"].indexOf(key) === -1) return "background has an unknown key: " + key
  }
  if (value.source !== undefined && BACKGROUND_SOURCES.indexOf(value.source) === -1)
    return "background.source must be one of " + BACKGROUND_SOURCES.join(", ")
  if (value.path !== undefined && (typeof value.path !== "string" || value.path.length > 4096
      || (value.path !== "" && (value.path[0] !== "/" || value.path.indexOf("\u0000") !== -1
        || value.path.split("/").indexOf("..") !== -1 || !PICTURE_PATTERN.test(value.path)))))
    return "background.path must be an absolute .png, .jpg or .webp path without parent traversal"
  if (value.blur !== undefined && (typeof value.blur !== "number" || !(value.blur >= 0 && value.blur <= 1)))
    return "background.blur must be a number from 0 to 1"
  if (value.dim !== undefined && (typeof value.dim !== "number" || !(value.dim >= 0 && value.dim <= 0.9)))
    return "background.dim must be a number from 0 to 0.9"
  return ""
}

function glassError(value) {
  if (!isPlainObject(value)) return "glass must be an object"
  for (var key in value) {
    if (key !== "opacity") return "glass has an unknown key: " + key
  }
  if (value.opacity !== undefined && (typeof value.opacity !== "number" || !(value.opacity >= 0 && value.opacity <= 1)))
    return "glass.opacity must be a number from 0 to 1"
  return ""
}

// The effective look for a preset name and the user's overrides, unchecked.
function merge(presetName, layout, background, glass) {
  var preset = PRESETS[presetName]
  var result = { preset: presetName, elements: copy(preset.elements), background: copy(preset.background),
    glass: { opacity: 1 } }
  for (var name in layout || {}) {
    for (var key in layout[name]) result.elements[name][key] = layout[name][key]
  }
  for (var b in background || {}) result.background[b] = background[b]
  for (var g in glass || {}) result.glass[g] = glass[g]
  return result
}

// The look for a built-in preset without overrides.
function preset(name) {
  return merge(PRESETS[name] ? name : DEFAULT_PRESET, null, null, null)
}

function defaults() {
  return preset(DEFAULT_PRESET)
}

// Parse the look keys of the foamy.lock entry: preset, layout, background,
// glass. Validated apart from the other settings, so a layout mistake never
// resets privacy or behaviour settings. { valid, look, error }.
function parseLook(entry) {
  var source = isPlainObject(entry) ? entry : {}
  var name = source.preset === undefined ? DEFAULT_PRESET : source.preset
  if (SELECTABLE_PRESETS.indexOf(name) === -1)
    return { valid: false, look: null, error: "preset must be one of " + SELECTABLE_PRESETS.join(", ") }
  var layout = source.layout === undefined ? {} : source.layout
  if (!isPlainObject(layout)) return { valid: false, look: null, error: "layout must be an object" }
  for (var element in layout) {
    if (ELEMENTS.indexOf(element) === -1)
      return { valid: false, look: null, error: "layout has an unknown element: " + element }
    var error = elementError(element, layout[element])
    if (error) return { valid: false, look: null, error: error }
  }
  var background = source.background === undefined ? {} : source.background
  var backgroundProblem = backgroundError(background)
  if (backgroundProblem) return { valid: false, look: null, error: backgroundProblem }
  var glass = source.glass === undefined ? {} : source.glass
  var glassProblem = glassError(glass)
  if (glassProblem) return { valid: false, look: null, error: glassProblem }
  var look = merge(name, layout, background, glass)
  if (look.background.source === "picture" && !look.background.path)
    return { valid: false, look: null, error: "background.path is required for source picture" }
  var problem = layoutError(look.elements)
  if (problem) return { valid: false, look: null, error: problem }
  return { valid: true, look: look, error: "" }
}

// Element names in `zone`, in stacking order, without hidden ones and
// without those `visible` (an optional { name: bool }) marks absent.
function stack(elements, zone, visible) {
  var names = []
  for (var i = 0; i < ELEMENTS.length; i++) {
    var name = ELEMENTS[i]
    var item = elements[name]
    if (item.zone !== zone || item.hidden) continue
    if (visible && visible[name] === false) continue
    names.push(name)
  }
  names.sort(function(a, b) {
    return elements[a].order - elements[b].order || ELEMENTS.indexOf(a) - ELEMENTS.indexOf(b)
  })
  return names
}

// The surface that gets the keys shows the account and the field; with no
// surface known to have them (or one without a screen yet), every surface
// does, so a field is never missing where keys arrive.
function isPrimary(surfaceActive, anyActive, hasScreen) {
  return !hasScreen || !anyActive || !!surfaceActive
}

// After a geometry failure on the look `presetName`: the next stage to try,
// or "" when there is none left.
function fallbackAfter(presetName) {
  if (presetName === FALLBACK_PRESET) return ""
  if (presetName === DEFAULT_PRESET) return FALLBACK_PRESET
  return DEFAULT_PRESET
}

// Rectangles { x, y, width, height }: do they overlap by more than `slack`?
function intersects(a, b, slack) {
  var s = slack || 0
  return a.x + s < b.x + b.width && b.x + s < a.x + a.width
    && a.y + s < b.y + b.height && b.y + s < a.y + a.height
}

// The geometry check for the password element: "" or an error code.
// `field` is its rectangle, `others` the visible elements' rectangles, the
// view `width` × `height`, and `margin` the space it keeps from the edges.
function geometryError(field, others, width, height, margin) {
  if (!field || !(field.width > 0) || !(field.height > 0)) return "password-missing"
  if (field.x < margin || field.y < margin || field.x + field.width > width - margin
      || field.y + field.height > height - margin) return "password-offscreen"
  for (var i = 0; i < others.length; i++) {
    if (intersects(field, others[i], 1)) return "password-overlap"
  }
  return ""
}

if (typeof module !== "undefined") module.exports = {
  ELEMENTS: ELEMENTS, ZONES: ZONES, STYLES: STYLES, PASSWORD_ZONES: PASSWORD_ZONES, PRESETS: PRESETS,
  SELECTABLE_PRESETS: SELECTABLE_PRESETS, BACKGROUND_SOURCES: BACKGROUND_SOURCES, ELEMENT_KEYS: ELEMENT_KEYS, DEFAULT_PRESET: DEFAULT_PRESET, FALLBACK_PRESET: FALLBACK_PRESET,
  zoneRow: zoneRow, zoneColumn: zoneColumn, screenColumn: screenColumn, layoutError: layoutError,
  merge: merge, preset: preset, defaults: defaults, parseLook: parseLook, stack: stack,
  isPrimary: isPrimary, fallbackAfter: fallbackAfter, intersects: intersects, geometryError: geometryError
}
