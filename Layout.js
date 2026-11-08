// The lock-screen layout model: elements, zones, styles, presets, the
// settings group (preset, layout, background, glass) and the rules the view
// relies on. Pure functions over plain data; the view does the geometry.
//
// A layout maps each element to { zone, style, order, hidden } and the
// optional scale, opacity, offset, glass and screens (see ELEMENT_KEYS). Zones are a
// 3×3 grid named by row (top, middle, bottom) and column (start, center,
// end); start and end mean left and right in left-to-right languages and
// mirror in right-to-left ones. Elements in one zone stack by `order`.

// `calendar` came last (1.3.0), so the tie-break order of the others holds.
var ELEMENTS = ["date", "clock", "account", "password", "media", "status", "calendar"]
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
  clock: ["thin", "bold", "stacked", "mono", "outline", "dots", "flip", "analog", "small", "poster", "ring"],
  account: ["avatar", "chip", "name"],
  password: ["pill", "underline", "box", "dots", "terminal", "card"],
  media: ["card", "line", "pill", "art"],
  status: ["text", "icons", "pill", "system"],
  calendar: ["card", "plain"]
}
// The field stays where a hand and an eye expect it: never in the top row.
var PASSWORD_ZONES = ["middle-start", "middle-center", "middle-end", "bottom-start", "bottom-center", "bottom-end"]
var ELEMENT_KEYS = ["zone", "style", "order", "hidden", "scale", "opacity", "offset", "glass", "screens"]
// Free placement and finish (1.3.0), every key optional; absent means the
// default, which draws exactly as before:
// - scale: the element's size, a multiple of 0.05 (default 1).
// - opacity: the whole element's opacity (default 1).
// - offset: { x, y }, both required: a move from the zone position, as a
//   fraction of the screen's width and height; x mirrors in right-to-left
//   languages, like start and end. It never moves the rest of the stack.
// - glass: the opacity of the element's own glass surface, in place of the
//   look's glass.opacity (absent: the look's applies). Only GLASS_STYLES
//   draw one; other styles of the element ignore it, and the date (which
//   has none) rejects the key.
// - screens: "all", or "primary" (only the screen that gets the keys).
// The password field has tighter limits, so it stays legible and in reach.
var LIMITS = {
  scale: { min: 0.5, max: 2, step: 0.05 },
  opacity: { min: 0.3, max: 1 },
  offset: { min: -0.5, max: 0.5 },
  glass: { min: 0, max: 1 }
}
var PASSWORD_LIMITS = {
  scale: { min: 0.85, max: 1.5, step: 0.05 },
  opacity: { min: 0.7, max: 1 },
  offset: { min: -0.5, max: 0.5 },
  glass: { min: 0.08, max: 1 }
}
var SCREENS = ["all", "primary"]
// The account and the field already follow the primary screen (see
// isPrimary); they take no `screens`.
var SCREENS_ELEMENTS = ["date", "clock", "media", "status", "calendar"]
// The styles that draw a glass surface, per element.
var GLASS_STYLES = {
  clock: ["analog", "ring"],
  account: ["chip"],
  password: ["pill", "box", "card"],
  media: ["card", "pill", "art"],
  status: ["pill", "system"],
  calendar: ["card"]
}
// The defaults of the optional keys, left out of a canonical look.
var ELEMENT_DEFAULTS = { scale: 1, opacity: 1, screens: "all" }
// The last three are drawn by the view in the theme's colours.
var BACKGROUND_SOURCES = ["omarchy", "picture", "theme", "black", "aurora", "rain", "constellation"]
var DRAWN_SOURCES = ["aurora", "rain", "constellation"]
var BACKGROUND_KEYS = ["source", "path", "blur", "dim", "decor"]
// Shapes drawn over the background, behind the elements, fitted to the zones
// they belong to (see LockView and elements/Decoration.qml).
var DECORATIONS = ["none", "split", "sheet", "cinema", "strip", "island", "frame", "card"]
// These hold the bottom row in a band along the bottom edge, so the
// bottom-center stack drops into it instead of resting at 65% height.
var BAND_DECORATIONS = ["cinema", "strip"]
// How the glass surfaces are tinted: "none" (white glass, as before),
// "accent" (the theme accent on the edges) or "solid" (opaque, no edges).
var GLASS_TINTS = ["none", "accent", "solid"]
var GLASS_KEYS = ["opacity", "tint"]
var PICTURE_PATTERN = /\.(png|jpe?g|webp)$/i

