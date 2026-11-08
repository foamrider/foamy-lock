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
  assert.deepEqual(look.background, {source: 'omarchy', path: '', blur: 0, dim: 0.25, shapes: []})
  assert.deepEqual(look.glass, {opacity: 1, tint: 'none'})
  assert.equal(look.elements.calendar.hidden, true)
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
    {layout: {clock: 'thin'}}, {layout: {forecast: {zone: 'top-start'}}},
    {background: {source: 'video'}}, {background: {blur: 2}}, {background: {dim: 0.95}}, {background: {dim: '0.2'}},
    {background: {path: 'relative.png'}}, {background: {path: '/tmp/../etc/x.png'}}, {background: {path: '/tmp/x.gif'}},
    {background: {source: 'picture'}}, {background: {colour: 'red'}}, {background: []},
    {glass: {opacity: -0.1}}, {glass: {opacity: 1.5}}, {glass: {blur: true}}, {glass: 0.5},
    {background: {decor: 'bars'}}, {background: {decor: true}}, {background: {source: 'lava'}},
    {glass: {tint: 'red'}}, {glass: {tint: 1}}, {layout: {calendar: {style: 'month'}}}
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
    date: ['long', 'caps', 'short', 'serif', 'numeric', 'stacked', 'week'],
    clock: ['thin', 'bold', 'stacked', 'mono', 'outline', 'dots', 'flip', 'analog', 'small', 'poster', 'ring', 'serif'],
    account: ['avatar', 'chip', 'name'],
    password: ['pill', 'underline', 'box', 'dots', 'terminal', 'card'],
    media: ['card', 'line', 'pill', 'art', 'hero', 'minimal', 'disc'],
    status: ['text', 'icons', 'pill', 'system'],
    calendar: ['card', 'plain', 'week', 'mini'],
    weather: ['compact', 'pill', 'detailed', 'line', 'large', 'card']
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

test('every new background key, decoration and tint is accepted', () => {
  for (const source of Layout.BACKGROUND_SOURCES.filter(s => s !== 'picture'))
    assert.ok(Layout.parseLook({background: {source}}).valid, source)
  // An older look's decoration still reads, as its shapes (tests/shapes.test.cjs).
  for (const decor of Layout.DECORATIONS) {
    const result = Layout.parseLook({background: {decor}})
    assert.ok(result.valid, decor)
    assert.deepEqual(result.look.background.shapes, Layout.template(decor), decor)
  }
  for (const tint of Layout.GLASS_TINTS) assert.equal(Layout.parseLook({glass: {tint}}).look.glass.tint, tint)
  // A preset's own glass merges under the user's.
  assert.deepEqual(Layout.parseLook({preset: 'neon', glass: {opacity: 0.5}}).look.glass, {opacity: 0.5, tint: 'accent'})
  assert.deepEqual(Layout.parseLook({preset: 'neon', glass: {tint: 'none'}}).look.glass, {opacity: 1, tint: 'none'})
  for (const source of Layout.DRAWN_SOURCES) assert.ok(Layout.BACKGROUND_SOURCES.includes(source), source)
})

test('every selectable preset is valid, distinct and keeps the field in reach', () => {
  const seen = new Map()
  for (const name of Layout.SELECTABLE_PRESETS) {
    const parsed = Layout.parseLook({preset: name})
    assert.ok(parsed.valid, name + ': ' + parsed.error)
    const {elements, background, glass} = parsed.look
    assert.equal(elements.password.hidden, false, name)
    assert.ok(Layout.PASSWORD_ZONES.includes(elements.password.zone), name)
    assert.equal(Layout.backgroundShapesError(background), '', name)
    assert.ok(Layout.GLASS_TINTS.includes(glass.tint), name)
    assert.equal(background.path, '', name)
    const key = JSON.stringify({elements, background, glass})
    assert.ok(!seen.has(key), name + ' repeats ' + seen.get(key))
    seen.set(key, name)
    assert.match(name, /^[a-z]+$/, 'short lowercase ids')
  }
  assert.equal(new Set(Layout.SELECTABLE_PRESETS).size, Layout.SELECTABLE_PRESETS.length)
  assert.deepEqual(Object.keys(Layout.PRESETS).sort(), [...Layout.SELECTABLE_PRESETS, Layout.FALLBACK_PRESET].sort())
  // The presets from 1.3.0's first four keep their names and shape.
  assert.deepEqual(Layout.SELECTABLE_PRESETS.slice(0, 4), ['foamy', 'corner', 'editorial', 'zen'])
  for (const name of ['foamy', 'corner', 'editorial', 'zen']) assert.equal(Layout.preset(name).elements.calendar.hidden, true)
})

