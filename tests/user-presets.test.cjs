const assert = require('node:assert/strict')
const { test } = require('node:test')
const Layout = require('../Layout.js')
const Model = require('../Model.js')

const config = (entry = {}) => JSON.stringify({version: 1, plugins: [{id: 'foamy.lock', ...entry}]})
const preset = (id, name = 'Mine', look = {preset: 'zen'}) => ({id, name, look})

// The three groups as Service reads them from one shell.json text.
function read(entry) {
  const result = Model.parseConfig(config(entry))
  return {settings: result.settings, look: Layout.parseLook(result.entry), presets: Layout.parseUserPresets(result.entry)}
}

test('user presets are read item by item, newest first', () => {
  const list = [preset('b', 'Second', {preset: 'corner', layout: {media: {hidden: true}}}), preset('a', 'First')]
  const {presets} = read({userPresets: list})
  assert.equal(presets.invalid, 0)
  assert.equal(presets.error, '')
  assert.deepEqual(presets.presets.map(p => [p.id, p.name]), [['b', 'Second'], ['a', 'First']])
  assert.deepEqual(presets.presets[0].look, list[0].look)
  assert.equal(presets.presets[0].effective.preset, 'corner')
  assert.equal(presets.presets[0].effective.elements.media.hidden, true)
  assert.deepEqual(Layout.parseUserPresets({}), {presets: [], invalid: 0, error: ''})
  assert.deepEqual(Layout.parseUserPresets(null), {presets: [], invalid: 0, error: ''})
})

test('bad presets list, look still applies', () => {
  const look = {preset: 'corner', layout: {media: {hidden: true}}, timeFormat: '12h'}
  for (const userPresets of ['nope', {a: 1}, null, 7]) {
    const {settings, look: parsed, presets} = read({...look, userPresets})
    assert.equal(settings.timeFormat, '12h', JSON.stringify(userPresets))
    assert.equal(parsed.valid, true)
    assert.equal(parsed.look.preset, 'corner')
    assert.deepEqual(presets, {presets: [], invalid: 1, error: 'userPresets must be a list'})
  }
  // Bad items are dropped one by one; the good ones and everything else stay.
  const items = [preset('ok-1'), {id: 'x'}, preset('Bad Id'), preset('ok-2', ' padded'), preset('ok-3', 'x'.repeat(65)),
    preset('ok-4', 'line\nbreak'), preset('ok-5', 'Mine', {preset: 'nope'}), preset('ok-6', 'Mine', {layout: {password: {hidden: true}}}),
    preset('ok-7', 'Mine', {preset: 'zen', userPreset: 'ok-1'}), {...preset('ok-8'), extra: true}, preset('ok-1', 'Twice'),
    null, [], preset('ok-9', 'Ålesund ✓ نمط')]
  const {settings, look: parsed, presets} = read({...look, userPresets: items})
  assert.equal(settings.timeFormat, '12h')
  assert.equal(parsed.valid, true)
  assert.deepEqual(presets.presets.map(p => p.id), ['ok-1', 'ok-9'])
  assert.equal(presets.invalid, items.length - 2)
  assert.match(presets.error, /^userPresets\[1\]: /)
  // A bad look and bad settings never touch the presets either.
  const broken = read({preset: 'nope', timeFormat: 'system', userPresets: [preset('a')]})
  assert.equal(broken.look.valid, false)
  assert.equal(broken.settings, null)
  assert.deepEqual(broken.presets.presets.map(p => p.id), ['a'])
})

test('the link to a user preset is ignored when the id is unknown', () => {
  const presets = Layout.parseUserPresets({userPresets: [preset('a')]}).presets
  assert.equal(Layout.userPresetLink({userPreset: 'a'}, presets), 'a')
  assert.equal(Layout.userPresetLink({userPreset: 'gone'}, presets), '')
  assert.equal(Layout.userPresetLink({userPreset: 3}, presets), '')
  assert.equal(Layout.userPresetLink({}, presets), '')
  // The look itself doesn't depend on the link.
  assert.equal(Layout.parseLook({preset: 'zen', userPreset: 'gone'}).valid, true)
  assert.equal(Layout.findUserPreset(presets, 'a').name, 'Mine')
  assert.equal(Layout.findUserPreset(presets, 'b'), null)
})

test('reading stops at 50 presets and at 256 KiB', () => {
  const many = Array.from({length: 53}, (_, i) => preset('p' + i))
  const read50 = Layout.parseUserPresets({userPresets: many})
  assert.equal(read50.presets.length, Layout.USER_PRESET_LIMIT)
  assert.equal(read50.invalid, 3)
  assert.match(read50.error, /userPresets\[50\]: only the first 50/)
  // Past 256 KiB (here a hand-written item the lock can't read fills it).
  const filler = {junk: 'x'.repeat(Layout.USER_PRESETS_BYTES - 20)}
  const parsed = Layout.parseUserPresets({userPresets: [preset('first'), filler, preset('late')]})
  assert.deepEqual(parsed.presets.map(p => p.id), ['first'])
  assert.equal(parsed.invalid, 2)
  assert.match(parsed.error, /^userPresets\[1\]: user presets past 262144 bytes/)
  const small = {junk: 'x'.repeat(Layout.USER_PRESETS_BYTES - 100)}
  assert.deepEqual(Layout.parseUserPresets({userPresets: [small, preset('a'), preset('b'), preset('c'), preset('d')]}).presets.map(p => p.id), ['a'])
  assert.equal(Layout.utf8Length('aé✓😀'), 1 + 2 + 3 + 4)
})

