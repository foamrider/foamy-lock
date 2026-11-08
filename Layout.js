// The lock-screen layout model: elements, zones, styles, presets, the
// settings group (preset, layout, background, glass) and the rules the view
// relies on. Pure functions over plain data; the view does the geometry.
//
// A layout maps each element to { zone, style, order, hidden } and the
// optional scale, opacity, offset, glass and screens (see ELEMENT_KEYS), plus
// a few keys of its own on some elements (ELEMENT_OPTIONS). Zones are a
// 3×3 grid named by row (top, middle, bottom) and column (start, center,
// end); start and end mean left and right in left-to-right languages and
// mirror in right-to-left ones. Elements in one zone stack by `order`.

// `calendar` came last (1.3.0) and `weather` after it, so the tie-break
// order of the others holds.
var ELEMENTS = ["date", "clock", "account", "password", "media", "status", "calendar", "weather"]
var ROWS = ["top", "middle", "bottom"]
var COLUMNS = ["start", "center", "end"]
var ZONES = (function() {
  var zones = []
  for (var r = 0; r < ROWS.length; r++)
    for (var c = 0; c < COLUMNS.length; c++) zones.push(ROWS[r] + "-" + COLUMNS[c])
  return zones
})()
var STYLES = {
  date: ["long", "caps", "short", "serif", "numeric", "stacked", "week"],
  clock: ["thin", "bold", "stacked", "mono", "outline", "dots", "flip", "analog", "small", "poster", "ring", "serif"],
  account: ["avatar", "chip", "name"],
  password: ["pill", "underline", "box", "dots", "terminal", "card"],
  media: ["card", "line", "pill", "art", "hero", "minimal", "disc"],
  status: ["text", "icons", "pill", "system"],
  calendar: ["card", "plain", "week", "mini"],
  weather: ["compact", "pill", "detailed", "line", "large", "card"]
}
// The field stays where a hand and an eye expect it: never in the top row.
var PASSWORD_ZONES = ["middle-start", "middle-center", "middle-end", "bottom-start", "bottom-center", "bottom-end"]
var ELEMENT_KEYS = ["zone", "style", "order", "hidden", "scale", "opacity", "offset", "glass", "screens"]
// What the status element can show, in any of its styles (`status.items`).
var STATUS_ITEMS = ["network", "battery", "volume", "bluetooth", "keyboard", "uptime", "load", "memory"]
// What each status style shows without `items` (its built-in behaviour):
// "system" shows the battery row, or the network row on a machine without
// one; the others show the battery only where there is one.
var STATUS_DEFAULT_ITEMS = {
  text: ["network", "battery"],
  icons: ["network", "battery"],
  pill: ["network", "battery"],
  system: ["uptime", "memory", "load", "battery"]
}
// Keys only one element takes (1.3.0, round 2), each optional, validated only there:
// - password.reveal: "always" or "typing": the field shows only once
//   something is typed or a state needs it. Every style takes it; its
//   default follows the style (styleDefaults: the pill and dots have always
//   shown only the hint while idle, the others the whole field).
// - status.items: an ordered list of STATUS_ITEMS, each at most once; absent
//   means the style's built-in contents (STATUS_DEFAULT_ITEMS).
// - weather.details: "temperature" (the default) or "full" (adds the
//   condition and today's high and low).
// - weather.location: true shows the place name (default false: a lock
//   screen is seen by anyone).
// - media.artwork: false shows the music icon in place of the player's
//   cover in this look, and no artwork is prepared for it (default true;
//   the showArtwork setting still decides whether there is any).
var ELEMENT_OPTIONS = {
  password: { reveal: { values: ["always", "typing"], fallback: "always", styleDefaults: { pill: "typing", dots: "typing" } } },
  status: { items: { list: STATUS_ITEMS } },
  media: { artwork: { values: [true, false], fallback: true } },
  weather: { details: { values: ["temperature", "full"], fallback: "temperature" },
    location: { values: [false, true], fallback: false } }
}
// The field styles password.reveal applies to (round 4: all of them).
var REVEAL_STYLES = STYLES.password.slice()
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
var SCREENS_ELEMENTS = ["date", "clock", "media", "status", "calendar", "weather"]
// The styles that draw a glass surface, per element.
var GLASS_STYLES = {
  clock: ["analog", "ring"],
  account: ["chip"],
  password: ["pill", "box", "card"],
  media: ["card", "pill", "art"],
  status: ["pill", "system"],
  calendar: ["card", "week"],
  weather: ["pill", "detailed", "card"]
}
// The media styles that draw the cover (the others never prepare artwork).
var ARTWORK_STYLES = ["card", "pill", "art", "hero", "disc"]
// The defaults of the optional keys, left out of a canonical look.
var ELEMENT_DEFAULTS = { scale: 1, opacity: 1, screens: "all" }
// "color" is a solid colour (`color`); "theme" and "black" are its older
// names, still read: the theme's background and #000000 (canonical looks
// say "color"). The drawn ones (DRAWN_SOURCES) are the animations;
// "constellation" is the older name of "stars", still read.
var BACKGROUND_SOURCES = ["omarchy", "picture", "color", "theme", "black", "aurora", "rain", "stars", "constellation",
  "matrix", "snow", "fireflies", "gradient", "ocean"]
// The animations, drawn by the view in the theme's colours (elements/
// Backdrop.qml, a shader each in elements/shaders), in the order Lock
// Studio's picker lists them.
var DRAWN_SOURCES = ["aurora", "rain", "stars", "matrix", "snow", "fireflies", "gradient", "ocean"]
// Older names of animations, read as the one they became.
var DRAWN_ALIASES = { constellation: "stars" }
var BACKGROUND_KEYS = ["source", "path", "blur", "dim", "decor", "motion", "pauseOnBattery", "color"]
// A solid colour's `color`: one of the theme's colours, by name, so it
// follows the theme, or exactly "#rrggbb" (kept in lower case).
var THEME_COLORS = ["background", "accent", "muted", "urgent"]
var HEX_COLOR = /^#[0-9a-fA-F]{6}$/
// The older "black" source's colour, as stored in a look.
var BLACK = "#000000" // foamy-lint: allow hex-colour — a stored look value (the older "black" source), not a UI colour
// A video background (1.3.0): source "picture" with a video `path`, or an
// Omarchy wallpaper that is a video. `motion` is "still" (the default: its
// first frame, and the lock never decodes video) or "play" (the clip Lock
// Studio converted for this file and screen size, if there is one, with
// GPU rendering only). `pauseOnBattery` (default true) holds the frame
// while on battery. Both are left out of a look when they are the default.
var MOTIONS = ["still", "play"]
var BACKGROUND_DEFAULTS = { motion: "still", pauseOnBattery: true, color: "background" }
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
// The containers the helper converts (video-probe and video-convert).
var VIDEO_PATTERN = /\.(mp4|m4v|mov|mkv|webm)$/i

function isVideoPath(path) {
  return VIDEO_PATTERN.test(String(path || ""))
}

function element(zone, style, order, hidden) {
  return { zone: zone, style: style, order: order, hidden: !!hidden }
}

// A preset's background; `decor` names its shapes' template (see template()).
function background(source, blur, dim, decor) {
  return { source: source, path: "", blur: blur, dim: dim, shapes: template(decor || "none") }
}

// A solid colour background (`color`: a THEME_COLORS name or "#rrggbb").
function solid(color, blur, dim, decor) {
  var result = background("color", blur, dim, decor)
  if (color !== BACKGROUND_DEFAULTS.color) result.color = color
  return result
}