function element(zone, style, order, hidden) {
  return { zone: zone, style: style, order: order, hidden: !!hidden }
}

function background(source, blur, dim, decor) {
  return { source: source, path: "", blur: blur, dim: dim, decor: decor || "none" }
}

// The calendar is new in 1.3.0; the older presets keep it hidden.
function noCalendar() {
  return element("middle-end", "card", 0, true)
}

// A preset from the elements it shows; everything not named is hidden in a
// zone of its own. `shown` maps element names to [zone, style, order].
function compose(shown, back, glass) {
  var hiddenAt = { date: ["top-center", "long"], clock: ["top-center", "thin"], account: ["bottom-center", "avatar"],
    media: ["bottom-start", "card"], status: ["top-end", "text"], calendar: ["middle-end", "card"] }
  var elements = {}
  for (var i = 0; i < ELEMENTS.length; i++) {
    var name = ELEMENTS[i]
    var spec = shown[name]
    elements[name] = spec ? element(spec[0], spec[1], spec[2] || 0) : element(hiddenAt[name][0], hiddenAt[name][1], 0, true)
  }
  var preset = { elements: elements, background: back }
  if (glass) preset.glass = glass
  return preset
}

// Built-in presets. `foamy` is the 1.2.0 lock screen and the default;
// `field-only` is the last-resort fallback and can't be chosen. The presets
// after `zen` are inspired by the layouts of Lock Designs
// (KamradSmeshnyavy/omarchy-lock-designs, MIT), rebuilt from this model.
var PRESETS = {
  "foamy": {
    elements: {
      date: element("top-center", "long", 0),
      clock: element("top-center", "thin", 1),
      account: element("bottom-center", "avatar", 0),
      password: element("bottom-center", "pill", 1),
      media: element("bottom-start", "card", 0),
      status: element("top-end", "text", 0),
      calendar: noCalendar()
    },
    background: background("omarchy", 0, 0.25)
  },
  "corner": {
    elements: {
      date: element("bottom-start", "caps", 0),
      clock: element("bottom-start", "bold", 1),
      account: element("bottom-end", "chip", 0),
      password: element("bottom-end", "underline", 1),
      media: element("top-start", "line", 0),
      status: element("top-end", "icons", 0),
      calendar: noCalendar()
    },
    background: background("omarchy", 0, 0.3)
  },
  "editorial": {
    elements: {
      date: element("middle-start", "caps", 0),
      clock: element("middle-start", "bold", 1),
      account: element("middle-start", "chip", 2),
      password: element("middle-start", "underline", 3),
      media: element("bottom-start", "line", 0),
      status: element("top-end", "text", 0),
      calendar: noCalendar()
    },
    background: background("omarchy", 0, 0.45)
  },
  "zen": {
    elements: {
      date: element("top-center", "long", 0, true),
      clock: element("top-center", "thin", 1, true),
      account: element("bottom-center", "avatar", 0, true),
      password: element("middle-center", "underline", 0),
      media: element("bottom-start", "card", 0, true),
      status: element("top-end", "text", 0, true),
      calendar: noCalendar()
    },
    background: background("omarchy", 1, 0.4)
  },
  // Everything in one band along the bottom.
  "dock": compose({ clock: ["bottom-start", "small"], password: ["bottom-center", "box"], date: ["bottom-end", "short"],
    media: ["top-start", "line"], status: ["top-end", "icons"] }, background("omarchy", 0.3, 0.2, "strip")),
  // The time and date in a pill at the top, the field in the middle.
  "island": compose({ clock: ["top-center", "small"], date: ["top-center", "short", 1], password: ["middle-center", "box"],
    media: ["bottom-start", "line"], status: ["top-end", "icons"] }, background("omarchy", 0.4, 0.25, "island")),
  // A solid panel on the start side with the clock and the field.
  "split": compose({ date: ["middle-start", "caps"], clock: ["middle-start", "bold", 1], account: ["middle-start", "name", 2],
    password: ["middle-start", "box", 3], media: ["bottom-start", "line"], status: ["top-end", "text"] },
  background("omarchy", 0, 0.1, "split")),
  // A frosted panel on the end side with the account, clock and field.
  "sheet": compose({ account: ["middle-end", "avatar"], clock: ["middle-end", "thin", 1], date: ["middle-end", "long", 2],
    password: ["middle-end", "pill", 3], media: ["bottom-start", "card"], status: ["top-start", "icons"] },
  background("omarchy", 0, 0.12, "sheet")),
  // A greeting card in the middle.
  "card": compose({ account: ["middle-center", "avatar"], clock: ["middle-center", "small", 1], date: ["middle-center", "short", 2],
    password: ["middle-center", "box", 3], media: ["bottom-start", "line"], status: ["top-end", "icons"] },
  background("omarchy", 0.5, 0.3, "card")),
  // Black bars top and bottom: the time in one, the field in the other.
  "cinema": compose({ clock: ["top-center", "small"], date: ["top-center", "caps", 1], password: ["bottom-center", "underline"] },
    background("omarchy", 0, 0.1, "cinema")),
  // Huge hours over minutes.
  "poster": compose({ date: ["middle-start", "caps"], clock: ["middle-start", "poster", 1], password: ["bottom-start", "underline"],
    media: ["bottom-end", "line"], status: ["top-end", "text"] }, background("omarchy", 0, 0.35)),
  "analog": compose({ clock: ["middle-center", "analog"], date: ["middle-center", "long", 1], password: ["middle-center", "pill", 2],
    media: ["bottom-start", "card"], status: ["top-end", "text"] }, background("omarchy", 0.2, 0.3)),
  "flip": compose({ clock: ["middle-center", "flip"], date: ["middle-center", "caps", 1], password: ["middle-center", "box", 2],
    media: ["bottom-start", "pill"], status: ["top-end", "icons"] }, background("omarchy", 0.2, 0.3)),
  // The time inside a ring that fills over the hour.
  "ring": compose({ clock: ["middle-center", "ring"], date: ["middle-center", "short", 1], password: ["middle-center", "pill", 2],
    media: ["bottom-start", "line"], status: ["top-end", "icons"] }, background("omarchy", 0.2, 0.3)),
  // The clock and field beside this month's calendar.
  "calendar": compose({ date: ["middle-start", "caps"], clock: ["middle-start", "bold", 1], password: ["middle-start", "box", 2],
    calendar: ["middle-end", "card"], media: ["bottom-start", "line"], status: ["top-end", "text"] },
  background("omarchy", 0, 0.3)),
  // A console login on black.
  "terminal": compose({ date: ["top-start", "caps"], clock: ["top-start", "mono", 1], account: ["middle-start", "name"],
    password: ["middle-start", "terminal", 1], status: ["top-end", "icons"] }, background("black", 0, 0)),
  // Accent edges and a glowing frame over a dark wallpaper.
  "neon": compose({ date: ["middle-center", "caps"], clock: ["middle-center", "outline", 1], password: ["middle-center", "box", 2],
    status: ["top-end", "icons"] }, background("omarchy", 0, 0.7, "frame"), { opacity: 1, tint: "accent" }),
  // Uptime, memory, load and battery beside the clock and field.
  "system": compose({ date: ["middle-start", "caps"], clock: ["middle-start", "bold", 1], password: ["middle-start", "box", 2],
    status: ["middle-end", "system"], media: ["bottom-start", "line"] }, background("omarchy", 0, 0.35)),
  // Now playing in the middle, artwork first.
  "music": compose({ clock: ["top-center", "small"], date: ["top-center", "short", 1], media: ["middle-center", "art"],
    password: ["middle-center", "pill", 1], status: ["top-end", "icons"] }, background("omarchy", 0.5, 0.35)),
  "aurora": compose({ date: ["middle-center", "long"], clock: ["middle-center", "thin", 1], password: ["middle-center", "pill", 2],
    media: ["bottom-start", "card"], status: ["top-end", "text"] }, background("aurora", 0, 0.1)),
  "rain": compose({ clock: ["middle-center", "mono"], date: ["middle-center", "caps", 1], password: ["middle-center", "terminal", 2],
    status: ["top-end", "icons"] }, background("rain", 0, 0, "card")),
  "constellation": compose({ date: ["top-center", "long"], clock: ["top-center", "thin", 1], password: ["middle-center", "dots"],
    status: ["top-end", "icons"] }, background("constellation", 0, 0)),
  // A dot-matrix clock inside a dark bezel.
  "dotmatrix": compose({ clock: ["middle-center", "dots"], date: ["middle-center", "caps", 1], password: ["middle-center", "dots", 2],
    media: ["bottom-start", "line"], status: ["top-end", "icons"] }, background("omarchy", 0, 0.5, "frame")),
  // The dot-matrix layout in three finishes: flat (solid surfaces),
  // frosted (blurred glass) and fluent (a card with accent edges).
  "flat": compose({ clock: ["middle-center", "thin"], date: ["middle-center", "caps", 1], password: ["middle-center", "box", 2],
    media: ["bottom-start", "card"], status: ["top-end", "pill"] }, background("omarchy", 0, 0.3), { opacity: 1, tint: "solid" }),
  "frosted": compose({ date: ["middle-center", "long"], clock: ["middle-center", "thin", 1], password: ["middle-center", "box", 2],
    media: ["bottom-start", "pill"], status: ["top-end", "pill"] }, background("omarchy", 0.8, 0.2)),
  "fluent": compose({ clock: ["middle-center", "bold"], date: ["middle-center", "short", 1], password: ["middle-center", "card", 2],
    media: ["bottom-start", "pill"], status: ["top-end", "pill"] }, background("omarchy", 0.4, 0.25), { opacity: 1, tint: "accent" }),
  "field-only": {
    elements: {
      date: element("top-center", "long", 0, true),
      clock: element("top-center", "thin", 1, true),
      account: element("bottom-center", "avatar", 0, true),
      password: element("middle-center", "pill", 0),
      media: element("bottom-start", "card", 0, true),
      status: element("top-end", "text", 0, true),
      calendar: noCalendar()
    },
    background: background("theme", 0, 0.25)
  }
}
var SELECTABLE_PRESETS = ["foamy", "corner", "editorial", "zen", "dock", "island", "split", "sheet", "card", "cinema",
  "poster", "analog", "flip", "ring", "calendar", "terminal", "neon", "system", "music", "aurora", "rain", "constellation",
  "dotmatrix", "flat", "frosted", "fluent"]
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
  var limits = limitsFor(name)
  if (value.scale !== undefined && !(inRange(value.scale, limits.scale) && onStep(value.scale, limits.scale.step)))
    return "layout." + name + ".scale must be a number from " + limits.scale.min + " to " + limits.scale.max
      + " in steps of " + limits.scale.step
  if (value.opacity !== undefined && !inRange(value.opacity, limits.opacity))
    return "layout." + name + ".opacity must be a number from " + limits.opacity.min + " to " + limits.opacity.max
  if (value.offset !== undefined) {
    var offset = value.offset
    if (!isPlainObject(offset) || offset.x === undefined || offset.y === undefined)
      return "layout." + name + ".offset must be an object with both x and y"
    for (var axis in offset) {
      if (axis !== "x" && axis !== "y") return "layout." + name + ".offset has an unknown key: " + axis
      if (!inRange(offset[axis], limits.offset))
        return "layout." + name + ".offset." + axis + " must be a number from " + limits.offset.min + " to "
          + limits.offset.max + " (a fraction of the screen's " + (axis === "x" ? "width" : "height") + ")"
    }
  }
  if (value.glass !== undefined) {
    if (!GLASS_STYLES[name]) return "layout." + name + ".glass isn't supported: the " + label(name) + " has no glass surface"
    if (!inRange(value.glass, limits.glass))
      return "layout." + name + ".glass must be a number from " + limits.glass.min + " to " + limits.glass.max
  }
  if (value.screens !== undefined) {
    if (SCREENS_ELEMENTS.indexOf(name) === -1)
      return "layout." + name + ".screens isn't supported: the " + label(name) + " always follows the screen that gets the keys"
    if (SCREENS.indexOf(value.screens) === -1) return "layout." + name + ".screens must be one of " + SCREENS.join(", ")
  }
  return ""
}