// The placement and finish keys (1.3.0): scale, opacity, offset, glass, screens.
const errorOf = (name, value) => Layout.parseLook({layout: {[name]: value}}).error

test('scale takes 0.05 steps from 0.5 to 2, and 0.85 to 1.5 for the field', () => {
  for (const scale of [0.5, 0.55, 0.85, 1, 1.15, 1.3, 1.45, 1.95, 2])
    assert.equal(errorOf('clock', {scale}), '', `clock ${scale}`)
  for (const scale of [0.85, 1.1, 1.5]) assert.equal(errorOf('password', {scale}), '', `password ${scale}`)
  const message = 'layout.clock.scale must be a number from 0.5 to 2 in steps of 0.05'
  for (const scale of [0.45, 2.05, 1.03, 1.149, 0, -1, NaN, Infinity, '1', null, true, [1]])
    assert.equal(errorOf('clock', {scale}), message, `clock ${scale}`)
  for (const scale of [0.8, 1.55, 0.5, 2, 1.12])
    assert.equal(errorOf('password', {scale}), 'layout.password.scale must be a number from 0.85 to 1.5 in steps of 0.05',
      `password ${scale}`)
  // Floating point: what an editor computes on the step is on the step, and
  // the look keeps the exact step value.
  assert.equal(errorOf('date', {scale: 0.1 * 11.5}), '')
  assert.equal(Layout.parseLook({layout: {date: {scale: 0.1 * 11.5}}}).look.elements.date.scale, 1.15)
  assert.equal(errorOf('date', {scale: 1.15 + 1e-12}), '')
  assert.notEqual(errorOf('date', {scale: 1.15 + 1e-6}), '')
})

test('opacity runs from 0.3 to 1, and from 0.7 for the field', () => {
  for (const opacity of [0.3, 0.55, 1]) assert.equal(errorOf('media', {opacity}), '', `media ${opacity}`)
  for (const opacity of [0.29, 1.01, 0, -0.5, '0.5', NaN, null])
    assert.equal(errorOf('media', {opacity}), 'layout.media.opacity must be a number from 0.3 to 1', `media ${opacity}`)
  for (const opacity of [0.7, 0.85, 1]) assert.equal(errorOf('password', {opacity}), '', `password ${opacity}`)
  for (const opacity of [0.69, 0.3, 1.1])
    assert.equal(errorOf('password', {opacity}), 'layout.password.opacity must be a number from 0.7 to 1', `password ${opacity}`)
})

test('an offset is whole: x and y, each a fraction of the screen from -0.5 to 0.5', () => {
  for (const offset of [{x: 0, y: 0}, {x: -0.5, y: 0.5}, {x: 0.5, y: -0.5}, {x: 0.125, y: -0.03}])
    assert.equal(errorOf('status', {offset}), '', JSON.stringify(offset))
  assert.equal(errorOf('password', {offset: {x: 0.1, y: -0.2}}), '')
  const whole = 'layout.status.offset must be an object with both x and y'
  for (const offset of [{x: 0.1}, {y: 0.1}, {}, [0.1, 0.2], 0.1, null, 'x', {x: undefined, y: 0}])
    assert.equal(errorOf('status', {offset}), whole, JSON.stringify(offset))
  assert.equal(errorOf('status', {offset: {x: 0, y: 0, z: 0}}), 'layout.status.offset has an unknown key: z')
  for (const x of [0.51, -0.51, '0.1', NaN, null, Infinity])
    assert.equal(errorOf('status', {offset: {x, y: 0}}),
      "layout.status.offset.x must be a number from -0.5 to 0.5 (a fraction of the screen's width)", String(x))
  assert.equal(errorOf('status', {offset: {x: 0, y: 0.6}}),
    "layout.status.offset.y must be a number from -0.5 to 0.5 (a fraction of the screen's height)")
})