// Whether `value` is a solid colour the lock accepts.
function isColor(value) {
  return typeof value === "string" && (THEME_COLORS.indexOf(value) !== -1 || HEX_COLOR.test(value))
}

// The animation a source draws (a DRAWN_SOURCES name, an older name read as
// its new one), or "" when it isn't one.
function drawnSource(source) {
  var name = DRAWN_ALIASES.hasOwnProperty(source) ? DRAWN_ALIASES[source] : source
  return DRAWN_SOURCES.indexOf(name) !== -1 ? name : ""
}

// The solid colour a background shows ("background", "accent", … or
// "#rrggbb"), or "" when it isn't one. The older "theme" and "black" too.
function solidColor(background) {
  if (!background) return ""
  if (background.source === "black") return BLACK
  if (background.source === "theme") return "background"
  if (background.source !== "color") return ""
  return isColor(background.color) ? String(background.color).toLowerCase() : BACKGROUND_DEFAULTS.color
}

// The calendar is new in 1.3.0; the older presets keep it hidden.
function noCalendar() {
  return element("middle-end", "card", 0, true)
}

// The weather came after it; no built-in preset shows it (it needs Foamy
// Weather, and the user turns it on).
function noWeather() {
  return element("top-start", "compact", 0, true)
}

// A preset from the elements it shows; everything not named is hidden in a
// zone of its own. `shown` maps element names to [zone, style, order].
function compose(shown, back, glass) {
  var hiddenAt = { date: ["top-center", "long"], clock: ["top-center", "thin"], account: ["bottom-center", "avatar"],
    media: ["bottom-start", "card"], status: ["top-end", "text"], calendar: ["middle-end", "card"],
    weather: ["top-start", "compact"] }
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
      calendar: noCalendar(),
      weather: noWeather()
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
      calendar: noCalendar(),
      weather: noWeather()
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
      calendar: noCalendar(),
      weather: noWeather()
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
      calendar: noCalendar(),
      weather: noWeather()
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
    password: ["middle-start", "terminal", 1], status: ["top-end", "icons"] }, solid(BLACK, 0, 0)),
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
      calendar: noCalendar(),
      weather: noWeather()
    },
    background: solid("background", 0, 0.25)
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
  var keys = elementKeys(name)
  for (var key in value) {
    if (keys.indexOf(key) === -1) return "layout." + name + " has an unknown key: " + key
  }
  var options = ELEMENT_OPTIONS[name] || {}
  for (var option in options) {
    if (value[option] === undefined) continue
    var problem = optionError(name, option, options[option], value[option])
    if (problem) return problem
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

// The keys `name` takes: the common ones and its own (ELEMENT_OPTIONS).
function elementKeys(name) {
  return ELEMENT_KEYS.concat(Object.keys(ELEMENT_OPTIONS[name] || {}))
}

// One element-only key: a value from its list, or (status.items) an ordered
// list of distinct names. "" when valid.
function optionError(name, key, spec, value) {
  var path = "layout." + name + "." + key
  if (spec.list) {
    if (!Array.isArray(value) || value.length === 0 || value.length > spec.list.length)
      return path + " must be a list of one or more of " + spec.list.join(", ")
    for (var i = 0; i < value.length; i++) {
      if (spec.list.indexOf(value[i]) === -1) return path + " must only name " + spec.list.join(", ")
      if (value.indexOf(value[i]) !== i) return path + " names " + value[i] + " twice"
    }
    return ""
  }
  if (spec.values.indexOf(value) === -1) {
    var booleans = typeof spec.values[0] === "boolean"
    return path + " must be " + (booleans ? "true or false" : "one of " + spec.values.join(", "))
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
// styles that draw glass (null: the element takes no `glass`), the
// `screens` values (null: it takes none) and its own keys (`options`:
// { key: { values, default } } or, for status.items, { items, defaults }
// with each style's built-in contents; {} when it has none).
function elementLimits() {
  var out = {}
  for (var i = 0; i < ELEMENTS.length; i++) {
    var name = ELEMENTS[i]
    var limits = copy(limitsFor(name))
    out[name] = { scale: limits.scale, opacity: limits.opacity, offset: limits.offset,
      glass: GLASS_STYLES[name] ? { min: limits.glass.min, max: limits.glass.max, styles: GLASS_STYLES[name].slice() } : null,
      screens: SCREENS_ELEMENTS.indexOf(name) !== -1 ? SCREENS.slice() : null,
      options: elementOptions(name) }
  }
  return out
}

function elementOptions(name) {
  var out = {}
  var options = ELEMENT_OPTIONS[name] || {}
  for (var key in options) {
    var spec = options[key]
    out[key] = spec.list ? { items: spec.list.slice(), defaults: copy(STATUS_DEFAULT_ITEMS) }
      : { values: spec.values.slice(), default: spec.fallback }
  }
  if (name === "password") {
    out.reveal.styles = REVEAL_STYLES.slice()
    out.reveal.defaults = {}
    for (var i = 0; i < STYLES.password.length; i++) out.reveal.defaults[STYLES.password[i]] = optionDefault("reveal", STYLES.password[i])
  }
  return out
}

// An element-only key's default for an element of `style` (each key belongs
// to one element): its own default, or its style's (password.reveal).
function optionDefault(key, style) {
  for (var name in ELEMENT_OPTIONS) {
    var spec = ELEMENT_OPTIONS[name][key]
    if (!spec || spec.list) continue
    return spec.styleDefaults && spec.styleDefaults[style] !== undefined ? spec.styleDefaults[style] : spec.fallback
  }
  return undefined
}

// Whether the key's default depends on the element's style.
function optionFollowsStyle(key) {
  for (var name in ELEMENT_OPTIONS) if (ELEMENT_OPTIONS[name][key] && ELEMENT_OPTIONS[name][key].styleDefaults) return true
  return false
}

// The field's effective reveal: its own, else its style's default.
function revealOf(item) {
  return item && item.reveal !== undefined ? item.reveal : optionDefault("reveal", item ? item.style : "")
}

// The element-only keys with a default (each key belongs to one element;
// optionDefault gives it for a style).
var OPTION_KEYS = (function() {
  var out = []
  for (var name in ELEMENT_OPTIONS)
    for (var key in ELEMENT_OPTIONS[name]) if (!ELEMENT_OPTIONS[name][key].list) out.push(key)
  return out
})()

// One element in canonical form: the optional keys only where they differ
// from their defaults (an element-only key's for its style; a zero offset
// is no offset; glass stays once set),
// and the scale exactly on its step. Absent and default then compare equal.
// `items` stays as given: absent (the style's own contents) is not the same
// as naming them.
function canonicalElement(item) {
  if (item.scale !== undefined) item.scale = Math.round(item.scale * 20) / 20
  for (var key in ELEMENT_DEFAULTS) {
    if (item[key] === ELEMENT_DEFAULTS[key]) delete item[key]
  }
  for (var o = 0; o < OPTION_KEYS.length; o++) {
    var option = OPTION_KEYS[o]
    if (item[option] !== undefined && item[option] === optionDefault(option, item.style)) delete item[option]
  }
  if (Array.isArray(item.items)) item.items = item.items.slice()
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
        || value.path.split("/").indexOf("..") !== -1 || !(PICTURE_PATTERN.test(value.path) || isVideoPath(value.path))))))
    return "background.path must be an absolute picture (.png, .jpg, .webp) or video (.mp4, .m4v, .mov, .mkv, .webm) path without parent traversal"
  if (value.blur !== undefined && (typeof value.blur !== "number" || !(value.blur >= 0 && value.blur <= 1)))
    return "background.blur must be a number from 0 to 1"
  if (value.dim !== undefined && (typeof value.dim !== "number" || !(value.dim >= 0 && value.dim <= 0.9)))
    return "background.dim must be a number from 0 to 0.9"
  if (value.decor !== undefined && DECORATIONS.indexOf(value.decor) === -1)
    return "background.decor must be one of " + DECORATIONS.join(", ")
  var shapeProblem = backgroundShapesError(value)
  if (shapeProblem) return shapeProblem
  if (value.motion !== undefined && MOTIONS.indexOf(value.motion) === -1)
    return "background.motion must be one of " + MOTIONS.join(", ")
  if (value.pauseOnBattery !== undefined && typeof value.pauseOnBattery !== "boolean")
    return "background.pauseOnBattery must be true or false"
  if (value.color !== undefined && !isColor(value.color))
    return "background.color must be one of " + THEME_COLORS.join(", ") + " or a colour like #1a1b26"
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
  // The glass first: an older `decor` follows the tint (canonicalShapes).
  for (var g in glass || {}) result.glass[g] = glass[g]
  for (var b in background || {}) result.background[b] = background[b]
  canonicalBackground(result.background)
  canonicalShapes(result.background, result.glass)
  return result
}