test('savePreset merges one item into the entry and keeps the rest', () => {
  const entry = {id: 'foamy.lock', timeFormat: '12h', preset: 'zen', userPresets: [preset('a'), {broken: true}]}
  const saved = Layout.savingPreset(entry, preset('b', 'New', {preset: 'corner'}))
  assert.equal(saved.error, '')
  assert.deepEqual(saved.entry, {timeFormat: '12h', preset: 'zen',
    userPresets: [preset('b', 'New', {preset: 'corner'}), preset('a'), {broken: true}]})
  // A known id is updated where it is (and a duplicate of it goes).
  const updated = Layout.savingPreset({userPresets: [preset('x'), preset('a'), preset('a', 'Dup')]}, preset('a', 'Renamed'))
  assert.deepEqual(updated.entry.userPresets, [preset('x'), preset('a', 'Renamed')])
  // The input entry is never modified.
  assert.deepEqual(entry.userPresets, [preset('a'), {broken: true}])
  assert.equal(entry.id, 'foamy.lock')
})

test('an idempotent retry saves the same entry again', () => {
  const entry = {id: 'foamy.lock', userPresets: [preset('a')]}
  const first = Layout.savingPreset(entry, preset('n', 'New'))
  const retry = Layout.savingPreset({id: 'foamy.lock', ...first.entry}, preset('n', 'New'))
  assert.deepEqual(retry.entry, first.entry)
  const deleted = Layout.deletingPreset({id: 'foamy.lock', ...first.entry}, 'n')
  assert.deepEqual(Layout.deletingPreset({id: 'foamy.lock', ...deleted.entry}, 'n').entry, deleted.entry)
  assert.equal(Layout.deletingPreset({}, 'n').error, '')
  assert.deepEqual(Layout.deletingPreset({}, 'n').entry, {})
})

test('two quick operations do not revert each other', () => {
  // Service takes each written entry as the last one read at once.
  let last = {id: 'foamy.lock', timeFormat: '12h'}
  const write = change => {
    assert.equal(change.error, '')
    last = {id: 'foamy.lock', ...change.entry}
  }
  write(Layout.savingPreset(last, preset('a', 'One')))
  write(Layout.renamingPreset(last, 'a', 'Uno'))
  write(Layout.savingPreset(last, preset('b', 'Two')))
  assert.deepEqual(last.userPresets, [preset('b', 'Two'), preset('a', 'Uno')])
  assert.equal(last.timeFormat, '12h')
})

test('caps: 50 presets and 256 KiB', () => {
  const full = {userPresets: Array.from({length: 50}, (_, i) => preset('p' + i))}
  assert.deepEqual(Layout.savingPreset(full, preset('new')), {error: 'full', entry: null})
  // An update fits even when the list is full.
  assert.equal(Layout.savingPreset(full, preset('p3', 'Changed')).error, '')
  // The cap counts the whole list as written, items the lock skips too.
  const heavy = {userPresets: [{junk: 'x'.repeat(Layout.USER_PRESETS_BYTES - 120)}]}
  assert.deepEqual(Layout.savingPreset(heavy, preset('a', 'x'.repeat(64))), {error: 'too-large', entry: null})
  assert.equal(Layout.savingPreset(heavy, preset('a', 'A')).error, '')
  assert.equal(Layout.renamingPreset({userPresets: [preset('a'), heavy.userPresets[0]]}, 'a', 'x'.repeat(64)).error, 'too-large')
})

test('rename and delete', () => {
  const entry = {id: 'foamy.lock', preset: 'zen', userPreset: 'a', userPresets: [preset('a'), preset('b')]}
  assert.deepEqual(Layout.renamingPreset(entry, 'b', 'Bee').entry.userPresets, [preset('a'), preset('b', 'Bee')])
  assert.deepEqual(Layout.renamingPreset(entry, 'zz', 'Bee'), {error: 'unknown-preset', entry: null})
  // Deleting the linked preset drops the link, never the look.
  const deleted = Layout.deletingPreset(entry, 'a')
  assert.deepEqual(deleted.entry, {preset: 'zen', userPresets: [preset('b')]})
  assert.deepEqual(Layout.deletingPreset(deleted.entry, 'b').entry, {preset: 'zen'})
  assert.deepEqual(Layout.deletingPreset(entry, 'b').entry.userPreset, 'a')
  // A list that isn't one is refused, not replaced.
  for (const op of [e => Layout.savingPreset(e, preset('a')), e => Layout.renamingPreset(e, 'a', 'x'), e => Layout.deletingPreset(e, 'a')])
    assert.match(op({userPresets: 'nope'}).error, /^invalid: shell.json's userPresets isn't a list/)
})

test('items are checked like the lock reads them', () => {
  assert.equal(Layout.userPresetError(preset('a-1')), '')
  assert.equal(Layout.userPresetError(preset('a'.repeat(40))), '')
  for (const [item, pattern] of [[preset('a'.repeat(41)), /^id must be/], [preset('-a'), /^id must be/], [preset(''), /^id must be/],
    [preset('a', ''), /^name must be/], [preset('a', 'x'.repeat(65)), /at most 64/], [preset('a', 'tab\there'), /control/],
    [preset('a', 'Mine', []), /^look must be an object/], [preset('a', 'Mine', {userPreset: 'a'}), /unknown key: userPreset/],
    [preset('a', 'Mine', {preset: 'field-only'}), /^preset must be one of/], [{...preset('a'), when: 1}, /unknown key: when/],
    ['a', /must be an object/]])
    assert.match(Layout.userPresetError(item), pattern, JSON.stringify(item))
  assert.equal(Layout.userPresetNameError('x'.repeat(64)), '')
  assert.equal(Layout.userPresetIdError('ok'), '')
})
