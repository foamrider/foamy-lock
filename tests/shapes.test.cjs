// The look's shapes (Layout.js "shapes"): the format, its canonical form,
// the older `decor` strings, the presets as templates, and the geometry
// (Layout.shapeRects) against a port of the fixed decorations it replaced
// (elements/Decoration.qml before shapes).
const assert = require('node:assert/strict')
const { test } = require('node:test')
const Layout = require('../Layout.js')

const shapes = list => Layout.parseLook({background: {shapes: list}})
const box = extra => Object.assign({kind: 'box', wrap: {modules: ['media']}}, extra)
const panel = extra => Object.assign({kind: 'panel', edge: 'start'}, extra)

test('a shape of each kind is read, and its defaults are left out', () => {
  const look = shapes([
    box({pad: {x: 24, y: 16}, stretch: 'none', radius: 24, fill: {color: 'auto', opacity: 0.6, frost: false},
      border: {color: 'glass', width: 1, sides: 'all'}, absorb: false}),
    panel({pad: 32, inset: 0, radius: 0}),
    {kind: 'frame', inset: 12, radius: 22, style: 'auto'}
  ])
  assert.ok(look.valid, look.error)
  assert.deepEqual(look.look.background.shapes, [box(), panel(), {kind: 'frame'}])
})

