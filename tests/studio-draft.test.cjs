// studio/Draft.js: the draft look, undo history and snapping maths.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../Layout.js')

// Draft.js is a QML library (".pragma library", ".import"): run it in a vm
// with Layout.js bound as `Layout`, as the QML import does.
function loadDraft() {
  const file = path.join(__dirname, '../studio/Draft.js')
  const source = fs.readFileSync(file, 'utf8')
    .replace(/^\s*\.pragma\s+library\s*$/m, '')
    .replace(/^\s*\.import\s+"Layout\.js"\s+as\s+Layout\s*$/m, '')
  assert.ok(!/^\s*\.(pragma|import)\b/m.test(source), 'no other QML directives')
  const sandbox = { module: { exports: {} }, Layout, console }
  vm.runInNewContext(source, sandbox, { filename: file })
  return sandbox.module.exports
}
const Draft = loadDraft()
// vm objects come from another realm; compare them as plain data.
const plain = value => JSON.parse(JSON.stringify(value))
const W = 1920, H = 1080, G = H / 48

const rect = (x, y, width, height) => ({ x, y, width, height })
// A drag input with no anchors or guides unless given.
function input(extra) {
  return Object.assign({ name: 'media', width: W, height: H, margin: 4, rightToLeft: false,
    start: rect(100, 900, 300, 80), delta: { x: 0, y: 0 }, axis: '', snapping: true,
    radius: Draft.snapRadius(0.5), anchors: [], others: [] }, extra)
}

test('a look of defaults is just its preset', () => {
  assert.deepEqual(plain(Draft.entry(Layout.defaults())), { preset: 'foamy' })
  for (const name of Layout.SELECTABLE_PRESETS) assert.deepEqual(plain(Draft.entry(Layout.preset(name))), { preset: name })
  assert.deepEqual(plain(Draft.entry(null)), { preset: 'foamy' })
})

test('entries round-trip through the lock and stay sparse', () => {
  const entries = [
    { preset: 'foamy', layout: { media: { zone: 'bottom-end', order: 1 } } },
    { preset: 'corner', layout: { clock: { scale: 1.5, opacity: 0.6, offset: { x: 0.1, y: -0.05 } } } },
    { preset: 'foamy', layout: { calendar: { hidden: false, screens: 'primary' } }, background: { dim: 0.4 } },
    { preset: 'zen', glass: { tint: 'accent' } },
    { preset: 'foamy', layout: { password: { glass: 0.5, style: 'box' } } }
  ]
  for (const e of entries) {
    const parsed = Layout.parseLook(e)
    assert.ok(parsed.valid, parsed.error)
    assert.deepEqual(plain(Draft.entry(parsed.look)), e, JSON.stringify(e))
  }
  // Explicit defaults are no change.
  const look = Layout.parseLook({ layout: { clock: { scale: 1, opacity: 1, offset: { x: 0, y: 0 }, screens: 'all' } } }).look
  assert.deepEqual(plain(Draft.entry(look)), { preset: 'foamy' })
})

test('a value back at a preset default that differs from it is written out', () => {
  // A preset whose element differs from the defaults (hidden calendar shown,
  // then hidden again, is the preset again).
  let draft = Draft.setHidden({ preset: 'foamy' }, 'calendar', false)
  assert.deepEqual(plain(draft), { preset: 'foamy', layout: { calendar: { hidden: false } } })
  draft = Draft.setHidden(draft, 'calendar', true)
  assert.deepEqual(plain(draft), { preset: 'foamy' })
  // A shown calendar preset gets an explicit hidden: true.
  const calendarShown = Layout.SELECTABLE_PRESETS.find(name => !Layout.preset(name).elements.calendar.hidden)
  assert.ok(calendarShown)
  assert.deepEqual(plain(Draft.setHidden({ preset: calendarShown }, 'calendar', true)),
    { preset: calendarShown, layout: { calendar: { hidden: true } } })
})

test('change count, presets and invalid entries', () => {
  assert.equal(Draft.changeCount({ preset: 'foamy' }), 0)
  assert.equal(Draft.changeCount({ preset: 'foamy', layout: { clock: { scale: 1.2, zone: 'top-start' } }, glass: { tint: 'solid' } }), 3)
  assert.deepEqual(plain(Draft.setPreset({ preset: 'foamy', layout: { clock: { scale: 2 } } }, 'zen')), { preset: 'zen' })
  assert.deepEqual(plain(Draft.setPreset({ preset: 'foamy' }, 'field-only')), { preset: 'foamy' }, 'not selectable')
  assert.equal(Draft.parse({ preset: 'nope' }).valid, false)
  assert.equal(plain(Draft.lookOf({ preset: 'nope' })).preset, 'foamy')
})

test('moving to a zone puts the module last in its stack', () => {
  const look = Layout.defaults()
  // bottom-center holds account and password.
  const draft = Draft.setZone({ preset: 'foamy' }, 'media', 'bottom-center')
  const order = Math.max(look.elements.account.order, look.elements.password.order) + 1
  assert.deepEqual(plain(draft), { preset: 'foamy', layout: { media: { zone: 'bottom-center', order } } })
  const moved = Draft.lookOf(draft)
  assert.deepEqual(Layout.stack(moved.elements, 'bottom-center').at(-1), 'media')
  // Staying in the zone keeps the order.
  const again = Draft.place(draft, 'media', 'bottom-center', { x: 0.01, y: 0 })
  assert.equal(again.layout.media.order, order)
  assert.deepEqual(plain(again.layout.media.offset), { x: 0.01, y: 0 })
  // An empty zone starts at 0; hidden members count (showing them later keeps order).
  assert.equal(Draft.lastOrder(look.elements, 'middle-start', 'media'), 0)
  const calendarZone = look.elements.calendar.zone
  assert.equal(Draft.lastOrder(look.elements, calendarZone, 'media'), look.elements.calendar.order + 1)
  // Orders stop at the lock's limit.
  const crowded = Draft.setOrder({ preset: 'foamy' }, 'status', 99)
  assert.equal(Draft.lastOrder(Draft.lookOf(crowded).elements, 'top-end', 'media'), 99)
})