// The background's motion keys and colour only where they differ from the
// defaults; the older solid sources ("black", "theme") as "color", an
// animation's older name ("constellation") as its new one, a hex colour in
// lower case, and no colour at all for another source (it shows
// none, so two looks that differ only there are the same look).
function canonicalBackground(background) {
  if (DRAWN_ALIASES.hasOwnProperty(background.source)) background.source = DRAWN_ALIASES[background.source]
  if (background.source === "black" || background.source === "theme") {
    background.color = solidColor(background)
    background.source = "color"
  }
  if (background.source !== "color") delete background.color
  else if (typeof background.color === "string" && HEX_COLOR.test(background.color)) background.color = background.color.toLowerCase()
  for (var key in BACKGROUND_DEFAULTS) {
    if (background[key] === BACKGROUND_DEFAULTS[key]) delete background[key]
  }
  return background
}

// Whether the background plays: motion "play" (pauseOnBattery aside).
function playsVideo(background) {
  return !!background && background.motion === "play"
}

// Whether a playing background holds still on battery (the default).
function pausesOnBattery(background) {
  return !background || background.pauseOnBattery !== false
}

// A copy of an effective look in canonical form (see canonicalElement), so
// looks compare by what they show: plain foamy with explicit defaults is
// plain foamy.
function canonical(look) {
  var result = copy(look)
  for (var name in (result && result.elements) || {}) canonicalElement(result.elements[name])
  if (result && isPlainObject(result.background)) {
    canonicalBackground(result.background)
    canonicalShapes(result.background, result.glass)
  }
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
  BACKGROUND_KEYS: BACKGROUND_KEYS, MOTIONS: MOTIONS, BACKGROUND_DEFAULTS: BACKGROUND_DEFAULTS,
  THEME_COLORS: THEME_COLORS, BLACK: BLACK, isColor: isColor, solidColor: solidColor,
  isVideoPath: isVideoPath, playsVideo: playsVideo, pausesOnBattery: pausesOnBattery, DECORATIONS: DECORATIONS, BAND_DECORATIONS: BAND_DECORATIONS, GLASS_TINTS: GLASS_TINTS, GLASS_KEYS: GLASS_KEYS,
  ELEMENT_KEYS: ELEMENT_KEYS, ELEMENT_OPTIONS: ELEMENT_OPTIONS, STATUS_ITEMS: STATUS_ITEMS,
  STATUS_DEFAULT_ITEMS: STATUS_DEFAULT_ITEMS, REVEAL_STYLES: REVEAL_STYLES, LIMITS: LIMITS, PASSWORD_LIMITS: PASSWORD_LIMITS, SCREENS: SCREENS,
  SCREENS_ELEMENTS: SCREENS_ELEMENTS, GLASS_STYLES: GLASS_STYLES, ARTWORK_STYLES: ARTWORK_STYLES, DEFAULT_PRESET: DEFAULT_PRESET, FALLBACK_PRESET: FALLBACK_PRESET,
  zoneRow: zoneRow, zoneColumn: zoneColumn, screenColumn: screenColumn, layoutError: layoutError,
  elementError: elementError, elementKeys: elementKeys, elementLimits: elementLimits,
  optionDefault: optionDefault, optionFollowsStyle: optionFollowsStyle, revealOf: revealOf, merge: merge, preset: preset, defaults: defaults, parseLook: parseLook, stack: stack,
  isPrimary: isPrimary, fallbackAfter: fallbackAfter, intersects: intersects, geometryError: geometryError,
  canonical: canonical, isOffset: isOffset, lookGeometryError: lookGeometryError
}

// --- user presets (Lock Studio round 2, step R2-2) ----------------------------
//
// `userPresets` in the foamy.lock entry: [{ id, name, look }], newest first,
// `look` holding the four look keys (preset, layout, background, glass) as
// the entry does. A third group, read apart from the settings and the look,
// and item by item: an invalid item is dropped (and counted), the others are
// kept, and nothing here changes the settings or the look. `userPreset` is
// the saved look's link to the preset it came from; an id that isn't in the
// list is ignored (the look itself is always self-contained).
//
// The writes (the lock's savePreset, renamePreset, deletePreset) change one
// item of the entry's own list and keep every other item as it is, invalid
// ones too: an item a newer lock understands is never lost by an older one.
var USER_PRESET_LIMIT = 50
// The whole list as compact JSON, in UTF-8 bytes.
var USER_PRESETS_BYTES = 256 * 1024
var USER_PRESET_NAME_LENGTH = 64
// A short slug made by the client, so a retried save is the same save.
var USER_PRESET_ID = /^[a-z0-9][a-z0-9-]{0,39}$/
var USER_PRESET_KEYS = ["id", "name", "look"]
var LOOK_ENTRY_KEYS = ["preset", "layout", "background", "glass"]

function utf8Length(text) {
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x80) bytes += 1
    else if (code < 0x800) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      bytes += 4
      i++
    } else bytes += 3
  }
  return bytes
}

// The largest IPC argument the lock parses (Omarchy's own cap): a JSON
// argument over it is refused before JSON.parse, so a caller that reaches
// the handler directly can't make the lock parse megabytes. In UTF-8 bytes;
// a string with more UTF-16 units than that is over without counting.
var IPC_ARGUMENT_BYTES = 64 * 1024

// "" when `text` may be parsed, else why not.
function ipcArgumentError(text) {
  text = String(text)
  return text.length > IPC_ARGUMENT_BYTES || utf8Length(text) > IPC_ARGUMENT_BYTES
    ? "argument over " + IPC_ARGUMENT_BYTES + " bytes" : ""
}

function userPresetIdError(id) {
  return typeof id === "string" && USER_PRESET_ID.test(id) ? ""
    : "id must be 1 to 40 lowercase letters, digits and dashes, starting with a letter or digit"
}

// A name as shown: trimmed, 1 to 64 characters, no control characters.
function userPresetNameError(name) {
  if (typeof name !== "string" || name.trim() === "" || name !== name.trim())
    return "name must be a non-empty string without leading or trailing spaces"
  if (name.length > USER_PRESET_NAME_LENGTH) return "name must be at most " + USER_PRESET_NAME_LENGTH + " characters"
  if (/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(name)) return "name must not contain control characters"
  return ""
}