// An element's name in a message.
function label(name) {
  return name === "password" ? "password field" : name
}

// The ranges of an element's numeric keys (the password's are tighter).
function limitsFor(name) {
  return name === "password" ? PASSWORD_LIMITS : LIMITS
}

function inRange(value, range) {
  return typeof value === "number" && value >= range.min && value <= range.max
}

// A multiple of `step`, allowing for binary fractions (1.15 / 0.05 is 22.999…).
function onStep(value, step) {
  var steps = value / step
  return Math.abs(steps - Math.round(steps)) < 1e-9
}

// What an editor may offer for each element: the numeric ranges, the
// styles that draw glass (null: the element takes no `glass`) and the
// `screens` values (null: it takes none).
function elementLimits() {
  var out = {}
  for (var i = 0; i < ELEMENTS.length; i++) {
    var name = ELEMENTS[i]
    var limits = copy(limitsFor(name))
    out[name] = { scale: limits.scale, opacity: limits.opacity, offset: limits.offset,
      glass: GLASS_STYLES[name] ? { min: limits.glass.min, max: limits.glass.max, styles: GLASS_STYLES[name].slice() } : null,
      screens: SCREENS_ELEMENTS.indexOf(name) !== -1 ? SCREENS.slice() : null }
  }
  return out
}