test('the password field keeps out of the top row and can not be hidden', () => {
  for (const zone of ['top-start', 'top-center', 'top-end']) {
    assert.deepEqual(plain(Draft.setZone({ preset: 'foamy' }, 'password', zone)), { preset: 'foamy' }, zone)
  }
  assert.deepEqual(plain(Draft.setHidden({ preset: 'foamy' }, 'password', true)), { preset: 'foamy' })
  assert.deepEqual(plain(Draft.setZone({ preset: 'foamy' }, 'clock', 'nowhere')), { preset: 'foamy' })
  assert.equal(Draft.setZone({ preset: 'foamy' }, 'password', 'middle-center').layout.password.zone, 'middle-center')
})

test('scale, offset and order stay within the limits', () => {
  assert.equal(Draft.setScale({ preset: 'foamy' }, 'clock', 1.234).layout.clock.scale, 1.25)
  assert.equal(Draft.setScale({ preset: 'foamy' }, 'clock', 9).layout.clock.scale, 2)
  assert.equal(Draft.setScale({ preset: 'foamy' }, 'clock', 0.1).layout.clock.scale, 0.5)
  assert.equal(Draft.setScale({ preset: 'foamy' }, 'password', 3).layout.password.scale, 1.5)
  assert.equal(Draft.setScale({ preset: 'foamy' }, 'password', 0.5).layout.password.scale, 0.85)
  let draft = { preset: 'foamy' }
  for (let i = 0; i < 3; i++) draft = Draft.scaleBy(draft, 'clock', 1)
  assert.equal(draft.layout.clock.scale, 1.15)
  draft = Draft.scaleBy(draft, 'clock', -3)
  assert.deepEqual(plain(draft), { preset: 'foamy' })
  assert.equal(Draft.cleanScale('clock', 1.234, true), 1.234, 'free while Shift resizes')
  assert.deepEqual(plain(Draft.setOffset({ preset: 'foamy' }, 'clock', { x: 0.9, y: -0.7 }).layout.clock.offset), { x: 0.5, y: -0.5 })
  assert.deepEqual(plain(Draft.cleanOffset('clock', { x: 1 / 3, y: -0 })), { x: 0.333333, y: 0 })
  assert.equal(Draft.setOrder({ preset: 'foamy' }, 'clock', 500).layout.clock.order, 99)
  for (const step of [0.85, 1.15, 1.35, 1.5]) {
    const e = Draft.setScale({ preset: 'foamy' }, 'password', step)
    assert.ok(Draft.parse(e).valid, `${step}: ${Draft.parse(e).error}`)
  }
})

test('undo and redo walk the history', () => {
  let h = Draft.history({ preset: 'foamy' })
  assert.equal(Draft.canUndo(h), false)
  assert.equal(Draft.canRedo(h), false)
  const a = Draft.setZone(h.present, 'media', 'bottom-end')
  h = Draft.push(h, a)
  assert.equal(Draft.push(h, plain(a)), h, 'an unchanged entry records nothing')
  const b = Draft.setScale(a, 'clock', 1.5)
  h = Draft.push(h, b)
  assert.deepEqual(plain(h.past), [{ preset: 'foamy' }, plain(a)])
  h = Draft.undo(h)
  assert.deepEqual(plain(h.present), plain(a))
  assert.equal(Draft.canRedo(h), true)
  h = Draft.undo(h)
  assert.deepEqual(plain(h.present), { preset: 'foamy' })
  assert.equal(Draft.undo(h), h, 'nothing left to undo')
  h = Draft.redo(h)
  assert.deepEqual(plain(h.present), plain(a))
  // A new edit drops the redo branch.
  h = Draft.push(h, Draft.setPreset(h.present, 'zen'))
  assert.equal(Draft.canRedo(h), false)
  assert.equal(Draft.redo(h), h)
  // The oldest steps go past the limit.
  let long = Draft.history({ preset: 'foamy' })
  for (let i = 1; i <= 120; i++) long = Draft.push(long, Draft.setOrder({ preset: 'foamy' }, 'clock', (i % 99) + 1 === 0 ? 1 : (i % 99) + 1))
  assert.ok(long.past.length <= Draft.HISTORY_LIMIT)
  const short = Draft.push(Draft.push(Draft.history({ preset: 'foamy' }), { preset: 'zen' }, 1), { preset: 'dock' }, 1)
  assert.deepEqual(plain(short.past), [{ preset: 'zen' }])
})

test('the grid is square, 1/48 of the height, and the radius is in canvas pixels', () => {
  assert.equal(Draft.gridStep(1080), 22.5)
  assert.equal(Draft.gridStep(1440), 30)
  assert.equal(Draft.snapRadius(1), 8)
  assert.equal(Draft.snapRadius(0.25), 32, '8 canvas px at a quarter zoom is 32 view px')
  assert.equal(Draft.snapRadius(2), 4)
  assert.equal(Draft.snapRadius(0), 8)
})

test('a free drag snaps to the grid, measured from the nearest anchor', () => {
  const anchor = { zone: 'bottom-start', x: 100, y: 900, width: 300, height: 80 }
  // 2.2 cells right and 1.1 down: snaps to 2 and 1 cells (centre and top).
  const result = Draft.snap(input({ start: rect(100, 900 - 3 * G, 300, 80), anchors: [anchor],
    delta: { x: 2.2 * G, y: 4.1 * G } }))
  assert.equal(result.x.kind, 'grid')
  assert.equal(result.y.kind, 'grid')
  assert.ok(Math.abs(result.rect.x - (100 + 2 * G)) < 1e-9, result.rect.x)
  assert.ok(Math.abs(result.rect.y - (900 + G)) < 1e-9, result.rect.y)
  assert.equal(result.zone, 'bottom-start')
  // Halfway between cells at a radius smaller than half a cell: no snap.
  const loose = Draft.snap(input({ anchors: [anchor], radius: 4, delta: { x: 0.5 * G, y: 0 } }))
  assert.equal(loose.x, null)
  assert.equal(loose.rect.x, 100 + 0.5 * G)
})