// One item: "" when the lock can use it, else why not.
function userPresetError(item) {
  if (!isPlainObject(item)) return "a user preset must be an object"
  for (var key in item) if (USER_PRESET_KEYS.indexOf(key) === -1) return "a user preset has an unknown key: " + key
  var problem = userPresetIdError(item.id) || userPresetNameError(item.name)
  if (problem) return problem
  if (!isPlainObject(item.look)) return "look must be an object"
  for (var lookKey in item.look)
    if (LOOK_ENTRY_KEYS.indexOf(lookKey) === -1) return "look has an unknown key: " + lookKey
  var parsed = parseLook(item.look)
  return parsed.valid ? "" : parsed.error
}

// The entry's user presets as the lock reads them: { presets: [{ id, name,
// look (the item's own look keys), effective (Layout.merge's shape) }],
// invalid: <items dropped>, error: <the first problem, with its index> }.
// Past USER_PRESET_LIMIT items, or past USER_PRESETS_BYTES, the rest are
// dropped; so is a second item with an id already read.
function parseUserPresets(entry) {
  var list = isPlainObject(entry) ? entry.userPresets : undefined
  var result = { presets: [], invalid: 0, error: "" }
  if (list === undefined) return result
  if (!Array.isArray(list)) return { presets: [], invalid: 1, error: "userPresets must be a list" }
  var seen = {}
  var bytes = 2
  function drop(index, problem) {
    result.invalid++
    if (!result.error) result.error = "userPresets[" + index + "]: " + problem
  }
  // Past the cap (or the bytes) every later item is dropped as well: they
  // are counted at once and never looked at, so a huge list costs no more
  // than the first 50 items.
  function dropRest(index, problem) {
    drop(index, problem)
    result.invalid += list.length - index - 1
  }
  for (var i = 0; i < list.length; i++) {
    if (i >= USER_PRESET_LIMIT) {
      dropRest(i, "only the first " + USER_PRESET_LIMIT + " user presets are read")
      break
    }
    var item = list[i]
    bytes += utf8Length(JSON.stringify(item === undefined ? null : item)) + (i > 0 ? 1 : 0)
    if (bytes > USER_PRESETS_BYTES) {
      dropRest(i, "user presets past " + USER_PRESETS_BYTES + " bytes are not read")
      break
    }
    var problem = userPresetError(item)
    if (!problem && seen[item.id]) problem = "id " + item.id + " is used twice"
    if (problem) drop(i, problem)
    else {
      seen[item.id] = true
      result.presets.push({ id: item.id, name: item.name, look: copy(item.look), effective: parseLook(item.look).look })
    }
  }
  return result
}

// The preset `id` in a parsed list (parseUserPresets().presets), or null.
function findUserPreset(presets, id) {
  for (var i = 0; i < (presets || []).length; i++) if (presets[i].id === id) return presets[i]
  return null
}

// The entry's link (`userPreset`) when it names a preset in `presets`, else "".
function userPresetLink(entry, presets) {
  var id = isPlainObject(entry) ? entry.userPreset : undefined
  return typeof id === "string" && findUserPreset(presets, id) ? id : ""
}

// A copy of `entry` without its id (what updateEntryInline takes), with the
// raw list, or the reply when the list can't be changed.
function presetBase(entry) {
  var next = {}
  for (var key in entry) if (key !== "id") next[key] = copy(entry[key])
  if (next.userPresets !== undefined && !Array.isArray(next.userPresets))
    return { error: "invalid: shell.json's userPresets isn't a list; fix or remove it first", entry: null }
  return { error: "", entry: next, list: next.userPresets || [] }
}

function presetResult(base, list) {
  if (utf8Length(JSON.stringify(list)) > USER_PRESETS_BYTES) return { error: "too-large", entry: null }
  if (list.length > 0) base.userPresets = list
  else delete base.userPresets
  return { error: "", entry: base }
}

// savePreset: `item` (checked with userPresetError) replaces the item with
// its id where it is, or goes first. { error: "" | "full" | "too-large" |
// "invalid: …", entry: the next entry (without id) }.
function savingPreset(entry, item) {
  var base = presetBase(entry)
  if (base.error) return base
  var list = base.list.slice()
  var saved = { id: item.id, name: item.name, look: copy(item.look) }
  var found = -1
  for (var i = 0; i < list.length; i++) {
    if (isPlainObject(list[i]) && list[i].id === item.id) {
      if (found === -1) {
        found = i
        list[i] = saved
      } else list.splice(i--, 1)
    }
  }
  if (found === -1) {
    if (list.length >= USER_PRESET_LIMIT) return { error: "full", entry: null }
    list.unshift(saved)
  }
  return presetResult(base.entry, list)
}

// renamePreset: { error: "" | "unknown-preset" | "too-large" | "invalid: …", entry }.
function renamingPreset(entry, id, name) {
  var base = presetBase(entry)
  if (base.error) return base
  var list = base.list.slice()
  var found = false
  for (var i = 0; i < list.length; i++) {
    if (isPlainObject(list[i]) && list[i].id === id) {
      var renamed = copy(list[i])
      renamed.name = name
      list[i] = renamed
      found = true
    }
  }
  if (!found) return { error: "unknown-preset", entry: null }
  return presetResult(base.entry, list)
}

// deletePreset: every item with `id` goes, and the saved look's link to it
// (the look stays). An id that isn't there changes nothing, so a retried
// delete answers "unchanged". { error: "" | "invalid: …", entry }.
function deletingPreset(entry, id) {
  var base = presetBase(entry)
  if (base.error) return base
  var list = base.list.filter(function(item) { return !(isPlainObject(item) && item.id === id) })
  if (base.entry.userPreset === id) delete base.entry.userPreset
  return presetResult(base.entry, list)
}

if (typeof module !== "undefined") {
  module.exports.USER_PRESET_LIMIT = USER_PRESET_LIMIT
  module.exports.USER_PRESETS_BYTES = USER_PRESETS_BYTES
  module.exports.USER_PRESET_NAME_LENGTH = USER_PRESET_NAME_LENGTH
  module.exports.utf8Length = utf8Length
  module.exports.IPC_ARGUMENT_BYTES = IPC_ARGUMENT_BYTES
  module.exports.ipcArgumentError = ipcArgumentError
  module.exports.userPresetIdError = userPresetIdError
  module.exports.userPresetNameError = userPresetNameError
  module.exports.userPresetError = userPresetError
  module.exports.parseUserPresets = parseUserPresets
  module.exports.findUserPreset = findUserPreset
  module.exports.userPresetLink = userPresetLink
  module.exports.savingPreset = savingPreset
  module.exports.renamingPreset = renamingPreset
  module.exports.deletingPreset = deletingPreset
}