test('glass is per element, only where a style draws glass, with a floor for the field', () => {
  assert.deepEqual(Object.keys(Layout.GLASS_STYLES).sort(), ['account', 'calendar', 'clock', 'media', 'password', 'status', 'weather'])
  for (const [name, styles] of Object.entries(Layout.GLASS_STYLES))
    for (const style of styles) assert.ok(Layout.STYLES[name].includes(style), `${name} ${style}`)
  for (const name of Object.keys(Layout.GLASS_STYLES)) {
    assert.equal(errorOf(name, {glass: 1}), '', name)
    assert.equal(errorOf(name, {glass: 1.01}), `layout.${name}.glass must be a number from ${name === 'password' ? 0.08 : 0} to 1`)
  }
  for (const glass of [0, 0.5]) assert.equal(errorOf('media', {glass}), '', `media ${glass}`)
  for (const glass of [-0.01, '0.5', null]) assert.equal(errorOf('media', {glass}), 'layout.media.glass must be a number from 0 to 1')
  assert.equal(errorOf('password', {glass: 0.08}), '')
  for (const glass of [0, 0.07]) assert.equal(errorOf('password', {glass}), 'layout.password.glass must be a number from 0.08 to 1')
  assert.equal(errorOf('date', {glass: 0.5}), "layout.date.glass isn't supported: the date has no glass surface")
  // Absent unless set, and kept when set (even at the look's own value).
  assert.equal('glass' in Layout.defaults().elements.media, false)
  assert.equal(Layout.parseLook({layout: {media: {glass: 1}}}).look.elements.media.glass, 1)
  // A style without a surface accepts and ignores it, so switching style keeps the look valid.
  assert.ok(Layout.parseLook({layout: {media: {style: 'line', glass: 0.4}}}).valid)
})

test('screens is "all" or "primary", and only for the elements that show everywhere', () => {
  assert.deepEqual(Layout.SCREENS, ['all', 'primary'])
  for (const name of ['date', 'clock', 'media', 'status', 'calendar', 'weather'])
    for (const screens of Layout.SCREENS) assert.equal(errorOf(name, {screens}), '', `${name} ${screens}`)
  for (const screens of ['Primary', 'secondary', '', true, null])
    assert.equal(errorOf('clock', {screens}), 'layout.clock.screens must be one of all, primary', String(screens))
  assert.equal(errorOf('account', {screens: 'primary'}),
    "layout.account.screens isn't supported: the account always follows the screen that gets the keys")
  assert.equal(errorOf('password', {screens: 'all'}),
    "layout.password.screens isn't supported: the password field always follows the screen that gets the keys")
})

test('absent keys and their defaults are the same look', () => {
  const explicit = {}
  for (const name of Layout.ELEMENTS) {
    explicit[name] = {scale: 1, opacity: 1, offset: {x: 0, y: 0}}
    if (Layout.SCREENS_ELEMENTS.includes(name)) explicit[name].screens = 'all'
  }
  const parsed = Layout.parseLook({layout: explicit})
  assert.ok(parsed.valid, parsed.error)
  assert.equal(JSON.stringify(parsed.look), JSON.stringify(Layout.defaults()), 'plain foamy, key for key')
  const changed = Layout.parseLook({layout: {clock: {scale: 1.5, opacity: 0.6, offset: {y: 0.1, x: -0.2}, screens: 'primary', glass: 0.3}}})
  assert.deepEqual(changed.look.elements.clock,
    {...Layout.PRESETS.foamy.elements.clock, scale: 1.5, opacity: 0.6, offset: {x: -0.2, y: 0.1}, screens: 'primary', glass: 0.3})
  assert.deepEqual(Object.keys(changed.look.elements.clock.offset), ['x', 'y'])
  // The user's entry is never changed by the merge.
  const entry = {layout: {date: {offset: {x: 0, y: 0}, scale: 1}}}
  Layout.parseLook(entry)
  assert.deepEqual(entry, {layout: {date: {offset: {x: 0, y: 0}, scale: 1}}})
})