test('anchors and guides beat the grid inside the radius', () => {
  const here = { zone: 'bottom-start', x: 100, y: 900, width: 300, height: 80 }
  const there = { zone: 'bottom-end', x: 1500, y: 900, width: 300, height: 80 }
  // 6 px short of the other zone's anchor.
  const result = Draft.snap(input({ anchors: [here, there], delta: { x: 1394, y: 3 }, radius: 8 }))
  assert.equal(result.x.kind, 'anchor')
  assert.equal(result.rect.x, 1500)
  assert.equal(result.y.kind, 'anchor')
  assert.equal(result.rect.y, 900)
  assert.equal(result.zone, 'bottom-end')
  // The screen's centre line catches the module's centre.
  const centre = Draft.snap(input({ anchors: [here], start: rect(100, 500, 300, 80), delta: { x: W / 2 - 250 + 5, y: 0 }, radius: 8 }))
  assert.equal(centre.x.kind, 'guide')
  assert.equal(centre.x.at, W / 2)
  assert.equal(centre.rect.x + 150, W / 2)
  // Another module's edge: its right edge to our left edge.
  const other = rect(600, 200, 200, 50)
  const edge = Draft.snap(input({ anchors: [here], start: rect(100, 500, 300, 80), delta: { x: 703, y: -2 }, others: [other], radius: 8 }))
  assert.equal(edge.x.kind, 'guide')
  assert.equal(edge.rect.x, 800)
})

test('the snap reach follows the zoom: 8 canvas pixels', () => {
  const here = { zone: 'bottom-start', x: 100, y: 900, width: 300, height: 80 }
  const there = { zone: 'bottom-end', x: 1500, y: 900, width: 300, height: 80 }
  // 20 view px away: out of reach at full zoom, within it at a quarter.
  const near = zoom => Draft.snap(input({ anchors: [here, there], delta: { x: 1380, y: 0 }, radius: Draft.snapRadius(zoom) }))
  assert.notEqual(near(1).x && near(1).x.kind, 'anchor')
  assert.equal(near(0.25).x.kind, 'anchor')
  assert.equal(near(0.25).rect.x, 1500)
})

test('Shift turns snapping off; the screen still holds the module', () => {
  const anchor = { zone: 'bottom-start', x: 100, y: 900, width: 300, height: 80 }
  const off = Draft.snap(input({ anchors: [anchor], snapping: false, delta: { x: 33, y: -47 } }))
  assert.deepEqual(plain(off.rect), rect(133, 853, 300, 80))
  assert.equal(off.x, null)
  assert.equal(off.y, null)
  const on = Draft.snap(input({ anchors: [anchor], snapping: true, delta: { x: 33, y: -47 } }))
  assert.notDeepEqual(plain(on.rect), plain(off.rect))
  // Clamped to the screen either way.
  const away = Draft.snap(input({ anchors: [anchor], snapping: false, delta: { x: -500, y: 400 } }))
  assert.deepEqual(plain(away.rect), rect(0, H - 80, 300, 80))
  const right = Draft.snap(input({ anchors: [anchor], snapping: true, delta: { x: 5000, y: -5000 } }))
  assert.deepEqual(plain(right.rect), rect(W - 300, 0, 300, 80))
})

test('Alt locks the drag to the axis it started along', () => {
  assert.equal(Draft.dragAxis(0, 0), '')
  assert.equal(Draft.dragAxis(10, -3), 'x')
  assert.equal(Draft.dragAxis(-2, 9), 'y')
  assert.equal(Draft.dragAxis(5, 5), 'x')
  const anchor = { zone: 'bottom-start', x: 100, y: 900, width: 300, height: 80 }
  const across = Draft.snap(input({ anchors: [anchor], snapping: false, axis: 'x', delta: { x: 40, y: 70 } }))
  assert.deepEqual(plain(across.rect), rect(140, 900, 300, 80))
  const down = Draft.snap(input({ anchors: [anchor], snapping: false, axis: 'y', delta: { x: 40, y: -70 } }))
  assert.deepEqual(plain(down.rect), rect(100, 830, 300, 80))
  // With snapping, only the free axis snaps.
  const snapped = Draft.snap(input({ anchors: [anchor], snapping: true, axis: 'x', delta: { x: 2.1 * G, y: 70 } }))
  assert.equal(snapped.y, null)
  assert.equal(snapped.rect.y, 900)
  assert.equal(snapped.x.kind, 'grid')
})

test('the password field snaps only to its zones and stays below the top third', () => {
  const field = rect(810, 800, 300, 56)
  const anchors = [
    { zone: 'top-center', x: 810, y: 100, width: 300, height: 56 },
    { zone: 'middle-center', x: 810, y: 512, width: 300, height: 56 },
    { zone: 'bottom-center', x: 810, y: 800, width: 300, height: 56 }
  ]
  const up = input({ name: 'password', start: field, anchors, delta: { x: 0, y: -702 } })
  const result = Draft.snap(up)
  assert.ok(result.rect.y >= H / 3, `top ${result.rect.y}`)
  assert.notEqual(result.zone, 'top-center')
  assert.ok(!(result.y && result.y.zone === 'top-center'))
  const placed = Draft.drop(result.rect, up)
  assert.equal(placed.zone, 'middle-center')
  assert.ok(512 + Math.round(placed.offset.y * H) >= H / 3, 'as the lock rounds it')
  // Free placement keeps the limits too, margin included.
  const free = Draft.snap(Object.assign({}, up, { snapping: false, delta: { x: -5000, y: -5000 } }))
  assert.deepEqual(plain(free.rect), rect(4, 360, 300, 56))
  assert.deepEqual(plain(Draft.bounds('password', W, H, 4)), { left: 4, top: 360, right: W - 4, bottom: H - 4 })
  assert.deepEqual(plain(Draft.bounds('clock', W, H, 4)), { left: 0, top: 0, right: W, bottom: H })
  assert.equal(Draft.nearestAnchor(rect(810, 90, 300, 56), anchors, 'password').zone, 'middle-center')
  assert.equal(Draft.nearestAnchor(rect(810, 90, 300, 56), anchors, 'clock').zone, 'top-center')
  assert.equal(Draft.nearestAnchor(rect(0, 0, 1, 1), [], 'clock'), null)
  assert.equal(Draft.drop(rect(0, 0, 1, 1), input({ anchors: [] })), null)
})

