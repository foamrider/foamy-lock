// The acceptance test of the decorations redesign (docs/plans/
// lock-decorations.md, "Every built-in preset can be recreated with the
// tools"): for every selectable preset, a recipe generated from its look
// (tests/studio-recipe.js) uses only Lock Studio's own controls, each value
// on its control's grid, and run from plain foamy through the Draft
// functions those controls call it makes the preset's look. The studio
// harness runs the same recipes on the real controls.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../Layout.js')

// A QML library (".pragma library", ".import") in a vm, with its imports bound.
function load(file, bindings) {
  const source = fs.readFileSync(path.join(__dirname, file), 'utf8')
    .replace(/^\s*\.pragma\s+library\s*$/m, '')
    .replace(/^\s*\.import\s+"[^"]+"\s+as\s+\w+\s*$/gm, '')
  const sandbox = Object.assign({ module: { exports: {} }, console }, bindings)
  vm.runInNewContext(source, sandbox, { filename: file })
  return sandbox.module.exports
}
const Draft = load('../studio/Draft.js', { Layout })
const Recipe = load('studio-recipe.js', { Layout, Draft })
const plain = value => JSON.parse(JSON.stringify(value))

// Every control a recipe may name: its objectName (a prefix for the ones
// made per value) and what is done to it.
const CONTROLS = {
  studioShown: 'toggle', studioStyles: 'pick', studioZones: 'pick', studioMoveUp: 'click', studioMoveDown: 'click',
  studioSize: 'commit', studioOpacity: 'commit', studioGlass: 'commit', studioScreens: 'pick', studioReveal: 'pick',
  studioDetails: 'pick', studioLocation: 'toggle', studioArtwork: 'toggle', 'studioSource-': 'click', studioAnimation: 'pick',
  'studioSwatch-': 'choose', studioColorHex: 'commit', studioBlur: 'commit', studioDim: 'commit', studioGlassOpacity: 'commit',
  studioTint: 'pick', studioAddShape: 'pick', 'studioShape-': 'click', 'studioShapeUp-': 'click', 'studioShapeDown-': 'click',
  'studioShapeRemove-': 'click', studioShapeWrap: 'pick', studioShapeZones: 'pick', 'studioShapeModule-': 'toggle',
  studioShapeEdge: 'pick', studioShapeStyle: 'pick', studioShapePadX: 'commit', studioShapePadY: 'commit', studioShapePad: 'commit',
  studioShapeAcross: 'toggle', 'studioShapeUnit-': 'pick', 'studioShapeSize-': 'commit', studioShapeInset: 'commit',
  studioShapeRadiusAuto: 'toggle', studioShapeRadius: 'commit', studioShapeFill: 'pick', studioShapeOpacity: 'commit',
  studioShapeFrost: 'toggle', studioShapeBorder: 'pick', studioShapeBorderWidth: 'commit', studioShapeInner: 'toggle',
  studioShapeAbsorb: 'toggle'
}
function kindOf(control) {
  if (CONTROLS[control]) return CONTROLS[control]
  const prefix = Object.keys(CONTROLS).find(key => key.endsWith('-') && control.startsWith(key))
  return prefix ? CONTROLS[prefix] : undefined
}

function run(steps) {
  let draft = { preset: 'foamy' }
  let selected = 'clock'
  for (const step of steps) {
    if (step.page === 'module') selected = step.module
    const next = Recipe.apply(draft, step, selected)
    assert.ok(!Draft.same(next, draft) || step.control.startsWith('studioShape-'), `${step.control} changed nothing: ${JSON.stringify(step)}`)
    draft = next
  }
  return draft
}

for (const name of Layout.SELECTABLE_PRESETS) {
  test(`${name}: recreated from foamy with Lock Studio's controls`, () => {
    const target = Layout.preset(name)
    const recipe = Recipe.recipeFor(target)
    // A value its control can't take fails here, with the control's name.
    assert.deepEqual(plain(recipe.problems), [], name + ': ' + JSON.stringify(recipe.problems))
    for (const step of recipe.steps) {
      assert.equal(kindOf(step.control), step.act, `${name}: ${step.control} isn't a ${step.act} control`)
      const grid = Recipe.GRIDS[step.control]
      if (grid) assert.ok(Math.abs(step.value / grid - Math.round(step.value / grid)) < 1e-9, `${step.control}: ${step.value} off its grid`)
      if (Recipe.WHOLE.includes(step.control)) assert.equal(Math.round(step.value), step.value, step.control)
    }
    const made = Draft.lookOf(run(recipe.steps))
    assert.deepEqual(plain(Recipe.comparable(made)), plain(Recipe.comparable(target)), name)
    // The shapes and the background are the preset's exactly.
    assert.deepEqual(plain(made.background), plain(target.background), name)
    assert.deepEqual(plain(made.glass), plain(target.glass), name)
  })
}

test('a value off its control\'s grid fails with the control\'s name', () => {
  const sheet = Layout.preset('sheet')
  sheet.background.dim = 0.125
  sheet.glass.opacity = 0.42
  sheet.background.shapes[0].fill.opacity = 0.555
  const recipe = Recipe.recipeFor(sheet)
  assert.deepEqual(plain(recipe.problems).map(p => p.control).sort(), ['studioDim', 'studioGlassOpacity', 'studioShapeOpacity'])
})

test('shapes that are no template are made key by key', () => {
  const look = Layout.parseLook({ preset: 'foamy', background: { shapes: [
    { kind: 'box', wrap: { modules: ['media', 'status'] }, pad: { x: 10, y: 6 }, stretch: 'across', inset: 30, radius: 'auto',
      fill: { color: 'surface', opacity: 0.4, frost: true }, border: { color: 'accent', width: 2 }, absorb: true },
    { kind: 'panel', edge: 'top', wrap: { zones: ['top-start', 'top-end'] }, pad: 12, size: { min: { px: 90 }, max: { screen: 0.25 } },
      radius: 12, border: { width: 0 } },
    { kind: 'panel', edge: 'end', pad: 0, size: { min: { screen: 0.2 } }, border: { sides: 'inner', width: 3 } },
    { kind: 'frame', inset: 6, radius: 30, style: 'line' }
  ] } }).look
  assert.ok(look)
  const recipe = Recipe.recipeFor(look)
  assert.deepEqual(plain(recipe.problems), [])
  assert.deepEqual(plain(Draft.lookOf(run(recipe.steps)).background), plain(look.background))
})
