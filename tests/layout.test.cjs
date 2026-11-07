const assert = require('node:assert/strict')
const { test } = require('node:test')
const Layout = require('../Layout.js')

test('every built-in preset is a complete, valid layout', () => {
  for (const name of Object.keys(Layout.PRESETS)) {
    const look = Layout.preset(name)
    assert.equal(look.preset, name)
    assert.equal(Layout.layoutError(look.elements), '', name)
    assert.deepEqual(Object.keys(look.elements).sort(), [...Layout.ELEMENTS].sort(), name)
  }
  assert.ok(!Layout.SELECTABLE_PRESETS.includes(Layout.FALLBACK_PRESET), 'the last resort is not a choice')
  for (const name of Layout.SELECTABLE_PRESETS) assert.ok(Layout.PRESETS[name], name)
})

test('the default look is the 1.2.0 lock screen', () => {
  const look = Layout.defaults()
  assert.equal(look.preset, 'foamy')
  assert.deepEqual(Layout.stack(look.elements, 'top-center'), ['date', 'clock'])
  assert.deepEqual(Layout.stack(look.elements, 'bottom-center'), ['account', 'password'])
  assert.deepEqual(Layout.stack(look.elements, 'bottom-start'), ['media'])
  assert.deepEqual(Layout.stack(look.elements, 'top-end'), ['status'])
  assert.deepEqual(look.background, {source: 'omarchy', path: '', blur: 0, dim: 0.25})
  assert.deepEqual(look.glass, {opacity: 1})
  assert.deepEqual(Layout.parseLook({}), {valid: true, look, error: ''})
  assert.deepEqual(Layout.parseLook(undefined).look, look)
})

test('overrides merge onto the preset and only change what they name', () => {
  const {valid, look} = Layout.parseLook({preset: 'corner', layout: {media: {zone: 'bottom-center'}, status: {hidden: true}},
    background: {dim: 0.5}, glass: {opacity: 0.4}})
  assert.ok(valid)
  assert.equal(look.preset, 'corner')
  assert.deepEqual(look.elements.media, {...Layout.PRESETS.corner.elements.media, zone: 'bottom-center'})
  assert.equal(look.elements.status.hidden, true)
  assert.equal(look.elements.status.style, Layout.PRESETS.corner.elements.status.style)
  assert.deepEqual(look.background, {...Layout.PRESETS.corner.background, dim: 0.5})
  assert.equal(look.glass.opacity, 0.4)
  // The preset data itself is never modified by a merge.
  assert.equal(Layout.PRESETS.corner.elements.media.zone, 'top-start')
  assert.equal(Layout.PRESETS.corner.background.dim, 0.3)
})

test('stacking follows order, then the fixed element order, and skips hidden and absent elements', () => {
  const look = Layout.merge('foamy', {date: {zone: 'middle-start', order: 2}, clock: {zone: 'middle-start', order: 2},
    account: {zone: 'middle-start', order: -1}, media: {zone: 'middle-start', hidden: true}}, null, null)
  assert.deepEqual(Layout.stack(look.elements, 'middle-start'), ['account', 'date', 'clock'])
  assert.deepEqual(Layout.stack(look.elements, 'middle-start', {account: false}), ['date', 'clock'])
  assert.deepEqual(Layout.stack(look.elements, 'top-center'), [])
})

test('the password field can never be hidden or put in the top row', () => {
  for (const layout of [{password: {hidden: true}}, {password: {zone: 'top-center'}}, {password: {zone: 'top-start'}},
    {password: {zone: 'top-end'}}]) {
    const result = Layout.parseLook({layout})
    assert.equal(result.valid, false, JSON.stringify(layout))
    assert.equal(result.look, null)
    assert.match(result.error, /password/)
  }
  for (const zone of Layout.PASSWORD_ZONES) assert.ok(Layout.parseLook({layout: {password: {zone}}}).valid, zone)
})

test('mistakes in the look are reported, never guessed', () => {
  const invalid = [
    {preset: 'field-only'}, {preset: 'Foamy'}, {preset: 1}, {layout: []}, {layout: null},
    {layout: {clock: {zone: 'top-left'}}}, {layout: {clock: {style: 'pill'}}}, {layout: {clock: {size: 2}}},
    {layout: {clock: {order: 1.5}}}, {layout: {clock: {order: 100}}}, {layout: {clock: {hidden: 'yes'}}},
    {layout: {clock: 'thin'}}, {layout: {weather: {zone: 'top-start'}}},
    {background: {source: 'video'}}, {background: {blur: 2}}, {background: {dim: 0.95}}, {background: {dim: '0.2'}},
    {background: {path: 'relative.png'}}, {background: {path: '/tmp/../etc/x.png'}}, {background: {path: '/tmp/x.gif'}},
    {background: {source: 'picture'}}, {background: {colour: 'red'}}, {background: []},
    {glass: {opacity: -0.1}}, {glass: {opacity: 1.5}}, {glass: {blur: true}}, {glass: 0.5}
  ]
  for (const entry of invalid) {
    const result = Layout.parseLook(entry)
    assert.equal(result.valid, false, JSON.stringify(entry))
    assert.ok(result.error, JSON.stringify(entry))
  }
  assert.ok(Layout.parseLook({background: {source: 'picture', path: '/home/me/Pictures/Lake.JPG'}}).valid)
  assert.ok(Layout.parseLook({background: {source: 'black', blur: 0, dim: 0}}).valid)
})