test('a drop picks the nearest anchor and keeps the rest as an offset', () => {
  const anchors = [
    { zone: 'bottom-start', x: 32, y: 900, width: 300, height: 80 },
    { zone: 'bottom-end', x: 1588, y: 900, width: 300, height: 80 },
    { zone: 'middle-end', x: 1792, y: 500, width: 300, height: 80 }
  ]
  const at = rect(1500, 880, 300, 80)
  const placed = Draft.drop(at, input({ anchors }))
  assert.equal(placed.zone, 'bottom-end')
  assert.deepEqual(plain(placed.offset), { x: Number((-88 / W).toFixed(6)), y: Number((-20 / H).toFixed(6)) })
  // Right to left, the offset's x mirrors (start/end swap on screen).
  const mirrored = Draft.drop(at, input({ anchors, rightToLeft: true }))
  assert.deepEqual(plain(mirrored.offset), { x: Number((88 / W).toFixed(6)), y: Number((-20 / H).toFixed(6)) })
  // Exactly on an anchor: no offset at all.
  const exact = Draft.drop(rect(32, 900, 300, 80), input({ anchors }))
  assert.deepEqual(plain(exact), { zone: 'bottom-start', offset: { x: 0, y: 0 } })
  // Widths that differ between zones line up by centre.
  const wide = Draft.drop(rect(1588 + 50, 900, 200, 80), input({ anchors }))
  assert.deepEqual(plain(wide.offset), { x: 0, y: 0 })
  // An offset past the limits stops at half the screen.
  const far = Draft.drop(rect(0, 0, 10, 10), input({ anchors: [{ zone: 'bottom-end', x: 1900, y: 1060, width: 10, height: 10 }] }))
  assert.deepEqual(plain(far.offset), { x: -0.5, y: -0.5 })
})

test('drag, drop and place make a look the lock accepts', () => {
  const anchors = [
    { zone: 'bottom-start', x: 32, y: 900, width: 300, height: 80 },
    { zone: 'bottom-end', x: 1588, y: 900, width: 300, height: 80 }
  ]
  const drag = input({ start: rect(32, 900, 300, 80), anchors, delta: { x: 1550, y: -4 } })
  const shown = Draft.snap(drag)
  assert.equal(shown.zone, 'bottom-end')
  const placed = Draft.drop(shown.rect, drag)
  const draft = Draft.place({ preset: 'foamy' }, 'media', placed.zone, placed.offset)
  // An empty zone's first place is order 0, the preset's own order: no order key.
  assert.deepEqual(plain(draft), { preset: 'foamy', layout: { media: { zone: 'bottom-end' } } })
  assert.ok(Draft.parse(draft).valid)
  // An offset drop round-trips its pixels.
  const free = Object.assign({}, drag, { snapping: false, delta: { x: 1533, y: -47 } })
  const dropped = Draft.drop(Draft.snap(free).rect, free)
  const offsetDraft = Draft.place({ preset: 'foamy' }, 'media', dropped.zone, dropped.offset)
  const offset = offsetDraft.layout.media.offset
  assert.equal(Math.round(offset.x * W), 32 + 1533 - 1588)
  assert.equal(Math.round(offset.y * H), -47)
})

test('the view while dragging keeps the zone and moves by an offset', () => {
  const look = Layout.defaults()
  const anchor = { zone: 'bottom-start', x: 32, y: 900, width: 300, height: 80 }
  const dragged = Draft.draggedLook(look, 'media', rect(1032, 800, 300, 80), anchor, input())
  assert.equal(dragged.elements.media.zone, look.elements.media.zone)
  assert.deepEqual(plain(dragged.elements.media.offset), { x: 1000 / W, y: -100 / H })
  assert.equal(look.elements.media.offset, undefined, 'the look itself is untouched')
  const rtl = Draft.draggedLook(look, 'media', rect(1032, 800, 300, 80), anchor, input({ rightToLeft: true }))
  assert.equal(rtl.elements.media.offset.x, -1000 / W)
  const probe = Draft.probeLook(Layout.parseLook({ layout: { media: { offset: { x: 0.1, y: 0 } } } }).look, 'media', 'top-end')
  assert.equal(probe.elements.media.zone, 'top-end')
  assert.equal(probe.elements.media.offset, undefined)
  assert.equal(probe.elements.media.order, look.elements.status.order + 1)
  const stay = Draft.probeLook(look, 'media', 'bottom-start')
  assert.equal(stay.elements.media.order, look.elements.media.order, 'its own zone keeps its place')
  const shown = Draft.probeLook(look, 'calendar', 'middle-end')
  assert.equal(shown.elements.calendar.hidden, false)
  assert.equal(Draft.scaledLook(look, 'clock', 1.234).elements.clock.scale, 1.234)
})