// --- shapes: the decorations (round 5, docs/plans/lock-decorations.md) ---------
//
// `background.shapes`: 0 to 4 shapes, drawn over the background (wallpaper,
// video, drawn source and scrim) and under every element: the frosted ones
// first, then the others in list order. Plain data, nothing loaded. Kinds:
// - "box": a rounded rectangle around what it wraps, plus `pad`; with
//   `stretch: "across"` it spans the screen's width less `inset`.
// - "panel": a rectangle along one screen `edge` (logical start or end, top
//   or bottom), as thick as what it wraps needs (plus `pad`), within `size`.
// - "frame": a border inset from the screen's edges, in a `style`.
// `wrap` is { zones } (the shown elements there, where the zone puts them:
// offsets never drag a zone shape along; on narrow screens a zone stacked
// with another wraps both) or { modules } (the named elements where they
// are drawn: offset, scale and late content included). Lengths are whole
// pixels at 1080p, scaled by the view like every other length. Colours:
// - fill "auto" (the default) follows the glass tint: dark (black) over the
//   plain glass, the look's glass under the accent and solid tints, as the
//   island always did; "glass" is the look's glass, "surface" exactly what
//   the wrapped modules' own surfaces draw, "black" black at `opacity`.
// - frame "auto" follows the tint too: a glow in the accent with the accent
//   tint, a dark bezel otherwise; "bezel", "glow" and "line" are fixed.
// `absorb` makes the shape the wrapped modules' only background (their own
// surfaces aren't drawn; ABSORB_STYLES), never the password field's. Shapes
// never take part in the geometry check and never cause a fallback.
var SHAPE_KINDS = ["box", "panel", "frame"]
var SHAPE_EDGES = ["start", "end", "top", "bottom"]
var SHAPE_STRETCHES = ["none", "across"]
var SHAPE_FILLS = ["auto", "glass", "surface", "black"]
var SHAPE_BORDERS = ["glass", "accent"]
var SHAPE_SIDES = ["all", "inner"]
var FRAME_STYLES = ["auto", "bezel", "glow", "line"]
// A shape's keys in canonical order, and the ones each kind takes.
var SHAPE_KEY_ORDER = ["kind", "edge", "wrap", "pad", "stretch", "inset", "size", "radius", "fill", "border", "absorb", "style"]
var SHAPE_KEYS = {
  box: ["kind", "wrap", "pad", "stretch", "inset", "radius", "fill", "border", "absorb"],
  panel: ["kind", "edge", "wrap", "pad", "inset", "size", "radius", "fill", "border", "absorb"],
  frame: ["kind", "inset", "radius", "style"]
}
var SHAPE_LIMITS = {
  count: 4, frosted: 2, zones: 9, modules: 8,
  pad: { box: { min: 0, max: 120 }, panel: { min: 0, max: 200 } },
  inset: { box: { min: 0, max: 64 }, panel: { min: 0, max: 64 }, frame: { min: 0, max: 24 } },
  radius: { box: { min: 0, max: 200 }, panel: { min: 0, max: 200 }, frame: { min: 0, max: 64 } },
  size: { screen: { min: 0.05, max: 1 }, px: { min: 0, max: 4000 } },
  opacity: { min: 0, max: 1 },
  border: { min: 0, max: 4 }
}
var SHAPE_FILL_DEFAULTS = { color: "auto", opacity: 0.6, frost: false }
var SHAPE_BORDER_DEFAULTS = { color: "glass", width: 1, sides: "all" }
var SHAPE_DEFAULTS = {
  box: { pad: { x: 24, y: 16 }, stretch: "none", inset: 16, radius: 24, fill: SHAPE_FILL_DEFAULTS,
    border: SHAPE_BORDER_DEFAULTS, absorb: false },
  panel: { pad: 32, inset: 0, radius: 0, fill: SHAPE_FILL_DEFAULTS, border: SHAPE_BORDER_DEFAULTS, absorb: false },
  frame: { inset: 12, radius: 22, style: "auto" }
}
// The surfaces `absorb` takes over (the panel-like ones; never the password
// field's, nor the analog and ring clock faces, which are the clock itself).
var ABSORB_STYLES = {
  media: ["card", "pill", "art"],
  status: ["pill", "system"],
  calendar: ["card", "week"],
  weather: ["pill", "detailed", "card"],
  account: ["chip"]
}
// The templates (the older decorations, by name), as Lock Studio offers them.
var SHAPE_TEMPLATES = ["island", "card", "split", "sheet", "strip", "cinema", "frame"]
BACKGROUND_KEYS.push("shapes")

// The shapes of a template, an older `decor` name ("none" and unknown: []).
// Called while PRESETS is built, so it uses nothing defined below it.
function template(name) {
  var row = function(r) { return [r + "-start", r + "-center", r + "-end"] }
  switch (name) {
  case "island":
    return [{ kind: "box", wrap: { zones: ["top-center"] }, pad: { x: 34, y: 12 }, radius: 40, fill: { opacity: 0.82 } }]
  case "card":
    return [{ kind: "box", wrap: { zones: ["middle-center"] }, pad: { x: 36, y: 36 }, radius: 30,
      fill: { color: "glass", opacity: 0.5, frost: true } }]
  case "strip":
    return [{ kind: "box", wrap: { zones: row("bottom") }, pad: { x: 0, y: 14 }, stretch: "across", radius: 20,
      fill: { color: "glass", opacity: 0.72 } }]
  case "split":
    return [{ kind: "panel", edge: "start", wrap: { zones: ["top-start", "middle-start", "bottom-start"] }, pad: 56,
      size: { min: { screen: 0.38 }, fillPast: { screen: 0.62 } }, fill: { color: "glass", opacity: 0.9 },
      border: { color: "accent", width: 3, sides: "inner" } }]
  case "sheet":
    return [{ kind: "panel", edge: "end", wrap: { zones: ["top-end", "middle-end", "bottom-end"] }, pad: 44, inset: 24,
      size: { min: { px: 420 } }, radius: 28, fill: { color: "glass", opacity: 0.55, frost: true } }]
  case "cinema":
    return ["top", "bottom"].map(function(edge) {
      return { kind: "panel", edge: edge, wrap: { zones: row(edge) }, pad: 26, size: { min: { screen: 0.12 }, max: { screen: 0.4 } },
        fill: { color: "black", opacity: 1 }, border: { width: 0 } }
    })
  case "frame":
    return [{ kind: "frame" }]
  }
  return []
}

// An older look's `decor` as shapes, drawn exactly as before: the island
// took the glass at 0.86 under the accent and solid tints.
function legacyShapes(name, tint) {
  var shapes = template(name)
  if (name === "island" && tint && tint !== "none") shapes[0].fill.opacity = 0.86
  return shapes
}

function isInteger(value) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
}

function integerError(path, value, range) {
  return isInteger(value) && value >= range.min && value <= range.max ? ""
    : path + " must be an integer from " + range.min + " to " + range.max
}

function choiceError(path, value, list) {
  return list.indexOf(value) !== -1 ? "" : path + " must be one of " + list.join(", ")
}

// { zones } or { modules }: exactly one key, distinct names. "" when valid.
function wrapError(path, wrap) {
  if (!isPlainObject(wrap) || Object.keys(wrap).length !== 1 || (wrap.zones === undefined && wrap.modules === undefined))
    return path + " must be { \"zones\": [...] } or { \"modules\": [...] }"
  var key = wrap.zones !== undefined ? "zones" : "modules"
  var names = key === "zones" ? ZONES : ELEMENTS
  var list = wrap[key]
  var most = SHAPE_LIMITS[key]
  if (!Array.isArray(list) || list.length === 0 || list.length > most)
    return path + "." + key + " must be a list of 1 to " + most + " of " + names.join(", ")
  for (var i = 0; i < list.length; i++) {
    if (names.indexOf(list[i]) === -1) return path + "." + key + " must only name " + names.join(", ")
    if (list.indexOf(list[i]) !== i) return path + "." + key + " names " + list[i] + " twice"
  }
  return ""
}

// A size: { screen: 0.05–1 } (of the screen across the panel) or { px }.
function lengthError(path, value) {
  var units = isPlainObject(value) ? Object.keys(value) : []
  if (units.length !== 1 || (units[0] !== "screen" && units[0] !== "px"))
    return path + " must be { \"screen\": fraction } or { \"px\": length }"
  if (units[0] === "px") return integerError(path + ".px", value.px, SHAPE_LIMITS.size.px)
  var range = SHAPE_LIMITS.size.screen
  return inRange(value.screen, range) ? "" : path + ".screen must be a number from " + range.min + " to " + range.max
}

