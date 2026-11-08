// studio/Draft.js: Lock Studio's shape edits and the order within a zone.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../Layout.js')

// Draft.js runs in a vm with Layout.js bound as `Layout`, as the QML import does.
function loadDraft() {
  const file = path.join(__dirname, '../studio/Draft.js')
  const source = fs.readFileSync(file, 'utf8')
    .replace(/^\s*\.pragma\s+library\s*$/m, '')
    .replace(/^\s*\.import\s+"Layout\.js"\s+as\s+Layout\s*$/m, '')
  const sandbox = { module: { exports: {} }, Layout, console }
  vm.runInNewContext(source, sandbox, { filename: file })
  return sandbox.module.exports
}
const Draft = loadDraft()
const plain = value => JSON.parse(JSON.stringify(value))
const shapesOf = draft => plain(Draft.lookOf(draft).background.shapes)

test('add a template, a box around a module, up to the limits', () => {
  const base = { preset: 'foamy' }
  const island = Draft.addShape(base, 'island')
  assert.deepEqual(plain(island), { preset: 'foamy', background: { shapes: Layout.template('island') } })
  // Cinema is two bars.
  assert.equal(shapesOf(Draft.addShape(base, 'cinema')).length, 2)
  const around = Draft.addShape(base, 'around', 'media')
  assert.deepEqual(shapesOf(around), [{ kind: 'box', wrap: { modules: ['media'] }, pad: { x: 0, y: 0 }, radius: 'auto',
    fill: { color: 'surface', opacity: 1 }, absorb: true }])
  assert.equal(Draft.addShape(base, 'around'), base, 'around needs a module')
  assert.equal(Draft.addShape(base, 'blob'), base)
  // Four at most, two of them frosted: what the lock refuses is refused.
  let full = base
  for (const name of ['island', 'strip', 'frame', 'card']) full = Draft.addShape(full, name)
  assert.equal(shapesOf(full).length, 4)
  assert.equal(Draft.addShape(full, 'island'), full)
  assert.ok(!Draft.canAddShape(Draft.lookOf(full), 'island'))
  assert.ok(!Draft.canAddShape(Draft.lookOf(Draft.addShape(base, 'frame')), 'cinema') === false)
  const frosty = Draft.addShape(Draft.addShape(base, 'card'), 'sheet')
  assert.equal(Draft.addShape(frosty, 'card'), frosty, 'a third frosted shape')
  assert.ok(!Draft.canAddShape(Draft.lookOf(frosty), 'sheet') && Draft.canAddShape(Draft.lookOf(frosty), 'island'))
  let three = base
  for (const name of ['island', 'strip', 'frame']) three = Draft.addShape(three, name)
  assert.ok(!Draft.canAddShape(Draft.lookOf(three), 'cinema'), 'cinema needs room for two')
})

test('remove, move and set: one entry each, back to the preset is nothing', () => {
  const sheet = { preset: 'sheet' }
  // Setting a key and back leaves no trace.
  const wider = Draft.setShape(sheet, 0, 'pad', 60)
  assert.equal(shapesOf(wider)[0].pad, 60)
  assert.deepEqual(plain(Draft.setShape(wider, 0, 'pad', 44)), sheet)
  // Lengths are whole pixels, opacities hundredths, all within range.
  assert.equal(shapesOf(Draft.setShape(sheet, 0, 'pad', 12.6))[0].pad, 13)
  assert.equal(shapesOf(Draft.setShape(sheet, 0, 'pad', 999))[0].pad, 200)
  assert.equal(shapesOf(Draft.setShape(sheet, 0, 'fill.opacity', 0.123))[0].fill.opacity, 0.12)
  assert.equal(shapesOf(Draft.setShape({ preset: 'split' }, 0, 'size.min.screen', 0.333))[0].size.min.screen, 0.33)
  // A size is one unit: switching sets the whole bound.
  assert.equal(Draft.setShape(sheet, 0, 'size.min.screen', 0.3), sheet)
  assert.deepEqual(shapesOf(Draft.setShape(sheet, 0, 'size.min', { screen: 0.3 }))[0].size, { min: { screen: 0.3 } })
  // null is the default again.
  assert.equal(shapesOf(Draft.setShape(sheet, 0, 'radius', null))[0].radius, undefined)
  // A box's padding starts from its default pair.
  const card = Draft.addShape({ preset: 'foamy' }, 'around', 'media')
  assert.deepEqual(shapesOf(Draft.setShape(Draft.setShape(card, 0, 'pad', null), 0, 'pad.x', 8))[0].pad, { x: 8, y: 16 })
  // Leaving "across" takes the box's inset along.
  const strip = Draft.setShape({ preset: 'dock' }, 0, 'inset', 30)
  assert.equal(shapesOf(strip)[0].inset, 30)
  assert.equal(shapesOf(Draft.setShape(strip, 0, 'stretch', 'none'))[0].inset, undefined)
  // Refused: what the lock refuses, and the kind.
  assert.equal(Draft.setShape(sheet, 0, 'kind', 'box'), sheet)
  assert.equal(Draft.setShape(sheet, 0, 'style', 'glow'), sheet, 'a panel has no style')
  assert.equal(Draft.setShape(Draft.addShape({ preset: 'foamy' }, 'island'), 0, 'border.sides', 'inner').background.shapes[0].border, undefined)
  assert.equal(Draft.setShape(sheet, 3, 'pad', 1), sheet, 'no such shape')
  // Remove and move.
  const two = Draft.addShape(sheet, 'frame')
  assert.deepEqual(shapesOf(Draft.moveShape(two, 1, 0)).map(s => s.kind), ['frame', 'panel'])
  assert.equal(Draft.moveShape(two, 1, 5), two)
  assert.deepEqual(plain(Draft.removeShape(two, 1)), sheet)
  assert.deepEqual(plain(Draft.removeShape(sheet, 0)), { preset: 'sheet', background: { shapes: [] } })
})