test('Ctrl+arrows find the neighbouring zone on screen', () => {
  assert.equal(Draft.neighbourZone('bottom-start', 'right', false, 'media'), 'bottom-center')
  assert.equal(Draft.neighbourZone('bottom-start', 'left', false, 'media'), 'bottom-start', 'the edge')
  assert.equal(Draft.neighbourZone('bottom-start', 'up', false, 'media'), 'middle-start')
  assert.equal(Draft.neighbourZone('top-end', 'up', false, 'status'), 'top-end')
  assert.equal(Draft.neighbourZone('top-end', 'down', false, 'status'), 'middle-end')
  // Right to left, start is on the right: left moves towards the end.
  assert.equal(Draft.neighbourZone('bottom-start', 'left', true, 'media'), 'bottom-center')
  assert.equal(Draft.neighbourZone('bottom-start', 'right', true, 'media'), 'bottom-start')
  assert.equal(Draft.neighbourZone('middle-center', 'right', true, 'media'), 'middle-start')
  // The field never goes up into the top row.
  assert.equal(Draft.neighbourZone('middle-center', 'up', false, 'password'), 'middle-center')
  assert.equal(Draft.neighbourZone('bottom-center', 'up', false, 'password'), 'middle-center')
  assert.equal(Draft.neighbourZone('nowhere', 'up', false, 'clock'), 'nowhere')
})

test('arrow keys nudge within the screen', () => {
  const anchor = rect(32, 900, 300, 80)
  const geometry = { width: W, height: H, margin: 4, rightToLeft: false }
  const draft = Draft.nudge({ preset: 'foamy' }, 'media', G, 0, rect(32, 900, 300, 80), anchor, geometry)
  assert.equal(Math.round(draft.layout.media.offset.x * W), Math.round(G))
  const one = Draft.nudge({ preset: 'foamy' }, 'media', 0, -1, rect(32, 900, 300, 80), anchor, geometry)
  assert.deepEqual(plain(one.layout.media.offset), { x: 0, y: Number((-1 / H).toFixed(6)) })
  // At the bottom edge a nudge down stops there.
  const edge = Draft.nudge({ preset: 'foamy' }, 'media', 0, 50, rect(32, 990, 300, 80), rect(32, 990, 300, 80), geometry)
  assert.equal(Math.round(edge.layout.media.offset.y * H), -(990 + 80 - H))
  const rtl = Draft.nudge({ preset: 'foamy' }, 'media', -10, 0, rect(500, 900, 300, 80), rect(500, 900, 300, 80),
    Object.assign({}, geometry, { rightToLeft: true }))
  assert.equal(Math.round(rtl.layout.media.offset.x * W), 10, 'left on screen is towards the end')
  // The field stops at the top third.
  const high = Draft.nudge({ preset: 'foamy' }, 'password', 0, -1000, rect(810, 800, 300, 56), rect(810, 800, 300, 56), geometry)
  assert.equal(800 + Math.round(high.layout.password.offset.y * H), 360)
})

test('corner handles scale in 0.05 steps, Shift frees them', () => {
  const r = rect(100, 100, 200, 100)
  assert.equal(Draft.resizeScale('clock', 1, r, { x: 1, y: 1 }, { x: 40, y: 0 }, false), 1.2)
  assert.equal(Draft.resizeScale('clock', 1, r, { x: -1, y: 1 }, { x: 40, y: 0 }, false), 1, 'dragging a left corner right shrinks')
  assert.equal(Draft.resizeScale('clock', 1, r, { x: -1, y: -1 }, { x: -40, y: -2 }, false), 1.2)
  assert.equal(Draft.resizeScale('clock', 1, r, { x: 1, y: 1 }, { x: 0, y: 33 }, false), 1.35)
  assert.ok(Math.abs(Draft.resizeScale('clock', 1, r, { x: 1, y: 1 }, { x: 0, y: 33 }, true) - 1.33) < 1e-9)
  assert.equal(Draft.resizeScale('clock', 1, r, { x: 1, y: 1 }, { x: -1000, y: -1000 }, false), 0.5)
  assert.equal(Draft.resizeScale('password', 1, r, { x: 1, y: 1 }, { x: 1000, y: 0 }, false), 1.5)
})

test('geometry problems name the modules to outline', () => {
  const look = Layout.defaults()
  const rects = { password: rect(810, 800, 300, 56), clock: rect(810, 790, 100, 30), media: rect(32, 900, 300, 80) }
  assert.deepEqual(plain(Draft.problemElements('', look.elements, rects, W, H)), [])
  assert.deepEqual(plain(Draft.problemElements('password-overlap', look.elements, rects, W, H)), ['password', 'clock'])
  assert.deepEqual(plain(Draft.problemElements('password-high', look.elements, rects, W, H)), ['password'])
  const off = { password: rect(810, 800, 300, 56), media: rect(-40, 900, 300, 80) }
  assert.deepEqual(plain(Draft.problemElements('element-offscreen', look.elements, off, W, H)), ['media'])
  // Overlap between zones counts; inside one zone's stack only when offset.
  const elements = Layout.parseLook({ layout: { status: { offset: { x: -0.4, y: 0.07 } } } }).look.elements
  const pair = { password: rect(810, 800, 300, 56), clock: rect(700, 100, 500, 120), status: rect(900, 150, 200, 30) }
  assert.deepEqual(plain(Draft.problemElements('element-overlap', elements, pair, W, H)), ['clock', 'status'])
  const stacked = { password: rect(810, 800, 300, 56), date: rect(700, 100, 500, 40), clock: rect(700, 120, 500, 120) }
  assert.deepEqual(plain(Draft.problemElements('element-overlap', look.elements, stacked, W, H)), [])
  // The real check and this agree on the codes.
  assert.equal(Layout.lookGeometryError(look.elements, rects, W, H, 4), 'password-overlap')
  assert.equal(Layout.lookGeometryError(elements, pair, W, H, 4), 'element-overlap')
})

test('[ and ] walk the modules in library order', () => {
  assert.equal(Draft.neighbourModule('clock', 1), 'date')
  assert.equal(Draft.neighbourModule('clock', -1), 'status')
  assert.equal(Draft.neighbourModule('status', 1), 'clock')
  assert.equal(Draft.neighbourModule('nope', 1), 'clock')
  // The weather joins the library with its availability row (round 2, step
  // R2-4, app side); until then the library leaves it out.
  assert.deepEqual([...Draft.DISPLAY_ORDER].filter(n => n !== 'weather').sort(),
    Layout.ELEMENTS.filter(n => n !== 'weather').sort())
})