test('the limits an editor offers match what the parser accepts', () => {
  const limits = Layout.elementLimits()
  assert.deepEqual(Object.keys(limits), Layout.ELEMENTS)
  assert.deepEqual(limits.clock.scale, {min: 0.5, max: 2, step: 0.05})
  assert.deepEqual(limits.password.scale, {min: 0.85, max: 1.5, step: 0.05})
  assert.deepEqual(limits.password.opacity, {min: 0.7, max: 1})
  assert.deepEqual(limits.media.offset, {min: -0.5, max: 0.5})
  assert.deepEqual(limits.password.glass, {min: 0.08, max: 1, styles: ['pill', 'box', 'card']})
  assert.equal(limits.date.glass, null)
  assert.equal(limits.account.screens, null)
  assert.deepEqual(limits.calendar.screens, ['all', 'primary'])
  for (const name of Layout.ELEMENTS) {
    const l = limits[name]
    for (const key of ['scale', 'opacity']) {
      assert.equal(errorOf(name, {[key]: l[key].min}), '', `${name} ${key} min`)
      assert.equal(errorOf(name, {[key]: l[key].max}), '', `${name} ${key} max`)
      assert.notEqual(errorOf(name, {[key]: l[key].min - 0.01}), '', `${name} ${key} below`)
      assert.notEqual(errorOf(name, {[key]: l[key].max + 0.01}), '', `${name} ${key} above`)
    }
    // Editing the limits returned never changes the parser's.
    l.scale.min = 0
  }
  assert.equal(Layout.LIMITS.scale.min, 0.5)
  assert.equal(Layout.PASSWORD_LIMITS.scale.min, 0.85)
})

test('the field keeps below the top third of the screen', () => {
  const field = {x: 800, y: 360, width: 320, height: 51}
  assert.equal(Layout.geometryError(field, [], 1920, 1080, 8), '', 'exactly a third down')
  assert.equal(Layout.geometryError({...field, y: 359}, [], 1920, 1080, 8), 'password-high')
  // Off screen comes first, then too high, then covered.
  assert.equal(Layout.geometryError({...field, y: 2}, [], 1920, 1080, 8), 'password-offscreen')
  assert.equal(Layout.geometryError({...field, y: 300}, [{...field, y: 300}], 1920, 1080, 8), 'password-high')
})

test('the look geometry check: elements on screen, apart between zones and when moved', () => {
  const look = Layout.defaults().elements
  const field = {x: 800, y: 840, width: 320, height: 51}
  const date = {x: 810, y: 97, width: 300, height: 40}
  // The clock pulls up into the date: neighbours in one stack may overlap.
  const clock = {x: 760, y: 117, width: 400, height: 220}
  const status = {x: 1650, y: 24, width: 246, height: 38}
  const rects = {date, clock, password: field, status}
  const check = (elements, r) => Layout.lookGeometryError(elements, r, 1920, 1080, 4)
  assert.equal(check(look, rects), '')
  assert.equal(check(look, {...rects, password: undefined}), 'password-missing')
  assert.equal(check(look, {...rects, password: {...field, y: 200}}), 'password-high')
  assert.equal(check(look, {...rects, status: {...status, x: 1700}}), 'element-offscreen')
  assert.equal(check(look, {...rects, status: {...status, x: -2}}), 'element-offscreen')
  assert.equal(check(look, {...rects, status: {...status, x: 1674}}), '', 'touching the edge, within a pixel')
  // Different zones may not overlap.
  assert.equal(check(look, {...rects, status: {...status, x: 1000, y: 100}}), 'element-overlap')
  // The field against anything, its own stack included.
  assert.equal(check(look, {...rects, account: {x: 900, y: 800, width: 120, height: 60}}), 'password-overlap')
  // An offset element against everything, its own stack included.
  const moved = Layout.parseLook({layout: {clock: {offset: {x: 0, y: 0.01}}}}).look.elements
  assert.equal(Layout.isOffset(moved.clock), true)
  assert.equal(Layout.isOffset(look.clock), false)
  assert.equal(check(moved, rects), 'element-overlap')
  assert.equal(check(moved, {...rects, clock: {...clock, y: 140}}), '')
  // Hidden elements have no rectangle and aren't checked.
  assert.equal(check(look, {password: field}), '')
})