// One shape: "" when valid, else the problem with its path.
function shapeError(shape, index) {
  var path = "background.shapes[" + index + "]"
  if (!isPlainObject(shape)) return path + " must be an object"
  if (SHAPE_KINDS.indexOf(shape.kind) === -1) return path + ".kind must be one of " + SHAPE_KINDS.join(", ")
  var kind = shape.kind
  for (var key in shape) {
    if (SHAPE_KEY_ORDER.indexOf(key) === -1) return path + " has an unknown key: " + key
    if (SHAPE_KEYS[kind].indexOf(key) === -1) return path + "." + key + " isn't taken by a " + kind
  }
  var problem = ""
  if (kind === "box" && shape.wrap === undefined) return path + ".wrap is required for a box"
  if (shape.wrap !== undefined && (problem = wrapError(path + ".wrap", shape.wrap))) return problem
  if (kind === "panel" && shape.edge === undefined) return path + ".edge is required for a panel"
  if (shape.edge !== undefined && (problem = choiceError(path + ".edge", shape.edge, SHAPE_EDGES))) return problem
  if (shape.pad !== undefined) {
    if (kind === "box") {
      var pad = shape.pad
      if (!isPlainObject(pad) || pad.x === undefined || pad.y === undefined)
        return path + ".pad must be an object with both x and y"
      for (var axis in pad) {
        if (axis !== "x" && axis !== "y") return path + ".pad has an unknown key: " + axis
        if ((problem = integerError(path + ".pad." + axis, pad[axis], SHAPE_LIMITS.pad.box))) return problem
      }
    } else if ((problem = integerError(path + ".pad", shape.pad, SHAPE_LIMITS.pad.panel))) return problem
  }
  if (shape.stretch !== undefined && (problem = choiceError(path + ".stretch", shape.stretch, SHAPE_STRETCHES))) return problem
  if (shape.inset !== undefined) {
    if (kind === "box" && shape.stretch !== "across") return path + ".inset needs stretch \"across\" on a box"
    if ((problem = integerError(path + ".inset", shape.inset, SHAPE_LIMITS.inset[kind]))) return problem
  }
  if (shape.size !== undefined) {
    var size = shape.size
    if (!isPlainObject(size)) return path + ".size must be an object with min, max or fillPast"
    for (var part in size) {
      if (["min", "max", "fillPast"].indexOf(part) === -1) return path + ".size has an unknown key: " + part
      if ((problem = lengthError(path + ".size." + part, size[part]))) return problem
    }
    if (size.min && size.max && Object.keys(size.min)[0] === Object.keys(size.max)[0]
        && size.min[Object.keys(size.min)[0]] > size.max[Object.keys(size.max)[0]])
      return path + ".size.min must not be more than size.max"
  }
  if (shape.radius !== undefined && !(kind === "box" && shape.radius === "auto")
      && (problem = integerError(path + ".radius", shape.radius, SHAPE_LIMITS.radius[kind])))
    return kind === "box" ? problem + ", or \"auto\"" : problem
  if (shape.fill !== undefined) {
    var fill = shape.fill
    if (!isPlainObject(fill)) return path + ".fill must be an object with color, opacity or frost"
    for (var f in fill) if (["color", "opacity", "frost"].indexOf(f) === -1) return path + ".fill has an unknown key: " + f
    if (fill.color !== undefined && (problem = choiceError(path + ".fill.color", fill.color, SHAPE_FILLS))) return problem
    if (fill.opacity !== undefined && !inRange(fill.opacity, SHAPE_LIMITS.opacity))
      return path + ".fill.opacity must be a number from 0 to 1"
    if (fill.frost !== undefined && typeof fill.frost !== "boolean") return path + ".fill.frost must be true or false"
  }
  if (shape.border !== undefined) {
    var border = shape.border
    if (!isPlainObject(border)) return path + ".border must be an object with color, width or sides"
    for (var b in border) if (["color", "width", "sides"].indexOf(b) === -1) return path + ".border has an unknown key: " + b
    if (border.color !== undefined && (problem = choiceError(path + ".border.color", border.color, SHAPE_BORDERS))) return problem
    if (border.width !== undefined && (problem = integerError(path + ".border.width", border.width, SHAPE_LIMITS.border))) return problem
    if (border.sides !== undefined && (problem = choiceError(path + ".border.sides", border.sides, SHAPE_SIDES))) return problem
    if (border.sides === "inner" && kind !== "panel") return path + ".border.sides \"inner\" is for a panel"
  }
  if (shape.absorb !== undefined && typeof shape.absorb !== "boolean") return path + ".absorb must be true or false"
  if (shape.style !== undefined && (problem = choiceError(path + ".style", shape.style, FRAME_STYLES))) return problem
  return ""
}

function isFrosted(shape) {
  return isPlainObject(shape) && isPlainObject(shape.fill) && shape.fill.frost === true
}

// The background's shapes (and their older spelling, `decor`): "" when valid.
function backgroundShapesError(value) {
  if (value.shapes === undefined) return ""
  if (value.decor !== undefined) return "background can't have both decor and shapes"
  var shapes = value.shapes
  if (!Array.isArray(shapes)) return "background.shapes must be a list of up to " + SHAPE_LIMITS.count + " shapes"
  if (shapes.length > SHAPE_LIMITS.count) return "background.shapes has more than " + SHAPE_LIMITS.count + " shapes"
  for (var i = 0; i < shapes.length; i++) {
    var problem = shapeError(shapes[i], i)
    if (problem) return problem
  }
  if (shapes.filter(isFrosted).length > SHAPE_LIMITS.frosted)
    return "background.shapes has more than " + SHAPE_LIMITS.frosted + " frosted shapes"
  return ""
}

function sameValue(a, b) {
  return JSON.stringify(a) === JSON.stringify(b)
}

// One shape in canonical form: keys in SHAPE_KEY_ORDER, the kind's defaults
// left out (inside fill and border too; an empty fill or border goes),
// `wrap` lists in ZONES or ELEMENTS order. A valid shape stays valid.
function canonicalShape(shape) {
  var kind = shape.kind
  var defaults = SHAPE_DEFAULTS[kind] || {}
  var out = { kind: kind }
  for (var i = 1; i < SHAPE_KEY_ORDER.length; i++) {
    var key = SHAPE_KEY_ORDER[i]
    if (shape[key] === undefined) continue
    var value = copy(shape[key])
    if (key === "wrap") {
      var listKey = value.zones !== undefined ? "zones" : "modules"
      var order = listKey === "zones" ? ZONES : ELEMENTS
      var sorted = {}
      sorted[listKey] = value[listKey].slice().sort(function(a, b) { return order.indexOf(a) - order.indexOf(b) })
      value = sorted
    } else if (key === "pad" && kind === "box") value = { x: value.x, y: value.y }
    else if (key === "size") {
      var size = {}
      var parts = ["min", "max", "fillPast"]
      for (var p = 0; p < parts.length; p++) if (value[parts[p]] !== undefined) size[parts[p]] = value[parts[p]]
      value = size
    } else if (key === "fill" || key === "border") {
      var own = {}
      var subDefaults = defaults[key]
      for (var sub in subDefaults) if (value[sub] !== undefined && value[sub] !== subDefaults[sub]) own[sub] = value[sub]
      if (Object.keys(own).length === 0) continue
      value = own
    }
    // A box's inset belongs to "across" (its default is kept out with it).
    if (key === "inset" && kind === "box" && shape.stretch !== "across") continue
    if (defaults[key] !== undefined && sameValue(value, defaults[key])) continue
    out[key] = value
  }
  return out
}