test('arrow steps land on the anchor grid and never drift', () => {
  assert.equal(Draft.gridMove(100, 100, 1, G), G)
  assert.equal(Draft.gridMove(100, 100, -1, G), -G)
  // Off the grid: to the next line, not a whole step.
  assert.equal(Draft.gridMove(110, 100, 1, G), G - 10)
  assert.equal(Draft.gridMove(110, 100, -1, G), -10)
  let at = 100
  for (let i = 0; i < 10; i++) at += Draft.gridMove(at, 100, 1, G)
  assert.ok(Math.abs(at - (100 + 10 * G)) < 1e-9, String(at))
})

test('comparisons ignore key order; saving restores the lock\'s order', () => {
  assert.ok(Draft.same({ preset: 'foamy', layout: { media: { zone: 'bottom-end', order: 1 } } },
    { layout: { media: { order: 1, zone: 'bottom-end' } }, preset: 'foamy' }))
  assert.ok(!Draft.same({ preset: 'foamy' }, { preset: 'zen' }))
  assert.ok(!Draft.same([1, 2], [2, 1]), 'arrays keep their order')
  assert.equal(Draft.stable({ b: 1, a: { d: [1, { f: 2, e: 3 }], c: null }, u: undefined }), '{"a":{"c":null,"d":[1,{"e":3,"f":2}]},"b":1}')
  const h = Draft.push(Draft.history({ preset: 'foamy', glass: { tint: 'solid' } }), { glass: { tint: 'solid' }, preset: 'foamy' })
  assert.equal(h.past.length, 0, 'a reordered entry is no change')
  assert.deepEqual(Object.keys(Draft.ordered({ glass: {}, layout: {}, preset: 'zen', background: {} })), ['preset', 'layout', 'background', 'glass'])
  assert.deepEqual(Object.keys(Draft.ordered({ preset: 'zen' })), ['preset'])
})

test('a module dragged in from the library is shown where it lands, in one step', () => {
  const shown = Draft.place({ preset: 'foamy' }, 'calendar', 'top-start', { x: 0.05, y: 0.02 }, true)
  // After the hidden weather, which waits in top-start.
  assert.deepEqual(plain(shown), { preset: 'foamy', layout: { calendar: { zone: 'top-start', order: 1, hidden: false, offset: { x: 0.05, y: 0.02 } } } })
  // Already in that zone: only shown (and moved).
  assert.deepEqual(plain(Draft.place({ preset: 'foamy' }, 'calendar', 'middle-end', null, true)),
    { preset: 'foamy', layout: { calendar: { hidden: false } } })
  assert.ok(Layout.parseLook(shown).valid)
})

test('styles, opacity, glass and screens keep to the lock\'s rules', () => {
  const base = { preset: 'foamy' }
  assert.deepEqual(plain(Draft.setStyle(base, 'clock', 'analog')), { preset: 'foamy', layout: { clock: { style: 'analog' } } })
  assert.deepEqual(plain(Draft.setStyle(base, 'clock', 'thin')), base, 'the preset style is no change')
  assert.equal(Draft.setStyle(base, 'clock', 'pill'), base, 'a style of another module is refused')
  assert.deepEqual(plain(Draft.setOpacity(base, 'media', 0.456)), { preset: 'foamy', layout: { media: { opacity: 0.46 } } })
  assert.deepEqual(plain(Draft.setOpacity(base, 'media', 0.1)), { preset: 'foamy', layout: { media: { opacity: 0.3 } } })
  assert.deepEqual(plain(Draft.setOpacity(base, 'password', 0.4)), { preset: 'foamy', layout: { password: { opacity: 0.7 } } })
  assert.equal(Draft.setOpacity(base, 'media', ''), base)
  assert.equal(Draft.setOpacity(base, 'media', 'x'), base)
  // Glass: hundredths within the limits (the field's floor), null clears it.
  const glass = Draft.setGlass(base, 'password', 0.02)
  assert.deepEqual(plain(glass), { preset: 'foamy', layout: { password: { glass: 0.08 } } })
  assert.deepEqual(plain(Draft.setGlass(glass, 'password', null)), base)
  assert.equal(Draft.setGlass(base, 'date', 0.5), base, 'the date has no glass')
  assert.equal(Draft.setGlass(base, 'media', NaN), base)
  const look = Draft.lookOf(Draft.setGlass(base, 'media', 0.4))
  assert.equal(Draft.glassOf(look, 'media'), 0.4)
  assert.equal(Draft.glassOf(look, 'clock'), 1, 'the look\'s glass otherwise')
  assert.ok(Draft.hasGlass(look, 'media'), 'the media card is glass')
  assert.ok(!Draft.hasGlass(look, 'clock'), 'the thin clock is not')
  assert.ok(!Draft.hasGlass(look, 'date'))
  // Screens: only the modules that take them.
  assert.deepEqual(plain(Draft.setScreens(base, 'media', 'primary')), { preset: 'foamy', layout: { media: { screens: 'primary' } } })
  assert.equal(Draft.setScreens(base, 'account', 'primary'), base)
  assert.equal(Draft.setScreens(base, 'media', 'some'), base)
  // Reset position clears the offset only.
  const moved = { preset: 'foamy', layout: { media: { zone: 'bottom-end', offset: { x: 0.1, y: 0 } } } }
  assert.deepEqual(plain(Draft.resetOffset(moved, 'media')), { preset: 'foamy', layout: { media: { zone: 'bottom-end' } } })
  for (const entry of [glass, moved]) assert.ok(Layout.parseLook(entry).valid)
})

test('offsets as pixels and grid steps', () => {
  assert.deepEqual(plain(Draft.offsetPixels({ x: 0.016667, y: -0.043519 }, W, H)), { x: 32, y: -47 })
  assert.deepEqual(plain(Draft.offsetPixels(undefined, W, H)), { x: 0, y: 0 })
  assert.equal(Draft.pixelsToSteps(45, H), 2)
  assert.equal(Draft.pixelsToSteps(-47, H), -2.1)
  assert.equal(Draft.stepsToPixels(2, H), 45)
  assert.equal(Draft.stepsToPixels(-1, 720), -15)
})