test('a look in canonical form compares by what it shows', () => {
  const look = Layout.defaults()
  look.elements.clock.scale = 1
  look.elements.date.offset = {x: 0, y: 0}
  look.elements.status.screens = 'all'
  assert.equal(JSON.stringify(Layout.canonical(look)), JSON.stringify(Layout.defaults()))
  assert.equal(look.elements.clock.scale, 1, 'the argument is not changed')
  look.elements.clock.scale = 1.2
  assert.notEqual(JSON.stringify(Layout.canonical(look)), JSON.stringify(Layout.defaults()))
})

test('the weather is last, and hidden in every preset', () => {
  assert.equal(Layout.ELEMENTS[Layout.ELEMENTS.length - 1], 'weather')
  assert.deepEqual(Layout.ELEMENTS.slice(0, 7), ['date', 'clock', 'account', 'password', 'media', 'status', 'calendar'])
  for (const name of Object.keys(Layout.PRESETS)) {
    const weather = Layout.preset(name).elements.weather
    assert.equal(weather.hidden, true, name)
    assert.equal(weather.zone, 'top-start', name)
    assert.equal(weather.style, 'compact', name)
  }
  assert.ok(Layout.SCREENS_ELEMENTS.includes('weather'))
  assert.deepEqual(Layout.GLASS_STYLES.weather, ['pill', 'detailed', 'card'])
  const shown = Layout.parseLook({layout: {weather: {hidden: false, style: 'detailed', details: 'full', location: true, glass: 0.5}}})
  assert.ok(shown.valid, shown.error)
  assert.deepEqual(Layout.stack(shown.look.elements, 'top-start'), ['weather'])
})

test('element-only keys are accepted on their own element and only there', () => {
  const valid = [
    ['password', {reveal: 'always'}], ['password', {reveal: 'typing'}],
    ['status', {items: ['network']}], ['status', {items: [...Layout.STATUS_ITEMS]}], ['status', {items: ['keyboard', 'battery']}],
    ['weather', {details: 'temperature'}], ['weather', {details: 'full'}], ['weather', {location: true}], ['weather', {location: false}]
  ]
  for (const [name, value] of valid) assert.equal(errorOf(name, value), '', `${name} ${JSON.stringify(value)}`)
  // Each key belongs to one element: not in the common ELEMENT_KEYS.
  for (const key of ['reveal', 'items', 'details', 'location']) assert.ok(!Layout.ELEMENT_KEYS.includes(key), key)
  for (const [name, key] of [['clock', 'reveal'], ['date', 'items'], ['media', 'details'], ['status', 'location'], ['password', 'items']])
    assert.equal(errorOf(name, {[key]: 'x'}), `layout.${name} has an unknown key: ${key}`)
  assert.deepEqual(Layout.elementKeys('password'), [...Layout.ELEMENT_KEYS, 'reveal'])
  assert.deepEqual(Layout.elementKeys('status'), [...Layout.ELEMENT_KEYS, 'items'])
  assert.deepEqual(Layout.elementKeys('weather'), [...Layout.ELEMENT_KEYS, 'details', 'location'])
  assert.deepEqual(Layout.elementKeys('clock'), Layout.ELEMENT_KEYS)
  const items = 'layout.status.items must be a list of one or more of ' + Layout.STATUS_ITEMS.join(', ')
  for (const value of [[], 'network', null, {network: true}, [...Layout.STATUS_ITEMS, 'network']])
    assert.equal(errorOf('status', {items: value}), items, JSON.stringify(value))
  assert.equal(errorOf('status', {items: ['wifi']}), 'layout.status.items must only name ' + Layout.STATUS_ITEMS.join(', '))
  assert.equal(errorOf('status', {items: ['volume', 'battery', 'volume']}), 'layout.status.items names volume twice')
  for (const reveal of ['Typing', 'never', true, null, ''])
    assert.equal(errorOf('password', {reveal}), 'layout.password.reveal must be one of always, typing', String(reveal))
  for (const details of ['Full', 'all', 1])
    assert.equal(errorOf('weather', {details}), 'layout.weather.details must be one of temperature, full')
  for (const location of ['true', 1, null])
    assert.equal(errorOf('weather', {location}), 'layout.weather.location must be true or false')
  // The reveal option keeps the field: it can't hide it, and every style accepts it.
  for (const style of Layout.STYLES.password)
    assert.ok(Layout.parseLook({layout: {password: {style, reveal: 'typing'}}}).valid, style)
  assert.deepEqual(Layout.REVEAL_STYLES, Layout.STYLES.password)
})