test('what a shape wraps: zones, modules or nothing', () => {
  const island = { preset: 'island' }
  // Modules: the shown ones in its zones; zones: the modules' zones.
  const modules = Draft.setWrapMode(island, 0, 'modules')
  assert.deepEqual(shapesOf(modules)[0].wrap, { modules: ['date', 'clock'] })
  assert.deepEqual(shapesOf(Draft.setWrapMode(modules, 0, 'zones'))[0].wrap, { zones: ['top-center'] })
  assert.equal(Draft.setWrapMode(island, 0, 'none'), island, 'a box wraps something')
  const panel = Draft.setWrapMode({ preset: 'sheet' }, 0, 'none')
  assert.equal(shapesOf(panel)[0].wrap, undefined)
  assert.deepEqual(shapesOf(Draft.setWrapMode(panel, 0, 'modules'))[0].wrap, { modules: ['clock'] })
  // One more or one less; the last one stays.
  const both = Draft.toggleWrapped(modules, 0, 'media', true)
  assert.deepEqual(shapesOf(both)[0].wrap, { modules: ['date', 'clock', 'media'] })
  const one = Draft.toggleWrapped(Draft.toggleWrapped(modules, 0, 'date', false), 0, 'clock', false)
  assert.deepEqual(shapesOf(one)[0].wrap, { modules: ['clock'] })
  assert.deepEqual(shapesOf(Draft.toggleWrapped(island, 0, 'top-end', true))[0].wrap, { zones: ['top-center', 'top-end'] })
  assert.equal(Draft.wrapMode(shapesOf(island)[0]), 'zones')
  assert.deepEqual(plain(Draft.wrappedModules(Draft.lookOf(island), shapesOf(island)[0])), ['clock', 'date'])
})

test('"Wrap in a shape" finds the shape around a module', () => {
  const look = Draft.lookOf(Draft.addShape(Draft.addShape({ preset: 'foamy' }, 'frame'), 'around', 'media'))
  assert.equal(Draft.shapeAround(look, 'media'), 1)
  assert.equal(Draft.shapeAround(look, 'clock'), -1)
  assert.deepEqual(plain(Draft.shapesWrapping(Draft.lookOf({ preset: 'island' }), 'clock')), [0])
  assert.deepEqual(plain(Draft.shapesWrapping(look, 'media')), [1])
})

test('the entry stays sparse with shapes, and carries them to another preset', () => {
  // A preset's own shapes are no change.
  for (const name of Layout.SELECTABLE_PRESETS) assert.deepEqual(plain(Draft.entry(Layout.preset(name))), { preset: name })
  // An older draft's decor is saved as shapes, or as nothing when it is the preset's.
  assert.deepEqual(plain(Draft.entry(Draft.lookOf({ preset: 'island', background: { decor: 'island' } }))), { preset: 'island' })
  assert.deepEqual(plain(Draft.entry(Draft.lookOf({ preset: 'foamy', background: { decor: 'frame' } }))),
    { preset: 'foamy', background: { shapes: [{ kind: 'frame' }] } })
  // Keep changes: the shapes go along as a background override.
  const framed = Draft.addShape({ preset: 'foamy' }, 'frame')
  assert.deepEqual(plain(Draft.presetKeeping(framed, 'island')), { preset: 'island', background: { shapes: [{ kind: 'frame' }] } })
  // The island's shapes on foamy are the island preset's.
  assert.deepEqual(plain(Draft.presetKeeping({ preset: 'island' }, 'foamy')), { preset: 'foamy' })
  assert.equal(Draft.changeCount(framed), 1)
})

test('move up and down in a zone: the stack in order, numbered from the top', () => {
  const base = { preset: 'foamy' }
  const look = Draft.lookOf(base)
  assert.deepEqual(plain(Draft.placeInZone(look, 'clock')), { at: 1, count: 2 })
  const up = Draft.moveInZone(base, 'clock', -1)
  assert.deepEqual(Layout.stack(Draft.lookOf(up).elements, 'top-center'), ['clock', 'date'])
  assert.deepEqual(plain(up.layout), { clock: { order: 0 }, date: { order: 1 } })
  assert.equal(Draft.moveInZone(base, 'clock', 1), base, 'already last')
  assert.equal(Draft.moveInZone(base, 'date', -1), base, 'already first')
  assert.equal(Draft.moveInZone(base, 'media', 1), base, 'alone in its zone')
  // And back.
  assert.deepEqual(plain(Draft.moveInZone(up, 'clock', 1)), base)
  // Hidden modules aren't in the stack.
  assert.deepEqual(plain(Draft.placeInZone(look, 'weather')), { at: -1, count: 0 })
})