test('background and glass edits stay within the lock\'s ranges', () => {
  const base = { preset: 'foamy' }
  assert.deepEqual(plain(Draft.setBackground(base, 'source', 'aurora')), { preset: 'foamy', background: { source: 'aurora' } })
  assert.equal(Draft.setBackground(base, 'source', 'picture'), base, 'a picture needs a path')
  assert.equal(Draft.setBackground(base, 'source', 'video'), base)
  assert.equal(Draft.setBackground(base, 'path', '/a.png'), base, 'the path comes with the source')
  assert.deepEqual(plain(Draft.setBackground(base, 'blur', 1.7)), { preset: 'foamy', background: { blur: 1 } })
  assert.deepEqual(plain(Draft.setBackground(base, 'dim', 0.95)), { preset: 'foamy', background: { dim: 0.9 } })
  assert.deepEqual(plain(Draft.setBackground(base, 'dim', 0.25)), base, 'the preset value is no change')
  assert.equal(Draft.setBackground(base, 'dim', ''), base)
  assert.deepEqual(plain(Draft.setBackground(base, 'decor', 'frame')), { preset: 'foamy', background: { decor: 'frame' } })
  assert.equal(Draft.setBackground(base, 'decor', 'stars'), base)
  const picture = Draft.setPicture(base, '/home/you/Pictures/lake.jpg')
  assert.deepEqual(plain(picture), { preset: 'foamy', background: { source: 'picture', path: '/home/you/Pictures/lake.jpg' } })
  assert.equal(Draft.setPicture(base, 'lake.jpg'), base, 'a relative path is refused')
  assert.equal(Draft.setPicture(base, '/home/you/../lake.jpg'), base)
  assert.equal(Draft.setPicture(base, '/home/you/lake.gif'), base)
  // Back to the wallpaper keeps the path (the lock ignores it there).
  assert.ok(Layout.parseLook(Draft.setBackground(picture, 'source', 'omarchy')).valid)
  assert.deepEqual(plain(Draft.setGlassLook(base, 'tint', 'accent')), { preset: 'foamy', glass: { tint: 'accent' } })
  assert.equal(Draft.setGlassLook(base, 'tint', 'gold'), base)
  assert.deepEqual(plain(Draft.setGlassLook(base, 'opacity', 0.333)), { preset: 'foamy', glass: { opacity: 0.33 } })
  assert.equal(Draft.setGlassLook(base, 'blur', 1), base)
})

test('a new preset can keep the draft\'s changes', () => {
  const draft = { preset: 'foamy', layout: { clock: { scale: 1.5 }, media: { zone: 'bottom-end' } }, background: { dim: 0.5 } }
  assert.deepEqual(plain(Draft.presetKeeping(draft, 'corner')),
    { preset: 'corner', layout: { clock: { scale: 1.5 }, media: { zone: 'bottom-end' } }, background: { dim: 0.5 } })
  // What equals the new preset is no longer a change.
  assert.deepEqual(plain(Draft.presetKeeping({ preset: 'foamy', layout: { password: { style: 'underline' } } }, 'corner')), { preset: 'corner' })
  assert.deepEqual(plain(Draft.presetKeeping({ preset: 'zen' }, 'foamy')), { preset: 'foamy' })
  assert.equal(Draft.presetKeeping(draft, 'field-only'), null)
  assert.equal(Draft.presetKeeping(draft, 'nope'), null)
  assert.deepEqual(plain(Draft.setPreset(draft, 'corner')), { preset: 'corner' })
})

test('the saved look comes from the lock\'s entry, as the lock reads it', () => {
  assert.deepEqual(plain(Draft.savedEntry(null)), { preset: 'foamy' })
  assert.deepEqual(plain(Draft.savedEntry({ id: 'foamy.lock', timeFormat: '12h' })), { preset: 'foamy' })
  const entry = { id: 'foamy.lock', timeFormat: '12h', preset: 'zen', layout: { clock: { hidden: false, scale: 1.5 } }, glass: { tint: 'accent' } }
  assert.deepEqual(plain(Draft.savedEntry(entry)),
    { preset: 'zen', layout: { clock: { hidden: false, scale: 1.5 } }, glass: { tint: 'accent' } })
  // What equals the preset isn't a change.
  assert.deepEqual(plain(Draft.savedEntry({ preset: 'zen', layout: { clock: { zone: 'top-center' } } })), { preset: 'zen' })
  assert.equal(Draft.savedEntry({ preset: 'nope' }), null, 'a look the lock refuses')
  assert.equal(Draft.savedEntry({ layout: { clock: { scale: 9 } } }), null)
})

test('looks compare as the lock reads them', () => {
  assert.ok(Draft.sameLook({ preset: 'zen' }, { preset: 'zen', layout: { clock: { zone: 'top-center', scale: 1 } } }))
  assert.ok(Draft.sameLook({ glass: { tint: 'accent' }, preset: 'foamy' }, { preset: 'foamy', glass: { tint: 'accent' } }))
  assert.ok(!Draft.sameLook({ preset: 'zen' }, { preset: 'foamy' }))
  assert.ok(!Draft.sameLook({ preset: 'foamy' }, { preset: 'foamy', background: { dim: 0.5 } }))
})

