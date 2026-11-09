// studio/Draft.js: user presets (round 2, R2-2): the link, the save flow's
// decisions, names and ids, and the list after an operation.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../Layout.js')

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

// Presets as LockSources has them (Layout.parseUserPresets).
const presets = Layout.parseUserPresets({userPresets: [
  {id: 'mine', name: 'Foamy (mine)', look: {preset: 'foamy', layout: {clock: {scale: 1.2}}}},
  {id: 'zen-2', name: 'Calm', look: {preset: 'zen'}}
]}).presets

test('the link is carried, replaced and read', () => {
  assert.equal(Draft.linkOf({preset: 'zen', userPreset: 'mine'}), 'mine')
  assert.equal(Draft.linkOf({preset: 'zen', userPreset: 'Not An Id'}), '')
  assert.equal(Draft.linkOf({preset: 'zen'}), '')
  assert.deepEqual(plain(Draft.carry({preset: 'zen'}, 'mine')), {preset: 'zen', userPreset: 'mine'})
  assert.deepEqual(plain(Draft.carry({preset: 'zen', userPreset: 'mine'}, '')), {preset: 'zen'})
  // Saved in the lock's key order, the link last.
  assert.equal(JSON.stringify(Draft.ordered({userPreset: 'mine', glass: {opacity: 0.5}, preset: 'zen'})),
    '{"preset":"zen","glass":{"opacity":0.5},"userPreset":"mine"}')
  // Only a link to a preset in the list goes to the lock.
  assert.deepEqual(plain(Draft.forSaving({preset: 'zen', userPreset: 'zen-2'}, presets)), {preset: 'zen', userPreset: 'zen-2'})
  assert.deepEqual(plain(Draft.forSaving({preset: 'zen', userPreset: 'gone'}, presets)), {preset: 'zen'})
})

test('the saved look, the draft on disk and the restored draft keep the link', () => {
  assert.deepEqual(plain(Draft.savedEntry({id: 'foamy.lock', preset: 'zen', userPreset: 'zen-2', timeFormat: '12h'})),
    {preset: 'zen', userPreset: 'zen-2'})
  assert.deepEqual(plain(Draft.savedEntry({preset: 'zen', userPreset: 'Bad'})), {preset: 'zen'})
  const h = Draft.push(Draft.history({preset: 'foamy'}), {preset: 'zen', userPreset: 'zen-2'})
  const disk = plain(Draft.diskDraft(h))
  assert.deepEqual(disk, {look: {preset: 'zen', userPreset: 'zen-2'}, history: [{preset: 'foamy'}]})
  const restored = plain(Draft.restore(disk))
  assert.deepEqual(restored.present, {preset: 'zen', userPreset: 'zen-2'})
  assert.deepEqual(restored.past, [{preset: 'foamy'}])
})

test('what Apply does: update a user preset, ask for a name, or apply', () => {
  const linked = Draft.presetEntry(presets[0])
  assert.deepEqual(plain(linked), {preset: 'foamy', layout: {clock: {scale: 1.2}}, userPreset: 'mine'})
  assert.equal(Draft.saveMode(linked, presets), 'plain')
  assert.equal(Draft.presetChanged(linked, presets), false)
  const edited = Draft.carry(Draft.setBackground(linked, 'dim', 0.5), 'mine')
  assert.equal(Draft.saveMode(edited, presets), 'user')
  assert.equal(Draft.presetChanged(edited, presets), true)
  assert.equal(Draft.saveMode({preset: 'corner'}, presets), 'plain')
  assert.equal(Draft.saveMode({preset: 'corner', background: {dim: 0.5}}, presets), 'builtin')
  // A link to a preset that's gone counts as none.
  assert.equal(Draft.saveMode({preset: 'corner', background: {dim: 0.5}, userPreset: 'gone'}, presets), 'builtin')
  assert.equal(Draft.linkedPreset({preset: 'zen', userPreset: 'zen-2'}, presets).name, 'Calm')
  assert.equal(Draft.linkedPreset({preset: 'zen', userPreset: 'gone'}, presets), null)
})

