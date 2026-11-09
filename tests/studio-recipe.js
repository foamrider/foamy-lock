.pragma library
.import "Layout.js" as Layout
.import "Draft.js" as Draft
// The acceptance test's recipes (docs/plans/lock-decorations.md, "Every
// built-in preset can be recreated with the tools"): for a target look, the
// steps that make it from { preset: "foamy" } using only Lock Studio's own
// controls, each step one control (its objectName), what is done to it,
// and the value, on the control's own grid. Node runs a recipe through the
// Draft functions the controls call (tests/studio-recreate.test.cjs); the
// studio harness runs it on the real controls. Development only: the app
// never loads it.
//
// A step: { page, module, shape, control, act, value }
// - page: "module" (the inspector, with `module` selected from the
//   library), "background", "glass" or "shapes" (with `shape` selected);
// - act: "toggle" (a switch), "pick" (tiles, a segmented choice or the
//   zone picker), "click" (a button), "commit" (a slider or a number
//   field) or "choose" (a colour swatch).

// The sliders' grids (their stepSize): a value off its grid can't be set.
var GRIDS = {
  studioSize: 0.05, studioOpacity: 0.05, studioGlass: 0.05, studioBlur: 0.05, studioDim: 0.01,
  studioGlassOpacity: 0.05, studioShapeOpacity: 0.01, studioShapeRadius: 1
}
// The number fields take whole pixels (StepField: one decimal; a percentage
// of the screen to a tenth).
var WHOLE = ["studioShapePadX", "studioShapePadY", "studioShapePad", "studioShapeInset", "studioShapeBorderWidth"]

function copy(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value))
}

function onGrid(value, step) {
  var steps = value / step
  return Math.abs(steps - Math.round(steps)) < 1e-9
}

// --- one step through the Draft functions the controls call ---------------------

function shapeAt(look, index) {
  return Draft.shapesOf(look)[index]
}