test('a draft goes to disk and comes back as a history', () => {
  let h = Draft.history({ preset: 'foamy' })
  h = Draft.push(h, { preset: 'zen' })
  h = Draft.push(h, { preset: 'zen', background: { dim: 0.5 } })
  h = Draft.undo(h)
  const disk = plain(Draft.diskDraft(h))
  assert.deepEqual(disk, { look: { preset: 'zen' }, history: [{ preset: 'foamy' }] }, 'redo steps stay behind')
  const ordered = Draft.diskDraft(Draft.history({ glass: { tint: 'accent' }, background: { dim: 0.5 }, preset: 'foamy' })).look
  assert.deepEqual(Object.keys(ordered), ['preset', 'background', 'glass'], 'the lock\'s key order')
  const back = Draft.restore({ look: disk.look, history: disk.history, savedAt: '2026-11-08T10:00:00Z' })
  assert.deepEqual(plain(back), { past: [{ preset: 'foamy' }], present: { preset: 'zen' }, future: [] })
  // Steps are read as the lock reads them; refused ones are dropped.
  const odd = Draft.restore({ look: { preset: 'zen', layout: { clock: { zone: 'top-center' } } },
    history: [{ preset: 'nope' }, 'x', { preset: 'corner' }] })
  assert.deepEqual(plain(odd), { past: [{ preset: 'corner' }], present: { preset: 'zen' }, future: [] })
  assert.equal(Draft.restore({ look: { preset: 'nope' }, history: [] }), null)
  assert.equal(Draft.restore(null), null)
  const long = Draft.restore({ look: { preset: 'zen' }, history: Array.from({ length: 130 }, () => ({ preset: 'foamy' })) })
  assert.equal(long.past.length, Draft.HISTORY_LIMIT)
})

test('draft-load replies become reports', () => {
  assert.deepEqual(plain(Draft.loadReport(0, '{"ok":true,"status":"none","draft":null}\n')), { status: 'none' })
  assert.deepEqual(plain(Draft.loadReport(0, '{"ok":true,"status":"corrupt","draft":null,"reason":"not JSON","movedTo":"/x"}')), { status: 'corrupt' })
  const loaded = Draft.loadReport(0, JSON.stringify({ ok: true, status: 'loaded',
    draft: { look: { preset: 'zen' }, history: [{ preset: 'foamy' }], savedAt: '2026-11-08T10:00:00Z' } }))
  assert.equal(loaded.status, 'loaded')
  assert.equal(loaded.savedAt, '2026-11-08T10:00:00Z')
  assert.deepEqual(plain(loaded.history.present), { preset: 'zen' })
  assert.deepEqual(plain(Draft.loadReport(0, JSON.stringify({ ok: true, status: 'loaded', draft: { look: { preset: 'nope' } } }))),
    { status: 'corrupt' }, 'a draft the lock would refuse')
  assert.deepEqual(plain(Draft.loadReport(1, '{"ok":false,"code":"NO_HOME","error":"neither…"}')), { status: 'failed', code: 'NO_HOME' })
  assert.deepEqual(plain(Draft.loadReport(101, 'panic')), { status: 'failed', code: 'FAILED' })
  assert.deepEqual(plain(Draft.loadReport(127, '')), { status: 'failed', code: 'helper-unavailable' })
  assert.equal(Draft.draftError(0, '{"ok":true,"path":"/x","savedAt":"…","history":0,"trimmed":0}'), '')
  assert.equal(Draft.draftError(1, '{"ok":false,"code":"IO","error":"disk full"}'), 'IO')
  assert.equal(Draft.draftError(1, '{"ok":false,"code":"lower case","error":""}'), 'FAILED')
  assert.equal(Draft.draftError(126, ''), 'helper-unavailable')
})

test('apply replies become reports, without the helper\'s words', () => {
  for (const result of Draft.APPLY_RESULTS) {
    const ok = result === 'ok' || result === 'unchanged'
    const report = Draft.applyReport(0, JSON.stringify({ ok, result, message: 'English', confirmed: true, attempts: 1 }))
    assert.equal(report.result, result)
    assert.equal(report.saved, ok)
    assert.equal(report.confirmed, true)
    assert.ok(!JSON.stringify(report).includes('English'))
  }
  const invalid = Draft.applyReport(0, '{"ok":false,"result":"invalid","reason":"layout has an unknown element: x","message":"The lock refused","confirmed":true,"attempts":1}')
  assert.equal(invalid.reason, 'layout has an unknown element: x')
  const unclear = Draft.applyReport(0, '{"ok":false,"result":"not-responding","message":"…","confirmed":false,"attempts":2}')
  assert.deepEqual([unclear.saved, unclear.confirmed], [false, false])
  assert.equal(Draft.applyReport(0, '{"ok":true,"result":"ok","confirmed":true}').saved, true)
  assert.equal(Draft.applyReport(0, '{"ok":false,"result":"ok","confirmed":true}').saved, false, 'ok must agree')
  assert.deepEqual(plain(Draft.applyReport(1, '{"ok":false,"code":"INVALID_REQUEST","error":"…"}')),
    { result: 'error', saved: false, confirmed: true, reason: '', code: 'INVALID_REQUEST' })
  assert.equal(Draft.applyReport(101, '').confirmed, false)
  assert.equal(Draft.applyReport(0, '{"ok":true,"result":"saved"}').result, 'error', 'an unknown result')
  assert.equal(Draft.applyReport(127, '').result, 'helper-unavailable')
})

test('preview answers from omarchy-shell become reports', () => {
  const report = (code, out, err) => plain(Draft.previewReport(code, out, err)).result
  assert.equal(report(0, 'ok\n', ''), 'ok')
  assert.equal(report(0, 'locked', ''), 'locked')
  assert.equal(report(0, 'invalid-json', ''), 'invalid-json')
  assert.deepEqual(plain(Draft.previewReport(0, 'invalid: preset must be one of foamy', '')), { result: 'invalid', reason: 'preset must be one of foamy' })
  assert.equal(report(0, 'what', ''), 'unexpected')
  assert.equal(report(1, '', 'omarchy-shell is not responding\n'), 'not-responding')
  assert.equal(report(1, '', 'omarchy-shell is not ready'), 'not-ready')
  assert.equal(report(1, '', 'omarchy-shell is not running'), 'not-running')
  assert.equal(report(1, '', 'Target not found.'), 'target-not-found')
  assert.equal(report(1, '', 'Function not found.'), 'function-not-found')
  assert.equal(report(124, '', ''), 'not-responding')
  assert.equal(report(127, '', 'bash: no such file'), 'no-omarchy-shell')
  assert.equal(report(2, '', 'boom'), 'failed')
})