test('the item savePreset takes', () => {
  const item = plain(Draft.presetItem('u1', 'Mine', {userPreset: 'old', background: {dim: 0.5}, preset: 'zen'}))
  assert.deepEqual(item, {id: 'u1', name: 'Mine', look: {preset: 'zen', background: {dim: 0.5}}})
  assert.equal(JSON.stringify(item.look), '{"preset":"zen","background":{"dim":0.5}}')
  assert.equal(Layout.userPresetError(item), '')
})

test('ids and names', () => {
  const id = Draft.presetId(1793442240000, 'k3x9Q!')
  assert.equal(id, 'u' + (1793442240000).toString(36) + '-k3x9q')
  assert.equal(Layout.userPresetIdError(id), '')
  assert.equal(Layout.userPresetIdError(Draft.presetId(0, '')), '')
  assert.ok(Draft.presetId(Date.now(), 'abcdefghijklmnop').length <= 40)
  assert.equal(Draft.nameProblem('  Foamy (mine) '), '')
  assert.match(Draft.nameProblem('   '), /^name must be/)
  assert.match(Draft.nameProblem('a\nb'), /control/)
  assert.match(Draft.nameProblem('x'.repeat(65)), /at most 64/)
  assert.equal(Draft.uniqueName('Calm', presets), 'Calm 2')
  assert.equal(Draft.uniqueName('Quiet', presets), 'Quiet')
  const many = [{name: 'A'}, {name: 'A 2'}, {name: 'A 3'}]
  assert.equal(Draft.uniqueName('A', many), 'A 4')
  const long = 'x'.repeat(64)
  assert.equal(Draft.uniqueName(long, [{name: long}]), 'x'.repeat(62) + ' 2')
})

test('relinking names the draft without an undo step', () => {
  const h = Draft.push(Draft.history({preset: 'foamy'}), {preset: 'zen', background: {dim: 0.4}})
  const linked = Draft.relink(h, 'u1')
  assert.deepEqual(plain(linked.present), {preset: 'zen', background: {dim: 0.4}, userPreset: 'u1'})
  assert.equal(linked.past.length, h.past.length)
  assert.deepEqual(plain(Draft.relink(linked, '').present), {preset: 'zen', background: {dim: 0.4}})
})

test('the list after an operation the lock confirmed', () => {
  const saved = Draft.presetsAfter(presets, 'save', {id: 'new', name: 'New', look: {preset: 'corner'}})
  assert.deepEqual(saved.map(p => p.id), ['new', 'mine', 'zen-2'])
  assert.equal(saved[0].effective.preset, 'corner')
  const updated = Draft.presetsAfter(saved, 'save', {id: 'mine', name: 'Mine 2', look: {preset: 'flat'}})
  assert.deepEqual(updated.map(p => [p.id, p.name, p.effective.preset]), [['new', 'New', 'corner'], ['mine', 'Mine 2', 'flat'], ['zen-2', 'Calm', 'zen']])
  const renamed = Draft.presetsAfter(updated, 'rename', {id: 'zen-2', name: 'Calmer'})
  assert.equal(renamed[2].name, 'Calmer')
  assert.equal(renamed[2].effective.preset, 'zen')
  assert.deepEqual(Draft.presetsAfter(renamed, 'delete', {id: 'new'}).map(p => p.id), ['mine', 'zen-2'])
  assert.deepEqual(Draft.presetsAfter(renamed, 'delete', {id: 'gone'}).map(p => p.id), ['new', 'mine', 'zen-2'])
  assert.equal(presets.length, 2, 'the list given is never changed')
})

test('the preset replies are told apart', () => {
  for (const result of ['write-failed', 'full', 'too-large', 'unknown-preset']) {
    const report = plain(Draft.applyReport(0, JSON.stringify({ok: false, result, message: 'x', confirmed: true, attempts: 1})))
    assert.deepEqual(report, {result, saved: false, confirmed: true, reason: '', code: ''})
  }
})