test('every key is checked, and the error names its path', () => {
  const cases = [
    [[{}], /^background\.shapes\[0\]\.kind must be one of box, panel, frame$/],
    [['box'], /^background\.shapes\[0\] must be an object$/],
    [[box({colour: 1})], /^background\.shapes\[0\] has an unknown key: colour$/],
    [[box({edge: 'top'})], /^background\.shapes\[0\]\.edge isn't taken by a box$/],
    [[{kind: 'frame', wrap: {zones: ['top-start']}}], /wrap isn't taken by a frame$/],
    [[{kind: 'box'}], /\.wrap is required for a box$/],
    [[{kind: 'panel'}], /\.edge is required for a panel$/],
    [[panel({edge: 'left'})], /\.edge must be one of start, end, top, bottom$/],
    [[box({wrap: {}})], /\.wrap must be/],
    [[box({wrap: {zones: ['top-start'], modules: ['clock']}})], /\.wrap must be/],
    [[box({wrap: {zones: []}})], /\.wrap\.zones must be a list of 1 to 9/],
    [[box({wrap: {zones: ['top-left']}})], /\.wrap\.zones must only name/],
    [[box({wrap: {zones: ['top-start', 'top-start']}})], /names top-start twice$/],
    [[box({wrap: {modules: ['forecast']}})], /\.wrap\.modules must only name/],
    [[box({pad: 12})], /\.pad must be an object with both x and y$/],
    [[box({pad: {x: 1}})], /\.pad must be an object with both x and y$/],
    [[box({pad: {x: 1, y: 1, z: 1}})], /\.pad has an unknown key: z$/],
    [[box({pad: {x: 1.5, y: 1}})], /^background\.shapes\[0\]\.pad\.x must be an integer from 0 to 120$/],
    [[box({pad: {x: 1, y: 121}})], /\.pad\.y must be an integer from 0 to 120$/],
    [[panel({pad: 201})], /\.pad must be an integer from 0 to 200$/],
    [[panel({pad: {x: 1, y: 1}})], /\.pad must be an integer/],
    [[box({stretch: 'wide'})], /\.stretch must be one of none, across$/],
    [[box({inset: 8})], /\.inset needs stretch "across" on a box$/],
    [[box({stretch: 'across', inset: 65})], /\.inset must be an integer from 0 to 64$/],
    [[{kind: 'frame', inset: 25}], /\.inset must be an integer from 0 to 24$/],
    [[panel({size: 0.4})], /\.size must be an object/],
    [[panel({size: {least: {px: 1}}})], /\.size has an unknown key: least$/],
    [[panel({size: {min: 0.4}})], /\.size\.min must be/],
    [[panel({size: {min: {screen: 0.4, px: 4}}})], /\.size\.min must be/],
    [[panel({size: {min: {screen: 0.01}}})], /\.size\.min\.screen must be a number from 0\.05 to 1$/],
    [[panel({size: {max: {px: 4001}}})], /\.size\.max\.px must be an integer from 0 to 4000$/],
    [[panel({size: {min: {px: 500}, max: {px: 400}}})], /\.size\.min must not be more than size\.max$/],
    [[box({radius: 201})], /\.radius must be an integer from 0 to 200, or "auto"$/],
    [[panel({radius: 'auto'})], /\.radius must be an integer from 0 to 200$/],
    [[{kind: 'frame', radius: 65}], /\.radius must be an integer from 0 to 64$/],
    [[box({fill: 'glass'})], /\.fill must be an object/],
    [[box({fill: {color: 'white'}})], /\.fill\.color must be one of auto, glass, surface, black$/],
    [[box({fill: {color: '#ffffff'}})], /\.fill\.color must be one of/],
    [[box({fill: {opacity: 1.2}})], /\.fill\.opacity must be a number from 0 to 1$/],
    [[box({fill: {frost: 'yes'}})], /\.fill\.frost must be true or false$/],
    [[box({fill: {blur: 1}})], /\.fill has an unknown key: blur$/],
    [[box({border: {color: 'red'}})], /\.border\.color must be one of glass, accent$/],
    [[box({border: {width: 5}})], /\.border\.width must be an integer from 0 to 4$/],
    [[box({border: {sides: 'inner'}})], /\.border\.sides "inner" is for a panel$/],
    [[box({border: {dash: 1}})], /\.border has an unknown key: dash$/],
    [[box({absorb: 1})], /\.absorb must be true or false$/],
    [[{kind: 'frame', style: 'neon'}], /\.style must be one of auto, bezel, glow, line$/],
    [[{kind: 'frame', fill: {}}], /\.fill isn't taken by a frame$/],
    [{}, /^background\.shapes must be a list of up to 4 shapes$/],
    [[box(), box(), box(), box(), box()], /^background\.shapes has more than 4 shapes$/],
    [[box({fill: {frost: true}}), box({fill: {frost: true}}), box({fill: {frost: true}})], /more than 2 frosted shapes$/]
  ]
  for (const [list, message] of cases) {
    const result = shapes(list)
    assert.equal(result.valid, false, JSON.stringify(list))
    assert.match(result.error, message, JSON.stringify(list))
  }
  // The second shape's path is its own.
  assert.equal(shapes([box(), box({pad: {x: 1, y: -1}})]).error, 'background.shapes[1].pad.y must be an integer from 0 to 120')
  // Both spellings at once is a mistake; either alone is read.
  assert.equal(Layout.parseLook({background: {decor: 'island', shapes: []}}).error, "background can't have both decor and shapes")
  assert.ok(shapes([box(), box(), box(), box()]).valid)
  assert.ok(shapes([box({fill: {frost: true}}), panel({fill: {frost: true}}), box()]).valid)
  // A mistake leaves the rest of the entry alone (the look's group rules).
  assert.equal(Layout.parseLook({preset: 'island', background: {shapes: [{kind: 'blob'}]}}).look, null)
})

test('the canonical form: key order, defaults out, sorted wraps, list order kept', () => {
  const look = shapes([
    {fill: {opacity: 0.6, color: 'black'}, wrap: {zones: ['bottom-end', 'top-start', 'middle-center']}, kind: 'box',
      border: {width: 1}, radius: 'auto'},
    {kind: 'panel', size: {fillPast: {screen: 0.5}, min: {px: 10}}, edge: 'top', wrap: {modules: ['weather', 'date', 'clock']}},
    {kind: 'box', wrap: {modules: ['media']}, stretch: 'across', inset: 16, pad: {y: 3, x: 2}}
  ]).look.background.shapes
  assert.equal(JSON.stringify(look), JSON.stringify([
    {kind: 'box', wrap: {zones: ['top-start', 'middle-center', 'bottom-end']}, radius: 'auto', fill: {color: 'black'}},
    {kind: 'panel', edge: 'top', wrap: {modules: ['date', 'clock', 'weather']}, size: {min: {px: 10}, fillPast: {screen: 0.5}}},
    {kind: 'box', wrap: {modules: ['media']}, pad: {x: 2, y: 3}, stretch: 'across'}
  ]))
  // An empty list stays: it is how a look takes a preset's shapes away.
  const bare = Layout.parseLook({preset: 'island', background: {shapes: []}})
  assert.deepEqual(bare.look.background.shapes, [])
  assert.notDeepEqual(bare.look, Layout.preset('island'))
  // Canonical twice is canonical.
  for (const name of Layout.SELECTABLE_PRESETS) {
    const preset = Layout.preset(name)
    assert.deepEqual(Layout.canonical(preset), preset, name)
  }
})

test('the presets are templates, and the others have none', () => {
  const decorated = {dock: 'strip', island: 'island', split: 'split', sheet: 'sheet', card: 'card', cinema: 'cinema',
    neon: 'frame', rain: 'card', dotmatrix: 'frame'}
  for (const name of Object.keys(Layout.PRESETS)) {
    const look = Layout.preset(name)
    assert.ok(Array.isArray(look.background.shapes), name)
    assert.equal(look.background.decor, undefined, name)
    assert.equal(Layout.backgroundShapesError(look.background), '', name)
    assert.deepEqual(look.background.shapes, decorated[name] ? Layout.template(decorated[name]) : [], name)
  }
  assert.deepEqual(Layout.preset('foamy').background.shapes, [])
  assert.deepEqual(Layout.preset('field-only').background.shapes, [])
  // Every template is valid and canonical; cinema is two bars.
  for (const name of Layout.SHAPE_TEMPLATES) {
    const list = Layout.template(name)
    assert.equal(Layout.backgroundShapesError({shapes: list}), '', name)
    assert.deepEqual(list.map(Layout.canonicalShape), list, name)
  }
  assert.equal(Layout.template('cinema').length, 2)
  assert.deepEqual(Layout.template('none'), [])
  assert.deepEqual(Object.keys(Layout.templates()), Layout.SHAPE_TEMPLATES)
})

test('an older decor string loads as its shapes, in the look\'s tint', () => {
  for (const decor of Layout.DECORATIONS) {
    for (const tint of Layout.GLASS_TINTS) {
      const look = Layout.parseLook({background: {decor}, glass: {tint}})
      assert.ok(look.valid, decor)
      assert.equal(look.look.background.decor, undefined)
      assert.deepEqual(look.look.background.shapes, Layout.legacyShapes(decor, tint), decor + ' ' + tint)
    }
  }
  // The island took the glass at 0.86 under a tint, black at 0.82 without.
  assert.equal(Layout.parseLook({background: {decor: 'island'}}).look.background.shapes[0].fill.opacity, 0.82)
  assert.equal(Layout.parseLook({background: {decor: 'island'}, glass: {tint: 'accent'}}).look.background.shapes[0].fill.opacity, 0.86)
  // The frame keeps following the tint (its style is "auto").
  assert.deepEqual(Layout.legacyShapes('frame', 'accent'), [{kind: 'frame'}])
  // "none" takes a preset's shapes away; the same look as an empty list.
  assert.deepEqual(Layout.parseLook({preset: 'sheet', background: {decor: 'none'}}).look,
    Layout.parseLook({preset: 'sheet', background: {shapes: []}}).look)
  // A preset's decoration written out again is the preset.
  assert.deepEqual(Layout.parseLook({preset: 'island', background: {decor: 'island'}}).look, Layout.preset('island'))
})

test('the bottom band comes from the data alone', () => {
  assert.equal(Layout.bottomBand(Layout.preset('dock').background.shapes), true)
  assert.equal(Layout.bottomBand(Layout.preset('cinema').background.shapes), true)
  for (const name of ['foamy', 'island', 'split', 'sheet', 'card', 'neon']) assert.equal(Layout.bottomBand(Layout.preset(name).background.shapes), false, name)
  assert.equal(Layout.bottomBand([{kind: 'box', wrap: {zones: ['bottom-center']}}]), false, 'a box not across')
  assert.equal(Layout.bottomBand([{kind: 'box', wrap: {modules: ['password']}, stretch: 'across'}]), false, 'a module wrap never moves anything')
  assert.equal(Layout.bottomBand([{kind: 'panel', edge: 'bottom'}]), false, 'a panel around nothing')
  assert.equal(Layout.bottomBand([{kind: 'panel', edge: 'bottom', wrap: {zones: ['bottom-center']}}]), true)
  assert.equal(Layout.bottomBand([{kind: 'panel', edge: 'top', wrap: {zones: ['bottom-center']}}]), false)
  assert.equal(Layout.bottomBand(undefined), false)
})

// --- geometry ------------------------------------------------------------------

// A deterministic generator, so every run checks the same grid.
function random(seed) {
  let state = seed >>> 0
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0
    return state / 4294967296
  }
}

// A screen with shown elements in some zones: reserved rectangles at the
// zone's side of the screen, with fractional sizes; drawn = reserved
// (nothing offset), or moved by `offset`.
function screen(width, height, rightToLeft, zones, seed, offset) {
  const u = Math.max(0.82, Math.min(1.12, height / 1080))
  const next = random(seed)
  const elements = {}
  let n = 0
  for (const zone of zones) {
    const name = Layout.ELEMENTS[n++]
    const row = Layout.zoneRow(zone), column = Layout.screenColumn(zone, rightToLeft)
    const w = 120 + next() * 300 + 0.37, h = 30 + next() * 90 + 0.5
    const x = column === 'start' ? 64 * u : column === 'center' ? (width - w) / 2 : width - 64 * u - w
    const y = row === 'top' ? 24 * u + next() * 20 : row === 'middle' ? (height - h) / 2 : height - 32 * u - h - next() * 30
    const reserved = {x, y, width: w, height: h}
    const drawn = offset ? {x: x + offset.x, y: y + offset.y, width: w, height: h} : reserved
    elements[name] = {zone, style: Layout.STYLES[name][0], drawn, reserved, radius: 22 * u, glass: undefined}
  }
  return {width, height, uiScale: u, rightToLeft, compact: width < 1100 * u, middleStacked: false, tint: 'none', glass: 1, elements}
}

// The fixed decorations' formulas, ported from elements/Decoration.qml (the
// last revision before shapes), over the same reserved rectangles.
function oldSurfaces(kind, frame) {
  const W = frame.width, H = frame.height, unit = frame.uiScale, rtl = frame.rightToLeft
  const zonesRect = zones => {
    const rects = Object.values(frame.elements).filter(e => zones.includes(e.zone)).map(e => e.reserved)
    if (rects.length === 0) return null
    const left = Math.min(...rects.map(r => r.x)), top = Math.min(...rects.map(r => r.y))
    const right = Math.max(...rects.map(r => r.x + r.width)), bottom = Math.max(...rects.map(r => r.y + r.height))
    return {x: left, y: top, width: right - left, height: bottom - top}
  }
  const topRow = zonesRect(['top-start', 'top-center', 'top-end'])
  const bottomRow = zonesRect(['bottom-start', 'bottom-center', 'bottom-end'])
  switch (kind) {
  case 'split': {
    const held = zonesRect(['top-start', 'middle-start', 'bottom-start'].concat(frame.compact ? ['bottom-end'] : []))
    const extent = !held ? 0 : rtl ? W - held.x : held.x + held.width
    let width = Math.max(Math.round(W * 0.38), Math.round(extent + 56 * unit))
    if (width > W * 0.62) width = W
    return [{x: rtl ? W - width : 0, y: 0, width, height: H}]
  }
  case 'sheet': {
    const margin = Math.round(24 * unit)
    const held = zonesRect(['top-end', 'middle-end'].concat(frame.compact ? ['bottom-start', 'bottom-end'] : ['bottom-end']))
    const extent = !held ? 0 : rtl ? held.x + held.width : W - held.x
    const width = Math.min(W - 2 * margin, Math.max(Math.round(420 * unit), Math.round(extent - margin + 44 * unit)))
    return [{x: rtl ? margin : W - margin - width, y: margin, width, height: H - 2 * margin}]
  }
  case 'cinema': {
    const pad = Math.round(26 * unit)
    const least = Math.round(H * 0.12), most = Math.round(H * 0.4)
    const top = Math.min(most, Math.max(least, topRow ? Math.ceil(topRow.y + topRow.height + pad) : 0))
    const bottom = Math.min(most, Math.max(least, bottomRow ? Math.ceil(H - bottomRow.y + pad) : 0))
    return [{x: 0, y: 0, width: W, height: top}, {x: 0, y: H - bottom, width: W, height: bottom}]
  }
  case 'strip': {
    if (!bottomRow) return []
    const margin = Math.round(16 * unit), pad = Math.round(14 * unit)
    const top = Math.floor(bottomRow.y - pad)
    const bottom = Math.min(H - margin, Math.ceil(bottomRow.y + bottomRow.height + pad))
    return [{x: margin, y: top, width: W - 2 * margin, height: bottom - top}]
  }
  case 'island': case 'card': {
    const held = zonesRect([kind === 'island' ? 'top-center' : 'middle-center'])
    if (!held) return []
    const padX = Math.round((kind === 'island' ? 34 : 36) * unit), padY = Math.round((kind === 'island' ? 12 : 36) * unit)
    return [{x: Math.floor(held.x - padX), y: Math.floor(held.y - padY), width: Math.ceil(held.width + 2 * padX),
      height: Math.ceil(held.height + 2 * padY)}]
  }
  case 'frame': {
    const inset = Math.round(12 * unit)
    return [{x: inset, y: inset, width: W - 2 * inset, height: H - 2 * inset}]
  }
  }
  return []
}

const SIZES = [[1920, 1080], [3440, 1440], [1280, 720], [1080, 1920], [800, 1000]]
const ZONE_SETS = [[], ['top-center'], ['middle-center'], ['top-start', 'middle-start', 'bottom-start'],
  ['top-end', 'middle-end', 'bottom-end'], ['bottom-start', 'bottom-center', 'bottom-end'], ['top-start', 'top-center', 'top-end'],
  ['top-center', 'bottom-start', 'middle-start'], ['bottom-end', 'top-end'], ['bottom-start'], ['bottom-end', 'middle-center']]

test('the templates draw what the fixed decorations drew, over a grid of screens', () => {
  let cases = 0, drift = 0
  for (const [width, height] of SIZES) for (const rightToLeft of [false, true]) for (let z = 0; z < ZONE_SETS.length; z++) {
    const frame = screen(width, height, rightToLeft, ZONE_SETS[z], 7 * z + width + (rightToLeft ? 1 : 0))
    for (const kind of Layout.DECORATIONS.filter(d => d !== 'none')) {
      const old = oldSurfaces(kind, frame)
      const now = Layout.shapeRects(Layout.template(kind), frame)
      const where = `${kind} ${width}x${height}${rightToLeft ? ' rtl' : ''} ${ZONE_SETS[z].join(',') || 'empty'}`
      assert.equal(now.length, old.length, where)
      // Split and sheet round their thickness up now (they rounded to the
      // nearest): a pixel at most. Everything else is exact.
      const slack = kind === 'split' || kind === 'sheet' ? 1 : 0
      for (let i = 0; i < old.length; i++) {
        for (const key of ['x', 'y', 'width', 'height']) {
          const off = Math.abs(now[i][key] - old[i][key])
          assert.ok(off <= slack, `${where} surface ${i} ${key}: ${now[i][key]}, was ${old[i][key]}`)
          if (off) drift++
        }
      }
      cases++
    }
  }
  assert.ok(cases > 700, 'the grid ran: ' + cases)
  assert.ok(drift > 0, 'the grid has fractional extents (the split and sheet drift is real, and bounded)')
})

test('zone shapes keep their place when a module moves; module shapes follow', () => {
  const still = screen(1920, 1080, false, ['top-center'], 3)
  const moved = screen(1920, 1080, false, ['top-center'], 3, {x: 58, y: 22})
  const island = Layout.template('island')
  assert.deepEqual(Layout.shapeRects(island, moved), Layout.shapeRects(island, still))
  const around = [{kind: 'box', wrap: {modules: ['date']}, pad: {x: 10, y: 10}, radius: 'auto', fill: {color: 'surface', opacity: 1}}]
  const a = Layout.shapeRects(around, still)[0], b = Layout.shapeRects(around, moved)[0]
  assert.equal(b.x - a.x, 58)
  assert.equal(b.y - a.y, 22)
  // Exactly the drawn rectangle plus the padding (no rounding: concentric).
  const r = moved.elements.date.drawn
  const close = (got, want) => assert.ok(got.every((v, i) => Math.abs(v - want[i]) < 1e-9), JSON.stringify([got, want]))
  close([b.x, b.y, b.width, b.height], [r.x - 10, r.y - 10, r.width + 20, r.height + 20])
  // "auto": the module's own radius plus the padding.
  assert.equal(b.radius, moved.elements.date.radius + 10)
  // Zero padding is the module's own surface.
  const zero = Layout.shapeRects([{kind: 'box', wrap: {modules: ['date']}, pad: {x: 0, y: 0}, radius: 'auto'}], moved)[0]
  close([zero.x, zero.y, zero.width, zero.height, zero.radius], [r.x, r.y, r.width, r.height, moved.elements.date.radius])
  // Without a surface, "auto" is the default radius.
  moved.elements.date.radius = -1
  assert.equal(Layout.shapeRects(around, moved)[0].radius, 24)
})

test('nothing shown: a box isn\'t drawn, a panel keeps its minimum, a frame always draws', () => {
  const empty = screen(1920, 1080, false, [], 1)
  assert.deepEqual(Layout.shapeRects(Layout.template('island'), empty), [])
  assert.deepEqual(Layout.shapeRects([{kind: 'box', wrap: {modules: ['media']}}], empty), [])
  const bars = Layout.shapeRects(Layout.template('cinema'), empty)
  assert.deepEqual(bars.map(b => b.height), [Math.round(1080 * 0.12), Math.round(1080 * 0.12)])
  assert.deepEqual(Layout.shapeRects([{kind: 'panel', edge: 'top', size: {min: {px: 100}}}], empty).map(s => s.height), [100])
  assert.deepEqual(Layout.shapeRects([{kind: 'panel', edge: 'top'}], empty), [], 'no content and no minimum')
  assert.equal(Layout.shapeRects([{kind: 'frame'}], empty).length, 1)
})

test('companion zones on narrow screens', () => {
  assert.deepEqual(Layout.wrappedZones(['bottom-start'], true, false), ['bottom-start', 'bottom-end'])
  assert.deepEqual(Layout.wrappedZones(['bottom-start'], false, false), ['bottom-start'])
  assert.deepEqual(Layout.wrappedZones(['middle-end', 'top-end'], false, true), ['middle-end', 'top-end', 'middle-start'])
  assert.deepEqual(Layout.wrappedZones(['middle-center'], true, true), ['middle-center'])
  // The preset zone lists come out as the fixed decorations' lists.
  assert.deepEqual(Layout.wrappedZones(Layout.template('split')[0].wrap.zones, true, false).sort(),
    ['top-start', 'middle-start', 'bottom-start', 'bottom-end'].sort())
  assert.deepEqual(Layout.wrappedZones(Layout.template('sheet')[0].wrap.zones, true, false).sort(),
    ['top-end', 'middle-end', 'bottom-start', 'bottom-end'].sort())
  // A side panel around a stacked middle row holds both.
  const frame = screen(800, 1000, false, ['middle-start', 'middle-end'], 5)
  frame.middleStacked = true
  const panelRect = Layout.shapeRects(Layout.template('sheet'), frame)[0]
  assert.deepEqual(panelRect.wraps, ['date', 'clock'])
})

// Zone shapes round out to whole pixels from a centred (half-pixel) start,
// so they mirror within a pixel, as the fixed decorations did; module
// shapes are exact.
test('right to left: logical sides mirror, boxes and frames are symmetric', () => {
  const shapesToTry = [
    ...Layout.SHAPE_TEMPLATES.flatMap(Layout.template),
    {kind: 'panel', edge: 'end', wrap: {modules: ['date']}, pad: 20, border: {color: 'accent', width: 2, sides: 'inner'}},
    {kind: 'box', wrap: {modules: ['date', 'clock']}, pad: {x: 5, y: 9}},
    {kind: 'frame', style: 'line', inset: 0}
  ]
  for (const zones of ZONE_SETS) {
    const ltr = screen(1920, 1080, false, zones, 11, {x: 31, y: 7})
    const rtl = screen(1920, 1080, true, zones, 11, {x: -31, y: 7})
    for (const shape of shapesToTry) {
      const a = Layout.shapeRects([shape], ltr), b = Layout.shapeRects([shape], rtl)
      assert.equal(a.length, b.length, JSON.stringify(shape))
      const slack = shape.wrap && shape.wrap.modules ? 1e-6 : 1
      for (let i = 0; i < a.length; i++) {
        assert.ok(Math.abs(b[i].x - (1920 - a[i].x - a[i].width)) <= slack && b[i].y === a[i].y && Math.abs(b[i].width - a[i].width) <= slack
          && b[i].height === a[i].height, `${JSON.stringify(shape)} ${zones}: ${JSON.stringify(b[i])} for ${JSON.stringify(a[i])}`)
        if (a[i].line) assert.ok(Math.abs(b[i].line.x - (1920 - a[i].line.x - a[i].line.width)) <= slack, 'the inner edge mirrors')
      }
    }
  }
})

test('colours, borders and the drawing order', () => {
  const frame = screen(1920, 1080, false, ['top-center', 'middle-center'], 2)
  const list = [
    {kind: 'box', wrap: {zones: ['top-center']}},
    {kind: 'box', wrap: {zones: ['middle-center']}, fill: {color: 'glass', frost: true}, border: {color: 'accent', width: 3}},
    {kind: 'frame', style: 'auto'},
    {kind: 'panel', edge: 'start', wrap: {zones: ['middle-center']}, fill: {frost: true}, border: {width: 0}}
  ]
  const rects = Layout.shapeRects(list, frame)
  // Frosted first (in list order), then the others in list order.
  assert.deepEqual(rects.map(r => r.index), [1, 3, 0, 2])
  assert.equal(rects[2].fill, 'black', 'auto over the plain glass is dark')
  assert.equal(rects[0].fill, 'glass')
  assert.deepEqual(rects[0].border, {color: 'accent', width: 3, sides: 'all'})
  assert.equal(rects[1].border.width, 0)
  assert.equal(rects[3].style, 'bezel')
  frame.tint = 'accent'
  const tinted = Layout.shapeRects(list, frame)
  assert.equal(tinted[2].fill, 'glass', 'auto under a tint is the glass')
  assert.equal(tinted[3].style, 'glow')
  frame.tint = 'solid'
  assert.equal(Layout.shapeRects(list, frame)[3].style, 'bezel')
  // Borders scale like the lock's lines: never under a pixel.
  frame.uiScale = 0.82
  assert.equal(Layout.shapeRects([{kind: 'box', wrap: {zones: ['top-center']}}], frame)[0].border.width, 1)
  assert.equal(Layout.shapeRects(Layout.template('split'), frame)[0].border.width, 2)
  // "surface" takes the module's own glass when it wraps one, else the look's.
  frame.elements.date.glass = 0.3
  frame.glass = 0.8
  assert.equal(Layout.shapeRects([{kind: 'box', wrap: {modules: ['date']}, fill: {color: 'surface'}}], frame)[0].glass, 0.3)
  assert.equal(Layout.shapeRects([{kind: 'box', wrap: {modules: ['date', 'clock']}, fill: {color: 'surface'}}], frame)[0].glass, 0.8)
  // A panel's inner edge isn't drawn once it fills the screen.
  const narrow = screen(800, 1000, false, ['middle-start'], 4)
  narrow.elements.date.reserved.width = 500
  const split = Layout.shapeRects(Layout.template('split'), narrow)[0]
  assert.ok(split.filled && split.line === null && split.width === 800)
})

test('absorb: the wrapped modules\' own surfaces, never the field\'s', () => {
  const shown = {media: {zone: 'bottom-start', style: 'card'}, password: {zone: 'bottom-center', style: 'pill'},
    status: {zone: 'top-end', style: 'text'}, account: {zone: 'bottom-center', style: 'chip'}}
  const frame = {compact: false, middleStacked: false}
  assert.deepEqual(Layout.absorbedModules([{kind: 'box', wrap: {modules: ['media', 'password', 'status']}, absorb: true}], shown, frame),
    {media: true})
  assert.deepEqual(Layout.absorbedModules([{kind: 'box', wrap: {zones: ['bottom-center']}, absorb: true}], shown, frame), {account: true})
  assert.deepEqual(Layout.absorbedModules([{kind: 'box', wrap: {modules: ['media']}}], shown, frame), {})
  for (const name of Object.keys(Layout.ABSORB_STYLES)) {
    assert.ok(Layout.ABSORB_STYLES[name].every(style => Layout.GLASS_STYLES[name].includes(style)), name)
  }
  assert.equal(Layout.ABSORB_STYLES.password, undefined)
  assert.equal(Layout.ABSORB_STYLES.clock, undefined, 'the analog and ring faces are the clock')
})

test('advice for an editor: straddling, outside the frame, frost on frost, nothing wrapped', () => {
  const frame = screen(1920, 1080, false, ['top-center', 'middle-center'], 9)
  const rects = {date: frame.elements.date.drawn, clock: frame.elements.clock.drawn}
  const advice = (list, rs) => Layout.shapeAdvice({background: {shapes: list}}, rs || rects, Layout.shapeRects(list, frame))
  assert.deepEqual(advice(Layout.template('island')), [])
  // A bar whose edge crosses the clock.
  const across = Math.round(rects.clock.y + rects.clock.height / 2)
  assert.deepEqual(advice([{kind: 'panel', edge: 'top', size: {min: {px: across}}}], {clock: rects.clock}),
    [{code: 'shape-straddles', index: 0, names: ['clock']}])
  assert.deepEqual(advice([{kind: 'frame', inset: 24}], {clock: {x: 2, y: 400, width: 50, height: 20}}),
    [{code: 'shape-outside-frame', index: 0, names: ['clock']}])
  assert.deepEqual(advice([{kind: 'box', wrap: {modules: ['weather']}}]), [{code: 'shape-empty', index: 0, names: []}])
  const two = [{kind: 'box', wrap: {zones: ['middle-center']}, fill: {frost: true}}, {kind: 'box', wrap: {zones: ['middle-center']}, pad: {x: 1, y: 1}, fill: {frost: true}}]
  assert.ok(advice(two).some(a => a.code === 'frost-overlap'))
})

test('the catalog describes shapes for an editor', () => {
  const catalog = Layout.shapeCatalog()
  assert.deepEqual(catalog.kinds, ['box', 'panel', 'frame'])
  assert.equal(catalog.limits.count, 4)
  assert.equal(catalog.limits.frosted, 2)
  assert.deepEqual(catalog.defaults.box.pad, {x: 24, y: 16})
  assert.ok(catalog.keys.frame.includes('style'))
  assert.ok(Layout.BACKGROUND_KEYS.includes('shapes'))
})