// One element in canonical form: the optional keys only where they differ
// from their defaults (a zero offset is no offset; glass stays once set),
// and the scale exactly on its step. Absent and default then compare equal.
function canonicalElement(item) {
  if (item.scale !== undefined) item.scale = Math.round(item.scale * 20) / 20
  for (var key in ELEMENT_DEFAULTS) {
    if (item[key] === ELEMENT_DEFAULTS[key]) delete item[key]
  }
  if (item.offset !== undefined) {
    if (item.offset.x === 0 && item.offset.y === 0) delete item.offset
    else item.offset = { x: item.offset.x, y: item.offset.y }
  }
  return item
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
    if (BACKGROUND_KEYS.indexOf(key) === -1) return "background has an unknown key: " + key
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
  if (value.decor !== undefined && DECORATIONS.indexOf(value.decor) === -1)
    return "background.decor must be one of " + DECORATIONS.join(", ")
  return ""
}

function glassError(value) {
  if (!isPlainObject(value)) return "glass must be an object"
  for (var key in value) {
    if (GLASS_KEYS.indexOf(key) === -1) return "glass has an unknown key: " + key
  }
  if (value.opacity !== undefined && (typeof value.opacity !== "number" || !(value.opacity >= 0 && value.opacity <= 1)))
    return "glass.opacity must be a number from 0 to 1"
  if (value.tint !== undefined && GLASS_TINTS.indexOf(value.tint) === -1)
    return "glass.tint must be one of " + GLASS_TINTS.join(", ")
  return ""
}