// The draft after `step`, as the control's handler makes it (`selected`: the
// module selected, for "Around the selected module").
function apply(draft, step, selected) {
  var look = Draft.lookOf(draft)
  var name = step.module
  var item = name ? look.elements[name] : null
  var v = step.value
  switch (step.control) {
  // The module inspector.
  case "studioShown": return Draft.setHidden(draft, name, !item.hidden)
  case "studioStyles": return Draft.setStyle(draft, name, v)
  case "studioZones": return Draft.setZone(draft, name, v)
  case "studioMoveUp": return Draft.moveInZone(draft, name, -1)
  case "studioMoveDown": return Draft.moveInZone(draft, name, 1)
  case "studioSize": return Draft.setScale(draft, name, v)
  case "studioOpacity": return Draft.setOpacity(draft, name, v)
  case "studioGlass": return Draft.setGlass(draft, name, v)
  case "studioScreens": return Draft.setScreens(draft, name, v)
  case "studioReveal": return Draft.setOption(draft, "password", "reveal", v)
  case "studioDetails": return Draft.setOption(draft, "weather", "details", v)
  case "studioLocation": return Draft.setOption(draft, "weather", "location", Draft.optionOf(look, "weather", "location") !== true)
  case "studioArtwork": return Draft.setOption(draft, "media", "artwork", Draft.optionOf(look, "media", "artwork") !== true)
  // The background page.
  case "studioSource-omarchy":
  case "studioSource-color":
  case "studioSource-animation": return Draft.chooseSource(draft, step.control.slice("studioSource-".length))
  case "studioAnimation": return Draft.setBackground(draft, "source", v)
  case "studioColorHex": return Draft.setColor(draft, v)
  case "studioBlur": return Draft.setBackground(draft, "blur", v)
  // The glass and dim page.
  case "studioDim": return Draft.setBackground(draft, "dim", v)
  case "studioGlassOpacity": return Draft.setGlassLook(draft, "opacity", v)
  case "studioTint": return Draft.setGlassLook(draft, "tint", v)
  // The shapes page.
  case "studioAddShape": return Draft.canAddShape(look, v, selected) ? Draft.addShape(draft, v, selected) : draft
  }
  if (step.control.indexOf("studioSwatch-") === 0) return Draft.setColor(draft, step.control.slice("studioSwatch-".length))
  if (step.control.indexOf("studioShape-") === 0) return draft
  var at = step.shape
  var shape = shapeAt(look, at)
  if (step.control.indexOf("studioShapeUp-") === 0) return Draft.moveShape(draft, at, at - 1)
  if (step.control.indexOf("studioShapeDown-") === 0) return Draft.moveShape(draft, at, at + 1)
  if (step.control.indexOf("studioShapeRemove-") === 0) return Draft.removeShape(draft, at)
  if (step.control.indexOf("studioShapeModule-") === 0) {
    var module = step.control.slice("studioShapeModule-".length)
    return Draft.toggleWrapped(draft, at, module, shape.wrap.modules.indexOf(module) === -1)
  }
  if (step.control.indexOf("studioShapeUnit-") === 0) {
    var bound = step.control.slice("studioShapeUnit-".length)
    if (v === "off") return Draft.setShape(draft, at, "size." + bound, null)
    var start = { min: { screen: 0.3, px: 400 }, max: { screen: 0.5, px: 800 }, fillPast: { screen: 0.6, px: 1200 } }[bound]
    var unit = {}
    unit[v] = start[v]
    return Draft.setShape(draft, at, "size." + bound, unit)
  }
  if (step.control.indexOf("studioShapeSize-") === 0) {
    var which = step.control.slice("studioShapeSize-".length)
    var length = {}
    if (shape.size[which].px !== undefined) length.px = v
    else length.screen = v / 100
    return Draft.setShape(draft, at, "size." + which, length)
  }
  var defaults = Layout.SHAPE_DEFAULTS[shape.kind]
  var own = function(key) { return shape[key] !== undefined ? shape[key] : defaults[key] }
  var border = shape.border || {}
  switch (step.control) {
  case "studioShapeWrap": return Draft.setWrapMode(draft, at, v)
  case "studioShapeZones": return Draft.toggleWrapped(draft, at, v, shape.wrap.zones.indexOf(v) === -1)
  case "studioShapeEdge": return Draft.setShape(draft, at, "edge", v)
  case "studioShapeStyle": return Draft.setShape(draft, at, "style", v)
  case "studioShapePadX": return Draft.setShape(draft, at, "pad.x", v)
  case "studioShapePadY": return Draft.setShape(draft, at, "pad.y", v)
  case "studioShapePad": return Draft.setShape(draft, at, "pad", v)
  case "studioShapeAcross": return Draft.setShape(draft, at, "stretch", own("stretch") === "across" ? null : "across")
  case "studioShapeInset": return Draft.setShape(draft, at, "inset", v)
  case "studioShapeRadiusAuto": return Draft.setShape(draft, at, "radius", own("radius") === "auto" ? null : "auto")
  case "studioShapeRadius": return Draft.setShape(draft, at, "radius", v)
  case "studioShapeFill": return Draft.setShape(draft, at, "fill.color", v)
  case "studioShapeOpacity": return Draft.setShape(draft, at, "fill.opacity", v)
  case "studioShapeFrost": return Draft.setShape(draft, at, "fill.frost", shape.fill && shape.fill.frost === true ? null : true)
  case "studioShapeBorder":
    if (v === "none") return Draft.setShape(draft, at, "border.width", 0)
    var next = Draft.setShape(draft, at, "border.color", v)
    return (border.width !== undefined ? border.width : 1) === 0 ? Draft.setShape(next, at, "border.width", null) : next
  case "studioShapeBorderWidth": return v >= 1 ? Draft.setShape(draft, at, "border.width", v) : draft
  case "studioShapeInner": return Draft.setShape(draft, at, "border.sides", border.sides === "inner" ? null : "inner")
  case "studioShapeAbsorb": return Draft.setShape(draft, at, "absorb", own("absorb") === true ? null : true)
  }
  throw new Error("no such control: " + step.control)
}

// --- the recipe for a look ----------------------------------------------------------

// The look as the test compares it: canonical, without the preset's name;
// a hidden element only by `hidden`; a shown one's order as its place in
// its zone's stack (the order's number only ranks it there).
function comparable(look) {
  var out = Layout.canonical(look)
  delete out.preset
  for (var i = 0; i < Layout.ELEMENTS.length; i++) {
    var name = Layout.ELEMENTS[i]
    var item = out.elements[name]
    if (item.hidden && name !== "password") out.elements[name] = { hidden: true }
    else item.order = Layout.stack(look.elements, item.zone).indexOf(name)
  }
  return out
}