test('password.reveal defaults to each style\'s own drawing and drops out there', () => {
  // The pill and dots have always shown only the hint while idle; the others the field.
  const own = {pill: 'typing', underline: 'always', box: 'always', dots: 'typing', terminal: 'always', card: 'always'}
  for (const [style, value] of Object.entries(own)) {
    assert.equal(Layout.optionDefault('reveal', style), value, style)
    const plain = Layout.parseLook({layout: {password: {style}}}).look
    assert.equal(Layout.revealOf(plain.elements.password), value, style)
    // The style's default is no change; the other value stays.
    const same = Layout.parseLook({layout: {password: {style, reveal: value}}}).look
    assert.equal(JSON.stringify(same), JSON.stringify(plain), style)
    const other = value === 'always' ? 'typing' : 'always'
    const changed = Layout.parseLook({layout: {password: {style, reveal: other}}}).look
    assert.equal(changed.elements.password.reveal, other, style)
    assert.equal(Layout.revealOf(changed.elements.password), other, style)
    assert.equal(JSON.stringify(Layout.canonical(changed)), JSON.stringify(changed), style)
  }
  // Canonical drops it by the element's style, wherever it comes from.
  const look = Layout.defaults()
  look.elements.password.reveal = 'typing'
  assert.equal(JSON.stringify(Layout.canonical(look)), JSON.stringify(Layout.defaults()))
  look.elements.password.style = 'box'
  assert.equal(Layout.canonical(look).elements.password.reveal, 'typing')
  assert.equal(Layout.revealOf(null), 'always')
  assert.ok(Layout.optionFollowsStyle('reveal') && !Layout.optionFollowsStyle('details') && !Layout.optionFollowsStyle('items'))
  // Every built-in preset keeps its field's drawing.
  for (const name of Layout.SELECTABLE_PRESETS) {
    const item = Layout.preset(name).elements.password
    assert.equal(item.reveal, undefined, name)
    assert.equal(Layout.revealOf(item), own[item.style], name)
  }
})

test('element-only defaults leave the look canonical; items stay as named', () => {
  // The pill's own reveal is "typing" (see the test of its defaults).
  const plain = Layout.parseLook({layout: {password: {reveal: 'typing'}, weather: {details: 'temperature', location: false}}})
  assert.equal(JSON.stringify(plain.look), JSON.stringify(Layout.defaults()))
  const named = Layout.parseLook({layout: {status: {items: ['battery', 'network']}}})
  assert.deepEqual(named.look.elements.status.items, ['battery', 'network'], 'the order is kept')
  assert.notEqual(JSON.stringify(named.look), JSON.stringify(Layout.defaults()), 'naming the items is not the default')
  // The user's entry is never shared with the look.
  const entry = {layout: {status: {items: ['volume']}}}
  Layout.parseLook(entry).look.elements.status.items.push('battery')
  assert.deepEqual(entry.layout.status.items, ['volume'])
})

