// The login screen's snapshot reading (sddm/Greeter.js) with Layout.js, as
// sddm/Main.qml uses them.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const Greeter = require('../sddm/Greeter.js')
const Layout = require('../Layout.js')

const SNAPSHOT = {
  version: 1,
  user: 'ada',
  timeFormat: '12h',
  showUserInfo: false,
  language: 'nb',
  formatLocale: 'nb-NO',
  rightToLeft: false,
  look: {
    preset: 'sheet',
    layout: { media: { hidden: true }, status: { hidden: true }, weather: { hidden: true }, clock: { scale: 1.2 } },
    background: { source: 'picture', blur: 0.4, dim: 0.3 }
  },
  colors: { background: '#101010', lockText: '#ffeeddcc' },
  lockThemed: ['lockText'],
  strings: { 'Enter password': 'Skriv passord' },
  files: { background: 'background.png', avatar: 'avatar.png' }
}

// What Main.qml shows: the parsed entry, or the fallback when it is rejected.
function shown(snapshot, backgroundPath) {
  const parsed = Layout.parseLook(Greeter.lookEntry(snapshot, backgroundPath))
  return parsed.valid ? parsed.look : Layout.parseLook(Greeter.fallbackEntry()).look
}

test('a version 1 snapshot reads every field the greeter uses', () => {
  const { snapshot, error } = Greeter.parseSnapshot(JSON.stringify(SNAPSHOT))
  assert.equal(error, '')
  assert.equal(snapshot.user, 'ada')
  assert.equal(snapshot.timeFormat, '12h')
  assert.equal(snapshot.showUserInfo, false)
  assert.equal(snapshot.language, 'nb')
  assert.equal(snapshot.formatLocale, 'nb-NO')
  assert.deepEqual(snapshot.colors, SNAPSHOT.colors)
  assert.deepEqual(snapshot.lockThemed, ['lockText'])
  assert.deepEqual(snapshot.strings, SNAPSHOT.strings)
  assert.equal(snapshot.background, true)
  assert.equal(snapshot.avatar, true)
})

test('a picture look shows the copied picture, already blurred by the helper', () => {
  const { snapshot } = Greeter.parseSnapshot(JSON.stringify(SNAPSHOT))
  const look = shown(snapshot, '/usr/share/sddm/themes/foamy-lock/background.png')
  assert.equal(look.preset, 'sheet')
  assert.equal(look.background.source, 'picture')
  assert.equal(look.background.path, '/usr/share/sddm/themes/foamy-lock/background.png')
  assert.equal(look.elements.clock.scale, 1.2)
  // The look itself is left untouched.
  assert.equal(SNAPSHOT.look.background.path, undefined)
})

test('the withheld elements stay hidden whatever the look says', () => {
  const snapshot = Greeter.parseSnapshot(JSON.stringify({
    ...SNAPSHOT,
    look: { preset: 'foamy', layout: { status: { zone: 'top-end', style: 'text', order: 0, hidden: false } } }
  })).snapshot
  const look = shown(snapshot, '')
  for (const name of Greeter.WITHHELD) assert.equal(look.elements[name].hidden, true, name)
  assert.equal(look.elements.password.hidden, false)
})

test('a look Layout.js rejects, or none, falls back to the default preset with the field', () => {
  const cases = [
    ['an unknown preset', { ...SNAPSHOT, look: { preset: 'nope' } }],
    ['a picture without the copied file', { ...SNAPSHOT, files: { background: null, avatar: null } }],
    ['a bad element', { ...SNAPSHOT, look: { layout: { clock: { zone: 'nowhere' } } } }],
    ['no look', { ...SNAPSHOT, look: 'foamy' }]
  ]
  for (const [name, value] of cases) {
    const { snapshot } = Greeter.parseSnapshot(JSON.stringify(value))
    const look = shown(snapshot, snapshot.background ? '/x/background.png' : '')
    assert.equal(look.preset, 'foamy', name)
    assert.equal(look.elements.password.hidden, false, name)
    for (const element of Greeter.WITHHELD) assert.equal(look.elements[element].hidden, true, `${name}: ${element}`)
  }
})

test('text that is not a version 1 snapshot gives the defaults and says why', () => {
  const cases = [
    [undefined, 'theme.conf has no snapshot'],
    ['', 'theme.conf has no snapshot'],
    ['{"version": 1,', 'the snapshot is not JSON'],
    ['[1]', 'the snapshot is not an object'],
    ['{"version": 2}', "the snapshot's version is not 1"]
  ]
  for (const [text, reason] of cases) {
    const { snapshot, error } = Greeter.parseSnapshot(text)
    assert.ok(error.startsWith(reason), `${text}: ${error}`)
    assert.equal(snapshot.look, null)
    assert.deepEqual(snapshot.colors, {})
    assert.equal(snapshot.language, 'en')
    assert.equal(snapshot.timeFormat, '24h')
    assert.equal(snapshot.showUserInfo, true)
    assert.equal(snapshot.avatar, false)
    assert.equal(shown(snapshot, '').preset, 'foamy')
  }
})

test('wrong field types take their defaults', () => {
  const { snapshot, error } = Greeter.parseSnapshot(JSON.stringify({
    version: 1, user: 7, timeFormat: 'noon', showUserInfo: 'no', language: '../x', formatLocale: '',
    rightToLeft: 'yes', colors: [], lockThemed: ['lockText', 3], strings: 'x', files: { avatar: '/etc/passwd' }
  }))
  assert.equal(error, '')
  assert.equal(snapshot.user, '')
  assert.equal(snapshot.timeFormat, '24h')
  assert.equal(snapshot.showUserInfo, true)
  assert.equal(snapshot.language, 'en')
  assert.equal(snapshot.formatLocale, 'en-US')
  assert.equal(snapshot.rightToLeft, false)
  assert.deepEqual(snapshot.colors, {})
  assert.deepEqual(snapshot.lockThemed, ['lockText'])
  assert.deepEqual(snapshot.strings, {})
  assert.equal(snapshot.avatar, false)
})

test('the copied avatar shows only for the user who copied the look', () => {
  const { snapshot } = Greeter.parseSnapshot(JSON.stringify(SNAPSHOT))
  assert.equal(Greeter.showsAvatar(snapshot, 'ada'), true)
  assert.equal(Greeter.showsAvatar(snapshot, 'bob'), false)
  assert.equal(Greeter.showsAvatar(snapshot, ''), false)
  const none = Greeter.parseSnapshot(JSON.stringify({ ...SNAPSHOT, files: { avatar: null } })).snapshot
  assert.equal(Greeter.showsAvatar(none, 'ada'), false)
  const anonymous = Greeter.parseSnapshot(JSON.stringify({ ...SNAPSHOT, user: '' })).snapshot
  assert.equal(Greeter.showsAvatar(anonymous, ''), false)
})

test('the session is the uwsm one, else the last', () => {
  assert.equal(Greeter.sessionIndex(['Hyprland', 'Hyprland (uwsm-managed)'], 0), 1)
  assert.equal(Greeter.sessionIndex(['Hyprland', 'Plasma'], 1), 1)
  assert.equal(Greeter.sessionIndex([], 0), 0)
})