function sameLook(a, b) {
  return Draft.same(comparable(a), comparable(b))
}

// The steps that make `target` (an effective look) from plain foamy, and
// the problems ({ control, value, why }) that kept a value out of reach.
function recipeFor(target) {
  var draft = { preset: Layout.DEFAULT_PRESET }
  var steps = []
  var problems = []
  var selected = "clock"
  function look() { return Draft.lookOf(draft) }
  function run(step) {
    if (step.page === "module") selected = step.module
    var next = apply(draft, step, selected)
    steps.push(step)
    draft = next
  }
  function gridded(control, value) {
    if (GRIDS[control] && !onGrid(value, GRIDS[control])) {
      problems.push({ control: control, value: value, why: "off its grid of " + GRIDS[control] })
      return false
    }
    if (WHOLE.indexOf(control) !== -1 && Math.round(value) !== value) {
      problems.push({ control: control, value: value, why: "not a whole number" })
      return false
    }
    return true
  }
  function module(name, control, act, value) {
    if (value !== undefined && act === "commit" && !gridded(control, value)) return
    run({ page: "module", module: name, control: control, act: act, value: value })
  }
  function scene(page, control, act, value) {
    if (value !== undefined && act === "commit" && !gridded(control, value)) return
    run({ page: page, control: control, act: act, value: value })
  }
  function shapeStep(index, control, act, value) {
    if (value !== undefined && act === "commit" && !gridded(control, value)) return
    run({ page: "shapes", shape: index, control: control, act: act, value: value })
  }

  // The modules: shown or hidden, style, zone, size, opacity, glass,
  // screens and their own keys.
  for (var i = 0; i < Draft.DISPLAY_ORDER.length; i++) {
    var name = Draft.DISPLAY_ORDER[i]
    var want = target.elements[name]
    var have = look().elements[name]
    if (want.hidden && name !== "password") {
      if (!have.hidden) module(name, "studioShown", "toggle")
      continue
    }
    if (have.hidden) module(name, "studioShown", "toggle")
    if (look().elements[name].style !== want.style) module(name, "studioStyles", "pick", want.style)
    if (look().elements[name].zone !== want.zone) module(name, "studioZones", "pick", want.zone)
    var keys = [["scale", "studioSize"], ["opacity", "studioOpacity"], ["glass", "studioGlass"]]
    for (var k = 0; k < keys.length; k++) {
      var key = keys[k][0]
      if (!Draft.same(Draft.elementValue(look().elements[name], key), Draft.elementValue(want, key)) && want[key] !== undefined)
        module(name, keys[k][1], "commit", want[key])
    }
    if (Draft.elementValue(want, "screens") !== Draft.elementValue(look().elements[name], "screens"))
      module(name, "studioScreens", "pick", Draft.elementValue(want, "screens"))
    if (want.offset !== undefined) problems.push({ control: "studioOffsetX", value: want.offset, why: "offsets are not in the recipe" })
    if (want.items !== undefined) problems.push({ control: "studioItems", value: want.items, why: "status items are not in the recipe" })
    var options = { reveal: "studioReveal", details: "studioDetails" }
    for (var option in options) {
      if (want[option] !== undefined && Draft.optionOf(look(), name, option) !== want[option]) module(name, options[option], "pick", want[option])
    }
    if (name === "weather" && want.location !== undefined && Draft.optionOf(look(), "weather", "location") !== want.location)
      module(name, "studioLocation", "toggle")
    if (name === "media" && want.artwork !== undefined && Draft.optionOf(look(), "media", "artwork") !== want.artwork)
      module(name, "studioArtwork", "toggle")
  }
  // The order in each zone: Move up until each module is in its place.
  for (var z = 0; z < Layout.ZONES.length; z++) {
    var zone = Layout.ZONES[z]
    var wanted = Layout.stack(target.elements, zone)
    for (var at = 0; at < wanted.length; at++) {
      var guard = 0
      while (Layout.stack(look().elements, zone).indexOf(wanted[at]) > at && guard++ < 10) module(wanted[at], "studioMoveUp", "click")
    }
  }

  // The background: its source, colour or animation, blur.
  var back = target.background
  var choice = Draft.sourceChoice(back.source)
  if (choice === "picture") problems.push({ control: "studioSource-picture", value: back.path, why: "a picture is the user's own file" })
  else {
    if (Draft.sourceChoice(look().background.source) !== choice) scene("background", "studioSource-" + choice, "click")
    if (choice === "animation" && look().background.source !== back.source) scene("background", "studioAnimation", "pick", back.source)
    var color = Layout.solidColor(back)
    if (choice === "color" && Layout.solidColor(look().background) !== color) {
      if (Layout.THEME_COLORS.indexOf(color) !== -1 || color === Layout.BLACK) scene("background", "studioSwatch-" + color, "choose")
      else scene("background", "studioColorHex", "commit", color)
    }
  }
  if (look().background.blur !== back.blur) {
    if (["omarchy", "picture"].indexOf(back.source) === -1)
      problems.push({ control: "studioBlur", value: back.blur, why: "the blur shows only for a picture" })
    else scene("background", "studioBlur", "commit", back.blur)
  }
  if (back.motion !== undefined || back.pauseOnBattery !== undefined)
    problems.push({ control: "studioMotion", value: back.motion, why: "a video's motion is not in the recipe" })
  // The glass and dim.
  if (look().background.dim !== back.dim) scene("glass", "studioDim", "commit", back.dim)
  if (look().glass.opacity !== target.glass.opacity) scene("glass", "studioGlassOpacity", "commit", target.glass.opacity)
  if (look().glass.tint !== target.glass.tint) scene("glass", "studioTint", "pick", target.glass.tint)

  // The shapes: a template where the next ones are one, else the template
  // of the same kind and then each key that differs.
  while (Draft.shapesOf(look()).length > 0) shapeStep(0, "studioShapeRemove-0", "click")
  var shapes = back.shapes || []
  var s = 0
  while (s < shapes.length) {
    var made = false
    for (var t = 0; t < Layout.SHAPE_TEMPLATES.length && !made; t++) {
      var template = Layout.template(Layout.SHAPE_TEMPLATES[t])
      if (Draft.same(template, shapes.slice(s, s + template.length))) {
        scene("shapes", "studioAddShape", "pick", Layout.SHAPE_TEMPLATES[t])
        s += template.length
        made = true
      }
    }
    if (made) continue
    var base = null
    for (var b = 0; b < Layout.SHAPE_TEMPLATES.length && !base; b++)
      if (Layout.template(Layout.SHAPE_TEMPLATES[b])[0].kind === shapes[s].kind) base = Layout.SHAPE_TEMPLATES[b]
    scene("shapes", "studioAddShape", "pick", base)
    var index = Draft.shapesOf(look()).length - 1
    shapeStep(index, "studioShape-" + index, "click")
    shapeKeys(index, shapes[s], shapeStep, look, problems)
    s++
  }
  return { steps: steps, problems: problems, draft: draft }
}