// The background's shapes in canonical form: an older `decor` becomes its
// shapes (in the look's tint) and goes. The effective look always has a
// list (every preset has one), never `decor`.
function canonicalShapes(background, glass) {
  if (background.decor !== undefined) {
    background.shapes = legacyShapes(background.decor, glass ? glass.tint : "none")
    delete background.decor
  }
  if (Array.isArray(background.shapes)) background.shapes = background.shapes.map(canonicalShape)
  return background
}

// Whether the shapes hold the bottom row in a band along the bottom edge
// (the bottom-center stack then drops into it). From the data alone, never
// from geometry: a bottom panel, or a box across the screen, that wraps the
// bottom-center zone. A module wrap never moves anything.
function bottomBand(shapes) {
  for (var i = 0; i < (shapes || []).length; i++) {
    var shape = shapes[i]
    var zones = shape.wrap && shape.wrap.zones
    if (!zones || zones.indexOf("bottom-center") === -1) continue
    if ((shape.kind === "panel" && shape.edge === "bottom") || (shape.kind === "box" && shape.stretch === "across")) return true
  }
  return false
}

// The zones a zone wrap covers on this screen: narrow screens stack the
// bottom corners together, and middle-end under middle-start when both are
// used, so a shape around one of such a pair wraps both.
function wrappedZones(zones, compact, middleStacked) {
  var out = zones.slice()
  var pairs = []
  if (compact) pairs.push(["bottom-start", "bottom-end"])
  if (middleStacked) pairs.push(["middle-start", "middle-end"])
  for (var i = 0; i < pairs.length; i++) {
    if (out.indexOf(pairs[i][0]) === -1 && out.indexOf(pairs[i][1]) === -1) continue
    for (var j = 0; j < 2; j++) if (out.indexOf(pairs[i][j]) === -1) out.push(pairs[i][j])
  }
  return out
}

// The shown elements a shape wraps, in ELEMENTS order. `shown` maps names
// to { zone } (only the shown ones); `frame` has compact and middleStacked.
function wrappedNames(shape, shown, frame) {
  var wrap = shape.wrap
  if (!wrap) return []
  var zones = wrap.zones ? wrappedZones(wrap.zones, frame.compact, frame.middleStacked) : null
  var out = []
  for (var i = 0; i < ELEMENTS.length; i++) {
    var name = ELEMENTS[i]
    var item = shown[name]
    if (!item) continue
    if (zones ? zones.indexOf(item.zone) !== -1 : wrap.modules.indexOf(name) !== -1) out.push(name)
  }
  return out
}

// Whether `name`'s style has a surface `absorb` takes over.
function absorbable(name, style) {
  return !!ABSORB_STYLES[name] && ABSORB_STYLES[name].indexOf(style) !== -1
}

// The modules whose own surface a shape replaces: { name: true }. From the
// data and what is shown only (never the shapes' geometry), so elements may
// read it. `shown` as in wrappedNames, with each element's style.
function absorbedModules(shapes, shown, frame) {
  var out = {}
  for (var i = 0; i < (shapes || []).length; i++) {
    if (shapes[i].absorb !== true) continue
    var names = wrappedNames(shapes[i], shown, frame)
    for (var j = 0; j < names.length; j++) if (absorbable(names[j], shown[names[j]].style)) out[names[j]] = true
  }
  return out
}

function unionRect(rects) {
  if (rects.length === 0) return null
  var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i]
    left = Math.min(left, r.x); top = Math.min(top, r.y)
    right = Math.max(right, r.x + r.width); bottom = Math.max(bottom, r.y + r.height)
  }
  return { x: left, y: top, width: right - left, height: bottom - top }
}

// A size bound in pixels across a panel's `span`, or null.
function sizeBound(length, span, unit, rounded) {
  if (!length) return null
  if (length.px !== undefined) return Math.round(length.px * unit)
  return rounded ? Math.round(length.screen * span) : length.screen * span
}

// The shapes' geometry, in drawing order (frosted first, then list order):
// [{ index, kind, x, y, width, height, radius, fill, opacity, glass, frost,
//   border: { color, width, sides }, edge, filled, line, style, inset,
//   wraps, modules }]. A shape with nothing to draw is left out. `frame`:
//   { width, height, uiScale, rightToLeft, compact, middleStacked, tint,
//     glass (the look's opacity), elements: { name: { zone, style, drawn,
//     reserved, radius (its surface's, or -1), glass } } } (shown only).
// Pure: node tests it, LockView binds it. Zone wraps fit the reserved
// rectangles, rounded out to whole pixels; module wraps the drawn ones,
// exactly, so a zero-padding box draws the module's own surface.
function shapeRects(shapes, frame) {
  var W = frame.width, H = frame.height, u = frame.uiScale
  var rtl = !!frame.rightToLeft
  var px = function(n) { return Math.round(n * u) }
  var elements = frame.elements || {}
  var out = []
  var list = shapes || []
  var order = []
  for (var f = 0; f < list.length; f++) if (isFrosted(list[f])) order.push(f)
  for (var g = 0; g < list.length; g++) if (!isFrosted(list[g])) order.push(g)
  for (var o = 0; o < order.length; o++) {
    var index = order[o]
    var shape = list[index]
    var kind = shape.kind
    var defaults = SHAPE_DEFAULTS[kind]
    var value = function(key) { return shape[key] !== undefined ? shape[key] : defaults[key] }
    var result = { index: index, kind: kind }
    if (kind === "frame") {
      var frameInset = px(value("inset"))
      var style = value("style")
      if (style === "auto") style = frame.tint === "accent" ? "glow" : "bezel"
      result.x = frameInset; result.y = frameInset
      result.width = W - 2 * frameInset; result.height = H - 2 * frameInset
      result.inset = frameInset
      result.radius = px(value("radius"))
      result.style = style
      result.wraps = []
      out.push(result)
      continue
    }
    var names = wrappedNames(shape, elements, frame)
    var modules = !!(shape.wrap && shape.wrap.modules)
    var R = unionRect(names.map(function(name) { return modules ? elements[name].drawn : elements[name].reserved }))
    var inset = px(value("inset"))
    var rect = null
    var filled = false
    if (kind === "box") {
      if (!R) continue
      var padX = px(value("pad").x), padY = px(value("pad").y)
      var down = modules ? function(n) { return n } : Math.floor
      var up = modules ? function(n) { return n } : Math.ceil
      if (value("stretch") === "across") {
        var top = Math.max(inset, down(R.y - padY))
        var bottom = Math.min(H - inset, up(R.y + R.height + padY))
        rect = { x: inset, y: top, width: W - 2 * inset, height: bottom - top }
      } else {
        rect = { x: down(R.x - padX), y: down(R.y - padY), width: up(R.width + 2 * padX), height: up(R.height + 2 * padY) }
      }
      var radius = value("radius")
      if (radius === "auto") {
        var only = names.length === 1 ? elements[names[0]] : null
        radius = only && only.radius >= 0 ? only.radius + Math.min(padX, padY) : px(defaults.radius)
      } else radius = px(radius)
      result.radius = Math.max(0, Math.min(radius, rect.width / 2, rect.height / 2))
    } else {
      var edge = shape.edge
      var across = edge === "start" || edge === "end"
      var span = across ? W : H
      var onLeft = (edge === "start") !== rtl
      var size = shape.size || {}
      var least = sizeBound(size.min, span, u, true)
      var most = sizeBound(size.max, span, u, true)
      var past = sizeBound(size.fillPast, span, u, false)
      var thick = least || 0
      if (R) {
        var reach = edge === "top" ? R.y + R.height : edge === "bottom" ? H - R.y : onLeft ? R.x + R.width : W - R.x
        thick = Math.ceil(reach - inset + px(value("pad")))
        if (least !== null) thick = Math.max(thick, least)
      }
      if (most !== null) thick = Math.min(thick, most)
      var room = span - 2 * inset
      if (past !== null && thick > past) thick = room
      thick = Math.min(thick, room)
      if (!(thick > 0)) continue
      filled = thick >= room
      if (across) rect = { x: onLeft ? inset : W - inset - thick, y: inset, width: thick, height: H - 2 * inset }
      else rect = { x: inset, y: edge === "top" ? inset : H - inset - thick, width: W - 2 * inset, height: thick }
      result.edge = edge
      result.filled = filled
      result.radius = Math.max(0, Math.min(px(value("radius")), rect.width / 2, rect.height / 2))
    }
    result.x = rect.x; result.y = rect.y; result.width = rect.width; result.height = rect.height
    var fill = shape.fill || {}
    var color = fill.color !== undefined ? fill.color : SHAPE_FILL_DEFAULTS.color
    if (color === "auto") color = frame.tint === "none" || !frame.tint ? "black" : "glass"
    result.fill = color
    result.opacity = fill.opacity !== undefined ? fill.opacity : SHAPE_FILL_DEFAULTS.opacity
    result.frost = fill.frost === true
    // "surface": the module's own glass when it wraps exactly one, else the look's.
    result.glass = names.length === 1 && elements[names[0]].glass !== undefined ? elements[names[0]].glass : frame.glass
    var border = shape.border || {}
    var width = border.width !== undefined ? border.width : SHAPE_BORDER_DEFAULTS.width
    var sides = border.sides !== undefined ? border.sides : SHAPE_BORDER_DEFAULTS.sides
    result.border = { color: border.color !== undefined ? border.color : SHAPE_BORDER_DEFAULTS.color,
      width: width > 0 ? Math.max(1, Math.round(width * u)) : 0, sides: sides }
    // The inner edge of a panel (not drawn when it fills the screen).
    result.line = null
    if (kind === "panel" && sides === "inner" && result.border.width > 0 && !filled) {
      var bw = result.border.width
      result.line = result.edge === "top" ? { x: rect.x, y: rect.y + rect.height - bw, width: rect.width, height: bw }
        : result.edge === "bottom" ? { x: rect.x, y: rect.y, width: rect.width, height: bw }
        : { x: onLeft ? rect.x + rect.width - bw : rect.x, y: rect.y, width: bw, height: rect.height }
    }
    result.wraps = names
    result.modules = modules
    out.push(result)
  }
  return out
}