test('an editor is offered each element-only key with its values and defaults', () => {
  const limits = Layout.elementLimits()
  assert.deepEqual(limits.password.options, {reveal: {values: ['always', 'typing'], default: 'always',
    styles: Layout.STYLES.password,
    defaults: {pill: 'typing', underline: 'always', box: 'always', dots: 'typing', terminal: 'always', card: 'always'}}})
  assert.deepEqual(limits.status.options.items.items, Layout.STATUS_ITEMS)
  assert.deepEqual(limits.status.options.items.defaults, Layout.STATUS_DEFAULT_ITEMS)
  assert.deepEqual(Object.keys(limits.status.options.items.defaults), Layout.STYLES.status)
  assert.deepEqual(limits.weather.options, {details: {values: ['temperature', 'full'], default: 'temperature'},
    location: {values: [false, true], default: false}})
  assert.deepEqual(limits.media.options, {artwork: {values: [true, false], default: true}})
  for (const name of ['date', 'clock', 'account', 'calendar']) assert.deepEqual(limits[name].options, {}, name)
  for (const [style, items] of Object.entries(Layout.STATUS_DEFAULT_ITEMS))
    assert.equal(errorOf('status', {style, items}), '', style)
})

test('a video background: its path, motion and pauseOnBattery', () => {
  for (const path of ['/v/loop.mp4', '/v/a.M4V', '/v/b.mov', '/v/c.mkv', '/v/d.webm', '/p/x.JPEG'])
    assert.ok(Layout.parseLook({background: {source: 'picture', path}}).valid, path)
  for (const path of ['/v/a.avi', '/v/a.gif', 'v/a.mp4', '/v/../a.mp4', '/v/a.mp4.txt'])
    assert.match(Layout.parseLook({background: {source: 'picture', path}}).error, /^background\.path must be/, path)
  assert.ok(Layout.isVideoPath('/v/a.WebM'))
  assert.ok(!Layout.isVideoPath('/v/a.png') && !Layout.isVideoPath('/v/a.avi') && !Layout.isVideoPath(''))
  // The defaults are left out, so absent and default compare equal.
  const play = Layout.parseLook({background: {source: 'picture', path: '/v/a.mp4', motion: 'play', pauseOnBattery: false}})
  assert.deepEqual(play.look.background, {source: 'picture', path: '/v/a.mp4', blur: 0, dim: 0.25, shapes: [],
    motion: 'play', pauseOnBattery: false})
  assert.ok(Layout.playsVideo(play.look.background))
  assert.ok(!Layout.pausesOnBattery(play.look.background))
  const still = Layout.parseLook({background: {motion: 'still', pauseOnBattery: true}})
  assert.deepEqual(still.look, Layout.defaults())
  assert.ok(!Layout.playsVideo(still.look.background) && Layout.pausesOnBattery(still.look.background))
  assert.ok(Layout.pausesOnBattery(null) && !Layout.playsVideo(null))
  const canonical = Layout.canonical({background: {source: 'omarchy', motion: 'still', pauseOnBattery: true}, elements: {}})
  assert.deepEqual(canonical.background, {source: 'omarchy'})
  for (const background of [{motion: 'loop'}, {motion: true}, {pauseOnBattery: 'no'}, {pauseOnBattery: 1}, {pauseOnBattery: null}])
    assert.equal(Layout.parseLook({background}).valid, false, JSON.stringify(background))
  assert.deepEqual(Layout.MOTIONS, ['still', 'play'])
  assert.deepEqual(Layout.BACKGROUND_DEFAULTS, {motion: 'still', pauseOnBattery: true, color: 'background'})
  // No built-in preset plays.
  for (const name of Layout.SELECTABLE_PRESETS) assert.ok(!Layout.playsVideo(Layout.preset(name).background), name)
})