// The effective look for a preset name and the user's overrides, unchecked.
function merge(presetName, layout, background, glass) {
  var preset = PRESETS[presetName]
  var result = { preset: presetName, elements: copy(preset.elements), background: copy(preset.background),
    glass: { opacity: 1, tint: "none" } }
  for (var p in preset.glass || {}) result.glass[p] = preset.glass[p]
  for (var name in layout || {}) {
    for (var key in layout[name]) result.elements[name][key] = layout[name][key]
    canonicalElement(result.elements[name])
  }
  for (var b in background || {}) result.background[b] = background[b]
  for (var g in glass || {}) result.glass[g] = glass[g]
  return result
}

// A copy of an effective look in canonical form (see canonicalElement), so
// looks compare by what they show: plain foamy with explicit defaults is
// plain foamy.
function canonical(look) {
  var result = copy(look)
  for (var name in (result && result.elements) || {}) canonicalElement(result.elements[name])
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
// The field's top stays below the screen's top third, where a hand and an
// eye expect it, wherever an offset moves it.
function geometryError(field, others, width, height, margin) {
  if (!field || !(field.width > 0) || !(field.height > 0)) return "password-missing"
  if (field.x < margin || field.y < margin || field.x + field.width > width - margin
      || field.y + field.height > height - margin) return "password-offscreen"
  if (field.y < height / 3) return "password-high"
  for (var i = 0; i < others.length; i++) {
    if (intersects(field, others[i], 1)) return "password-overlap"
  }
  return ""
}

// Whether an element is moved from its zone position.
function isOffset(item) {
  return !!item && !!item.offset && (item.offset.x !== 0 || item.offset.y !== 0)
}

// The whole look's geometry check: "" or an error code. `elements` is the
// effective layout, `rects` maps each shown element to its drawn rectangle.
// - The field: as geometryError, against every other shown element.
// - Every element stays on screen (within a pixel): element-offscreen.
// - Elements don't overlap (element-overlap) when they sit in different
//   zones, or when either is offset. Neighbours in one zone's stack may: the
//   clocks pull up into the date on purpose.
function lookGeometryError(elements, rects, width, height, margin) {
  var names = []
  for (var i = 0; i < ELEMENTS.length; i++) if (rects[ELEMENTS[i]]) names.push(ELEMENTS[i])
  var others = []
  for (var j = 0; j < names.length; j++) if (names[j] !== "password") others.push(rects[names[j]])
  var error = geometryError(rects.password, others, width, height, margin)
  if (error) return error
  for (var k = 0; k < names.length; k++) {
    var r = rects[names[k]]
    if (r.x < -1 || r.y < -1 || r.x + r.width > width + 1 || r.y + r.height > height + 1) return "element-offscreen"
  }
  for (var a = 0; a < names.length; a++) {
    for (var b = a + 1; b < names.length; b++) {
      var first = elements[names[a]], second = elements[names[b]]
      if (first.zone === second.zone && !isOffset(first) && !isOffset(second)) continue
      if (intersects(rects[names[a]], rects[names[b]], 1)) return "element-overlap"
    }
  }
  return ""
}

if (typeof module !== "undefined") module.exports = {
  ELEMENTS: ELEMENTS, ZONES: ZONES, STYLES: STYLES, PASSWORD_ZONES: PASSWORD_ZONES, PRESETS: PRESETS,
  SELECTABLE_PRESETS: SELECTABLE_PRESETS, BACKGROUND_SOURCES: BACKGROUND_SOURCES, DRAWN_SOURCES: DRAWN_SOURCES,
  BACKGROUND_KEYS: BACKGROUND_KEYS, DECORATIONS: DECORATIONS, BAND_DECORATIONS: BAND_DECORATIONS, GLASS_TINTS: GLASS_TINTS, GLASS_KEYS: GLASS_KEYS,
  ELEMENT_KEYS: ELEMENT_KEYS, LIMITS: LIMITS, PASSWORD_LIMITS: PASSWORD_LIMITS, SCREENS: SCREENS,
  SCREENS_ELEMENTS: SCREENS_ELEMENTS, GLASS_STYLES: GLASS_STYLES, DEFAULT_PRESET: DEFAULT_PRESET, FALLBACK_PRESET: FALLBACK_PRESET,
  zoneRow: zoneRow, zoneColumn: zoneColumn, screenColumn: screenColumn, layoutError: layoutError,
  elementError: elementError, elementLimits: elementLimits, merge: merge, preset: preset, defaults: defaults, parseLook: parseLook, stack: stack,
  isPrimary: isPrimary, fallbackAfter: fallbackAfter, intersects: intersects, geometryError: geometryError,
  canonical: canonical, isOffset: isOffset, lookGeometryError: lookGeometryError
}