function containsRect(outer, inner) {
  return inner.x >= outer.x - 1 && inner.y >= outer.y - 1 && inner.x + inner.width <= outer.x + outer.width + 1
    && inner.y + inner.height <= outer.y + outer.height + 1
}

// Advice for an editor, never a fallback (the lock ignores it): for the
// shapes drawn (`geometry`, from shapeRects) over the shown elements'
// drawn `rects`, a list of { code, index, names }:
// - "shape-straddles": a module (the field above all) across a shape's edge;
// - "shape-outside-frame": a module outside a frame;
// - "frost-overlap": two frosted shapes overlapping;
// - "shape-empty": a shape that wraps nothing on this screen.
function shapeAdvice(look, rects, geometry) {
  var shapes = (look && look.background && look.background.shapes) || []
  var out = []
  var drawn = {}
  for (var g = 0; g < geometry.length; g++) drawn[geometry[g].index] = geometry[g]
  for (var i = 0; i < shapes.length; i++) {
    var shape = shapes[i]
    var at = drawn[i]
    if (shape.kind !== "frame" && shape.wrap && (!at || at.wraps.length === 0)) out.push({ code: "shape-empty", index: i, names: [] })
    if (!at) continue
    var outside = [], straddling = []
    for (var n = 0; n < ELEMENTS.length; n++) {
      var name = ELEMENTS[n]
      var r = rects[name]
      if (!r) continue
      var inside = containsRect(at, r)
      if (shape.kind === "frame") { if (!inside) outside.push(name) }
      else if (!inside && intersects(at, r, 1)) straddling.push(name)
    }
    if (outside.length > 0) out.push({ code: "shape-outside-frame", index: i, names: outside })
    if (straddling.length > 0) out.push({ code: "shape-straddles", index: i, names: straddling })
  }
  for (var a = 0; a < geometry.length; a++) {
    for (var b = a + 1; b < geometry.length; b++) {
      if (geometry[a].frost && geometry[b].frost && intersects(geometry[a], geometry[b], 0))
        out.push({ code: "frost-overlap", index: Math.max(geometry[a].index, geometry[b].index), names: [] })
    }
  }
  return out
}

// What an editor may offer for shapes (the catalog's shapeLimits).
function shapeCatalog() {
  return { kinds: SHAPE_KINDS.slice(), keys: copy(SHAPE_KEYS), limits: copy(SHAPE_LIMITS), defaults: copy(SHAPE_DEFAULTS),
    edges: SHAPE_EDGES.slice(), stretches: SHAPE_STRETCHES.slice(), fills: SHAPE_FILLS.slice(),
    borders: SHAPE_BORDERS.slice(), sides: SHAPE_SIDES.slice(), frameStyles: FRAME_STYLES.slice(),
    absorbStyles: copy(ABSORB_STYLES) }
}

// Each template's shapes, by name.
function templates() {
  var out = {}
  for (var i = 0; i < SHAPE_TEMPLATES.length; i++) out[SHAPE_TEMPLATES[i]] = template(SHAPE_TEMPLATES[i])
  return out
}

if (typeof module !== "undefined") {
  var shapeExports = { SHAPE_KINDS: SHAPE_KINDS, SHAPE_EDGES: SHAPE_EDGES, SHAPE_STRETCHES: SHAPE_STRETCHES,
    SHAPE_FILLS: SHAPE_FILLS, SHAPE_BORDERS: SHAPE_BORDERS, SHAPE_SIDES: SHAPE_SIDES, FRAME_STYLES: FRAME_STYLES,
    SHAPE_KEY_ORDER: SHAPE_KEY_ORDER, SHAPE_KEYS: SHAPE_KEYS, SHAPE_LIMITS: SHAPE_LIMITS, SHAPE_DEFAULTS: SHAPE_DEFAULTS,
    SHAPE_FILL_DEFAULTS: SHAPE_FILL_DEFAULTS, SHAPE_BORDER_DEFAULTS: SHAPE_BORDER_DEFAULTS, ABSORB_STYLES: ABSORB_STYLES,
    SHAPE_TEMPLATES: SHAPE_TEMPLATES, template: template, legacyShapes: legacyShapes, shapeError: shapeError,
    backgroundShapesError: backgroundShapesError, canonicalShape: canonicalShape, canonicalShapes: canonicalShapes,
    bottomBand: bottomBand, wrappedZones: wrappedZones, wrappedNames: wrappedNames, absorbable: absorbable,
    absorbedModules: absorbedModules, shapeRects: shapeRects, shapeAdvice: shapeAdvice, shapeCatalog: shapeCatalog,
    templates: templates, isFrosted: isFrosted }
  for (var shapeKey in shapeExports) module.exports[shapeKey] = shapeExports[shapeKey]
}

// The animations' older names.
if (typeof module !== "undefined") {
  module.exports.DRAWN_ALIASES = DRAWN_ALIASES
  module.exports.drawnSource = drawnSource
}