test('media.artwork hides the cover in a look, and only there', () => {
  assert.deepEqual(Layout.elementKeys('media'), [...Layout.ELEMENT_KEYS, 'artwork'])
  assert.equal(Layout.elementError('media', {artwork: false}), '')
  assert.equal(Layout.elementError('media', {artwork: 'no'}), 'layout.media.artwork must be true or false')
  assert.equal(Layout.elementError('clock', {artwork: false}), 'layout.clock has an unknown key: artwork')
  // The default is no change; false stays, with every style.
  assert.equal(JSON.stringify(Layout.parseLook({layout: {media: {artwork: true}}}).look), JSON.stringify(Layout.defaults()))
  for (const style of Layout.STYLES.media)
    assert.equal(Layout.parseLook({layout: {media: {style, artwork: false}}}).look.elements.media.artwork, false, style)
  assert.deepEqual(Layout.ARTWORK_STYLES, ['card', 'pill', 'art', 'hero', 'disc'])
  for (const style of Layout.ARTWORK_STYLES) assert.ok(Layout.STYLES.media.includes(style), style)
})

test('a solid colour: theme colours by name or #rrggbb, and the older black and theme', () => {
  for (const color of [...Layout.THEME_COLORS, '#000000', '#1a1b26', '#ABCDEF']) {
    const parsed = Layout.parseLook({background: {source: 'color', color}})
    assert.ok(parsed.valid, color + ': ' + parsed.error)
    assert.equal(Layout.solidColor(parsed.look.background), color.toLowerCase())
  }
  // Strict: six hex digits with "#", or a theme colour's name; nothing else.
  for (const color of ['#abc', '#abcdeg', '1a1b26', '#1a1b2600', ' #1a1b26', 'red', 'foreground', 'url(x)', '', 0, null, ['#000000'], {}])
    assert.equal(Layout.parseLook({background: {source: 'color', color}}).valid, false, JSON.stringify(color))
  // The default colour is the theme's background, left out of the look.
  assert.deepEqual(Layout.parseLook({background: {source: 'color'}}).look.background,
    {source: 'color', path: '', blur: 0, dim: 0.25, shapes: []})
  assert.equal(Layout.parseLook({background: {source: 'color', color: 'background'}}).look.background.color, undefined)
  assert.equal(Layout.parseLook({background: {source: 'color', color: '#ABCDEF'}}).look.background.color, '#abcdef')
  // Older looks: black is #000000, theme the theme's background; both read
  // as "color" (canonical), so they compare equal to the new spelling.
  const black = Layout.parseLook({background: {source: 'black', blur: 0, dim: 0}})
  assert.ok(black.valid)
  assert.deepEqual(black.look.background, Layout.parseLook({background: {source: 'color', color: '#000000', blur: 0, dim: 0}}).look.background)
  assert.equal(Layout.solidColor({source: 'black'}), '#000000')
  assert.equal(Layout.solidColor({source: 'black', color: 'accent'}), '#000000')
  assert.equal(Layout.solidColor({source: 'theme'}), 'background')
  assert.deepEqual(Layout.parseLook({background: {source: 'theme'}}).look.background, Layout.parseLook({background: {source: 'color'}}).look.background)
  for (const source of ['omarchy', 'picture', ...Layout.DRAWN_SOURCES]) assert.equal(Layout.solidColor({source, color: '#ffffff'}), '', source)
  // The presets that were black and theme keep their colours.
  assert.equal(Layout.solidColor(Layout.preset('terminal').background), '#000000')
  assert.equal(Layout.solidColor(Layout.preset('field-only').background), 'background')
  for (const name of Layout.SELECTABLE_PRESETS) {
    const source = Layout.preset(name).background.source
    assert.ok(!['black', 'theme'].includes(source), name + ' says ' + source)
  }
})

test('a colour stays only with a solid colour source', () => {
  const look = Layout.parseLook({background: {source: 'omarchy', color: '#123456'}})
  assert.ok(look.valid)
  assert.equal(look.look.background.color, undefined)
  // The terminal preset's black goes with its source.
  assert.equal(Layout.parseLook({preset: 'terminal', background: {source: 'aurora'}}).look.background.color, undefined)
  assert.equal(Layout.parseLook({preset: 'terminal', background: {source: 'color'}}).look.background.color, '#000000')
})