test('start and end mirror in right-to-left languages, center stays', () => {
  assert.equal(Layout.screenColumn('top-start', false), 'start')
  assert.equal(Layout.screenColumn('top-start', true), 'end')
  assert.equal(Layout.screenColumn('bottom-end', true), 'start')
  assert.equal(Layout.screenColumn('middle-center', true), 'center')
  assert.equal(Layout.zoneRow('middle-end'), 'middle')
})

test('the field shows where keys arrive, and everywhere when that is unknown', () => {
  assert.equal(Layout.isPrimary(true, true, true), true, 'the active surface')
  assert.equal(Layout.isPrimary(false, true, true), false, 'another surface has the keys')
  assert.equal(Layout.isPrimary(false, false, true), true, 'no surface active yet: every surface')
  assert.equal(Layout.isPrimary(false, true, false), true, 'no screen yet: treated as primary')
})

test('fallback stages end at the field-only layout', () => {
  assert.equal(Layout.fallbackAfter('corner'), 'foamy')
  assert.equal(Layout.fallbackAfter('foamy'), 'field-only')
  assert.equal(Layout.fallbackAfter('field-only'), '')
})

test('the geometry check finds a missing, offscreen or covered field', () => {
  const field = {x: 800, y: 700, width: 320, height: 51}
  assert.equal(Layout.geometryError(field, [], 1920, 1080, 8), '')
  assert.equal(Layout.geometryError(null, [], 1920, 1080, 8), 'password-missing')
  assert.equal(Layout.geometryError({...field, width: 0}, [], 1920, 1080, 8), 'password-missing')
  assert.equal(Layout.geometryError({...field, x: 1700}, [], 1920, 1080, 8), 'password-offscreen')
  assert.equal(Layout.geometryError({...field, y: 1040}, [], 1920, 1080, 8), 'password-offscreen')
  assert.equal(Layout.geometryError(field, [{x: 1000, y: 720, width: 400, height: 90}], 1920, 1080, 8), 'password-overlap')
  // Touching edges (within a pixel) is not an overlap.
  assert.equal(Layout.geometryError(field, [{x: 1120, y: 700, width: 100, height: 51}], 1920, 1080, 8), '')
  assert.equal(Layout.geometryError(field, [{x: 800, y: 750.5, width: 320, height: 40}], 1920, 1080, 8), '')
})

test('every element offers its shipped styles, defaults first', () => {
  assert.deepEqual(Layout.STYLES, {
    date: ['long', 'caps', 'short', 'serif'],
    clock: ['thin', 'bold', 'stacked', 'mono', 'outline', 'dots', 'flip', 'analog'],
    account: ['avatar', 'chip', 'name'],
    password: ['pill', 'underline', 'box', 'dots', 'terminal', 'card'],
    media: ['card', 'line', 'pill', 'art'],
    status: ['text', 'icons', 'pill']
  })
  // The foamy preset uses each element's first style.
  for (const name of Layout.ELEMENTS) assert.equal(Layout.PRESETS.foamy.elements[name].style, Layout.STYLES[name][0], name)
})

test('every style is accepted on its own element and only there', () => {
  for (const name of Layout.ELEMENTS) {
    for (const style of Layout.STYLES[name]) {
      const result = Layout.parseLook({layout: {[name]: {style}}})
      assert.ok(result.valid, `${name} ${style}: ${result.error}`)
      assert.equal(result.look.elements[name].style, style)
    }
  }
  // Names shared between elements stay per element: "dots" is a clock and a
  // password style, "pill" a password, media and status style, never a date.
  for (const [name, style] of [['date', 'dots'], ['account', 'pill'], ['clock', 'card'], ['status', 'name'],
    ['media', 'terminal'], ['date', 'Serif']]) {
    const result = Layout.parseLook({layout: {[name]: {style}}})
    assert.equal(result.valid, false, `${name} ${style}`)
    assert.match(result.error, new RegExp(`layout\\.${name}\\.style must be one of`))
  }
})