// The steps that turn shape `index` into `want`, key by key.
function shapeKeys(index, want, shapeStep, look, problems) {
  function have() { return Draft.shapesOf(look())[index] }
  var defaults = Layout.SHAPE_DEFAULTS[want.kind]
  function value(shape, key) { return shape[key] !== undefined ? shape[key] : defaults[key] }
  if (want.edge !== undefined && have().edge !== want.edge) shapeStep(index, "studioShapeEdge", "pick", want.edge)
  if (want.kind === "frame" && value(have(), "style") !== value(want, "style")) shapeStep(index, "studioShapeStyle", "pick", value(want, "style"))
  // What it wraps.
  var mode = !want.wrap ? "none" : want.wrap.modules ? "modules" : "zones"
  if (Draft.wrapMode(have()) !== mode) shapeStep(index, "studioShapeWrap", "pick", mode)
  if (mode !== "none") {
    var list = want.wrap[mode]
    var control = mode === "zones" ? "studioShapeZones" : null
    for (var a = 0; a < list.length; a++) {
      if (have().wrap[mode].indexOf(list[a]) === -1)
        shapeStep(index, control || "studioShapeModule-" + list[a], control ? "pick" : "toggle", control ? list[a] : undefined)
    }
    var current = have().wrap[mode].slice()
    for (var r = 0; r < current.length; r++) {
      if (list.indexOf(current[r]) === -1)
        shapeStep(index, control || "studioShapeModule-" + current[r], control ? "pick" : "toggle", control ? current[r] : undefined)
    }
  }
  if (want.kind === "box") {
    if (value(have(), "stretch") !== value(want, "stretch")) shapeStep(index, "studioShapeAcross", "toggle")
    var pad = value(want, "pad")
    if (value(have(), "pad").x !== pad.x) shapeStep(index, "studioShapePadX", "commit", pad.x)
    if (value(have(), "pad").y !== pad.y) shapeStep(index, "studioShapePadY", "commit", pad.y)
  } else if (want.kind === "panel" && value(have(), "pad") !== value(want, "pad")) shapeStep(index, "studioShapePad", "commit", value(want, "pad"))
  if (value(have(), "inset") !== value(want, "inset") && (want.kind !== "box" || value(want, "stretch") === "across"))
    shapeStep(index, "studioShapeInset", "commit", value(want, "inset"))
  if (want.kind === "panel") {
    var bounds = ["min", "max", "fillPast"]
    for (var n = 0; n < bounds.length; n++) {
      var bound = bounds[n]
      var target = (want.size || {})[bound]
      var now = (have().size || {})[bound]
      var unit = !target ? "off" : target.px !== undefined ? "px" : "screen"
      var nowUnit = !now ? "off" : now.px !== undefined ? "px" : "screen"
      if (unit !== nowUnit) shapeStep(index, "studioShapeUnit-" + bound, "pick", unit)
      if (unit === "off" || Draft.same((have().size || {})[bound], target)) continue
      var shown = unit === "px" ? target.px : Math.round(target.screen * 1000) / 10
      if (unit === "screen" && Math.abs(shown / 100 - target.screen) > 1e-9)
        problems.push({ control: "studioShapeSize-" + bound, value: target.screen, why: "finer than a tenth of a percent" })
      else shapeStep(index, "studioShapeSize-" + bound, "commit", shown)
    }
  }
  var radius = value(want, "radius")
  if (value(have(), "radius") !== radius) {
    if (radius === "auto" || value(have(), "radius") === "auto") shapeStep(index, "studioShapeRadiusAuto", "toggle")
    if (radius !== "auto" && value(have(), "radius") !== radius) shapeStep(index, "studioShapeRadius", "commit", radius)
  }
  if (want.kind === "frame") return
  var fill = function(shape, key) { var f = shape.fill || {}; return f[key] !== undefined ? f[key] : Layout.SHAPE_FILL_DEFAULTS[key] }
  if (fill(have(), "color") !== fill(want, "color")) shapeStep(index, "studioShapeFill", "pick", fill(want, "color"))
  if (fill(have(), "opacity") !== fill(want, "opacity")) shapeStep(index, "studioShapeOpacity", "commit", fill(want, "opacity"))
  if (fill(have(), "frost") !== fill(want, "frost")) shapeStep(index, "studioShapeFrost", "toggle")
  var line = function(shape, key) { var b = shape.border || {}; return b[key] !== undefined ? b[key] : Layout.SHAPE_BORDER_DEFAULTS[key] }
  // The colour and sides first (their controls show while there is a
  // border), then the width, or None.
  if (line(have(), "width") === 0 || line(have(), "color") !== line(want, "color")) shapeStep(index, "studioShapeBorder", "pick", line(want, "color"))
  if (want.kind === "panel" && line(have(), "sides") !== line(want, "sides")) shapeStep(index, "studioShapeInner", "toggle")
  if (line(want, "width") === 0) shapeStep(index, "studioShapeBorder", "pick", "none")
  else if (line(have(), "width") !== line(want, "width")) shapeStep(index, "studioShapeBorderWidth", "commit", line(want, "width"))
  if (value(have(), "absorb") !== value(want, "absorb")) shapeStep(index, "studioShapeAbsorb", "toggle")
}

if (typeof module !== "undefined") module.exports = { GRIDS: GRIDS, WHOLE: WHOLE, apply: apply, comparable: comparable, sameLook: sameLook,
  recipeFor: recipeFor }
