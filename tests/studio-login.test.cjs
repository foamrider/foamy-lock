// studio/Login.js: the login-screen copy's replies, request and states.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../Layout.js')

// A QML library (".pragma library", ".import"): run it in a vm with
// Layout.js bound as `Layout`, as the QML import does.
function load() {
  const file = path.join(__dirname, '../studio/Login.js')
  const source = fs.readFileSync(file, 'utf8')
    .replace(/^\s*\.pragma\s+library\s*$/m, '')
    .replace(/^\s*\.import\s+"Layout\.js"\s+as\s+Layout\s*$/m, '')
  assert.ok(!/^\s*\.(pragma|import)\b/m.test(source), 'no other QML directives')
  const sandbox = { module: { exports: {} }, Layout, console }
  vm.runInNewContext(source, sandbox, { filename: file })
  return sandbox.module.exports
}
const Login = load()
const plain = value => JSON.parse(JSON.stringify(value))
const HASH = 'a'.repeat(64)
const line = value => JSON.stringify(value) + '\n'
const status = extra => Object.assign({ ok: true, state: 'not-installed', theme: 'omarchy',
  themeSetIn: '/etc/sddm.conf.d/10-theme.conf', themeDir: '/usr/share/sddm/themes', autologin: true, installed: null,
  managed: { theme: false, dropin: false } }, extra)

test('the stage limits and colour keys match stage.rs', () => {
  const stage = fs.readFileSync(path.join(__dirname, '../native/src/studio/login_screen/stage.rs'), 'utf8')
  const keys = /pub const COLOR_KEYS: \[&str; 19\] = \[([^\]]*)\]/.exec(stage)[1].match(/"[A-Za-z]+"/g).map(k => JSON.parse(k))
  assert.deepEqual(plain(Login.COLOR_KEYS), keys)
  assert.match(stage, new RegExp(`MAX_WIDTH: u32 = ${Login.MAX_WIDTH};`))
  assert.match(stage, new RegExp(`MAX_HEIGHT: u32 = ${Login.MAX_HEIGHT};`))
  const statusRs = fs.readFileSync(path.join(__dirname, '../native/src/studio/login_screen/status.rs'), 'utf8')
  for (const state of Login.STATES) assert.ok(statusRs.includes(`"${state}"`), state)
})

test('status replies become reports, and anything else is an error', () => {
  assert.deepEqual(plain(Login.statusReport(0, line(status()))), status())
  const installed = status({ state: 'installed', theme: 'foamy-lock', installed: { plugin: '1.2.0', hash: HASH } })
  assert.deepEqual(plain(Login.statusReport(0, 'noise\n' + line(installed))), installed)
  assert.equal(Login.statusReport(0, line(status({ state: 'unavailable', reason: 'not-sddm', theme: '', themeSetIn: null }))).state, 'unavailable')
  const long = Login.statusReport(0, line(status({ theme: 'x'.repeat(300) })))
  assert.equal(long.theme.length, 64)
  assert.ok(long.theme.endsWith('…'))
  const failures = [
    [1, line({ ok: false, code: 'IO', error: '/etc/sddm.conf: Permission denied' }), 'IO'],
    [124, '', 'timeout'], [137, '', 'timeout'], [-1, '', 'start-failed'], [127, '', 'helper-unavailable'],
    [126, '', 'helper-unavailable'], [0, 'not json', 'unexpected'], [0, '', 'unexpected'],
    [1, line({ ok: false, code: 'lower' }), 'unexpected'], [101, line({ ok: false, code: 'INTERNAL' }), 'unexpected'],
    [0, line(status({ state: 'gone' })), 'unexpected'], [0, line(status({ autologin: 'yes' })), 'unexpected'],
    [0, line(status({ themeSetIn: 3 })), 'unexpected'],
    [0, line(status({ state: 'installed' })), 'unexpected'],
    [0, line(status({ installed: { plugin: '1', hash: HASH } })), 'unexpected'],
    [0, line(status({ state: 'installed', installed: { plugin: '1', hash: 'nothex' } })), 'unexpected'],
    [0, line(status({ managed: undefined })), 'unexpected'], [0, line(status({ managed: null })), 'unexpected'],
    [0, line(status({ managed: { theme: true } })), 'unexpected'],
    [0, line(status({ managed: { theme: 'yes', dropin: false } })), 'unexpected'],
    [0, line(['a']), 'unexpected']
  ]
  for (const [exit, text, code] of failures)
    assert.deepEqual(plain(Login.statusReport(exit, text)), { ok: false, code }, `${exit} ${text}`)
})

test('the section state follows status and the compared hash', () => {
  const installed = Login.statusReport(0, line(status({ state: 'installed', installed: { plugin: '1', hash: HASH } })))
  const cases = [
    [null, '', '', 'checking'], [null, 'IO', '', 'error'], [installed, 'IO', HASH, 'error'],
    [Login.statusReport(0, line(status({ state: 'unavailable' }))), '', '', 'hidden'],
    [Login.statusReport(0, line(status())), '', '', 'not-installed'],
    [installed, '', '', 'installed'], [installed, '', HASH, 'current'], [installed, '', 'b'.repeat(64), 'outdated'],
    [Login.statusReport(0, line(status({ state: 'overridden', installed: { plugin: '1', hash: HASH } }))), '', HASH, 'overridden'],
    [Login.statusReport(0, line(status({ state: 'broken', detail: 'x' }))), '', '', 'broken']
  ]
  for (const [report, error, hash, state] of cases) assert.equal(Login.sectionState(report, error, hash), state)
})

test('Remove is offered whenever Foamy\'s files are there, whatever SDDM uses', () => {
  const managed = (theme, dropin) => Login.statusReport(0, line(status({ managed: { theme, dropin } })))
  assert.deepEqual(plain(managed(true, false).managed), { theme: true, dropin: false })
  const installed = Login.statusReport(0, line(status({ state: 'installed', installed: { plugin: '1', hash: HASH },
    managed: { theme: true, dropin: true } })))
  const cases = [
    ['not-installed', managed(false, false), false], ['not-installed', managed(true, false), true],
    ['not-installed', managed(false, true), true], ['not-installed', managed(true, true), true],
    ['current', installed, true], ['outdated', installed, true], ['installed', installed, true],
    ['overridden', managed(true, false), true], ['broken', managed(false, true), true],
    // A failed or first check, or SDDM not in use: nothing to act on.
    ['error', installed, false], ['checking', null, false], ['hidden', managed(false, false), false]
  ]
  for (const [state, report, offered] of cases)
    assert.equal(Login.restoreOffered(state, report), offered, `${state} ${JSON.stringify(report && report.managed)}`)
})

test('a picture shows for the wallpaper and a custom image, by the preset when the entry says nothing', () => {
  const look = entry => Layout.parseLook(entry).look
  assert.equal(Login.showsPicture(look({ preset: 'foamy' })), true)
  assert.equal(Login.showsPicture(look({ preset: 'foamy', background: { source: 'picture', path: '/p.png' } })), true)
  assert.equal(Login.showsPicture(look({ preset: 'foamy', background: { source: 'aurora' } })), false)
  assert.equal(Login.showsPicture(look({ preset: 'foamy', background: { source: 'color', color: 'accent' } })), false)
  for (const name of Layout.SELECTABLE_PRESETS) {
    const source = Layout.preset(name).background.source
    assert.equal(Login.showsPicture(Layout.preset(name)), source === 'omarchy' || source === 'picture', name)
  }
})

test('the background is the screen size, scaled down to 3840 × 2160 keeping its shape', () => {
  const cases = [[[1920, 1080], [1920, 1080]], [[3840, 2160], [3840, 2160]], [[7680, 4320], [3840, 2160]],
    [[5120, 1440], [3840, 1080]], [[3440, 1440], [3440, 1440]], [[2160, 3840], [1215, 2160]], [[0, 0], [16, 16]],
    [['x', null], [16, 16]]]
  for (const [[w, h], expected] of cases) assert.deepEqual(plain(Login.pictureSize(w, h)), expected, `${w}×${h}`)
})

function colors(extra) {
  const out = {}
  for (const key of Login.COLOR_KEYS) out[key] = '#1A2B3C'
  return Object.assign(out, extra)
}
const input = extra => Object.assign({ entry: { preset: 'foamy' }, settings: { timeFormat: '12h', showUserInfo: false },
  colors: colors(), lockThemed: [], language: 'nb', formatLocale: 'nb_NO', rightToLeft: false,
  background: '/c/omarchy/foamy.lock/background/' + HASH + '.png', avatar: '/c/omarchy/foamy.lock/avatar.png' }, extra)

test('the stage request carries the applied look, settings, colours and pictures', () => {
  const made = plain(Login.stageRequest(input({ entry: { preset: 'foamy', userPreset: 'mine', layout: { clock: { scale: 1.2 } } },
    lockThemed: ['lockText', 'lockBorderError', 'lockBackground', 'lockText'], colors: colors({ accent: '#80FFAA00' }) })))
  assert.deepEqual(Object.keys(made.request).sort(), ['avatar', 'background', 'colors', 'formatLocale', 'language', 'lockThemed',
    'look', 'rightToLeft', 'showUserInfo', 'showsPicture', 'timeFormat'])
  assert.deepEqual(made.request.look, { preset: 'foamy', layout: { clock: { scale: 1.2 } } })
  assert.equal(made.request.showsPicture, true)
  assert.equal(made.request.timeFormat, '12h')
  assert.equal(made.request.showUserInfo, false)
  assert.equal(made.request.colors.accent, '#80ffaa00')
  assert.equal(made.request.colors.background, '#1a2b3c')
  // Only the keys a theme can set, in stage.rs's order, once each.
  assert.deepEqual(made.request.lockThemed, ['lockBackground', 'lockText'])
  assert.equal(made.request.avatar, '/c/omarchy/foamy.lock/avatar.png')
  // No picture: the background is never sent; no avatar is null.
  const drawn = plain(Login.stageRequest(input({ entry: { preset: 'foamy', background: { source: 'aurora' } }, avatar: '' })))
  assert.equal(drawn.request.showsPicture, false)
  assert.equal(drawn.request.background, null)
  assert.equal(drawn.request.avatar, null)
  // A picture look without a prepared picture: null, and `stage` says
  // BACKGROUND_MISSING.
  assert.equal(Login.stageRequest(input({ background: '' })).request.background, null)
  assert.equal(Login.stageRequest(input({ settings: {} })).request.timeFormat, '24h')
  assert.equal(Login.stageRequest(input({ settings: {} })).request.showUserInfo, true)
})

test('a stage request the helper would refuse is not made', () => {
  assert.deepEqual(plain(Login.stageRequest(input({ entry: { preset: 'nope' } }))), { error: 'look' })
  assert.deepEqual(plain(Login.stageRequest(input({ colors: colors({ warning: 'red' }) }))), { error: 'color warning' })
  assert.deepEqual(plain(Login.stageRequest(input({ colors: colors({ info: undefined }) }))), { error: 'color info' })
  assert.deepEqual(plain(Login.stageRequest(input({ language: '' }))), { error: 'language' })
  assert.deepEqual(plain(Login.stageRequest(input({ formatLocale: 'nb NO' }))), { error: 'language' })
})

test('stage replies: a stage folder in the runtime directory, or a code', () => {
  const dir = '/run/user/1000/foamy-lock/login-screen/stage-Ab12'
  assert.deepEqual(plain(Login.stageReport(0, line({ ok: true, dir, hash: HASH, files: [] }), '/run/user/1000')),
    { ok: true, dir, hash: HASH })
  const failures = [
    [1, line({ ok: false, code: 'BACKGROUND_MISSING', error: 'x' }), 'BACKGROUND_MISSING'],
    [1, line({ ok: false, code: 'BUNDLE_INVALID', error: 'x' }), 'BUNDLE_INVALID'],
    [124, '', 'timeout'], [-1, '', 'start-failed'], [127, '', 'helper-unavailable'],
    [0, line({ ok: true, dir: '/tmp/stage-Ab12', hash: HASH }), 'unexpected'],
    [0, line({ ok: true, dir: dir + '/../../x', hash: HASH }), 'unexpected'],
    [0, line({ ok: true, dir, hash: 'short' }), 'unexpected'],
    [0, 'garbage', 'unexpected']
  ]
  for (const [exit, text, code] of failures)
    assert.deepEqual(plain(Login.stageReport(exit, text, '/run/user/1000')), { ok: false, code }, text)
  assert.equal(Login.stageReport(0, line({ ok: true, dir, hash: HASH }), '').ok, false)
})

test('pictures are accepted only where the sandboxed kinds write them', () => {
  const cache = '/home/u/.cache/foamy-lock-studio/login'
  const background = `${cache}/omarchy/foamy.lock/background/${HASH}.png`
  const avatar = `${cache}/omarchy/foamy.lock/avatar.png`
  assert.deepEqual(plain(Login.pictureReport('background', 0, line({ ok: true, path: background }), cache)),
    { ok: true, path: background, code: '' })
  assert.deepEqual(plain(Login.pictureReport('avatar', 0, line({ ok: true, path: avatar }), cache)), { ok: true, path: avatar, code: '' })
  const failures = [
    ['background', 0, line({ ok: true, path: `/elsewhere/omarchy/foamy.lock/background/${HASH}.png` }), 'background-helper-failed'],
    ['background', 0, line({ ok: true, path: `${cache}/omarchy/foamy.lock/background/x.png` }), 'background-helper-failed'],
    ['avatar', 0, line({ ok: true, path: background }), 'avatar-helper-failed'],
    ['avatar', 0, line({ ok: false, error: 'avatar-missing' }), 'avatar-missing'],
    ['background', 0, line({ ok: false, error: 'background-missing' }), 'background-missing'],
    ['background', 0, line({ ok: false, error: 'Not A Code' }), 'background-helper-failed'],
    ['background', 124, '', 'timeout'], ['avatar', 127, '', 'helper-unavailable'], ['avatar', -1, '', 'start-failed']
  ]
  for (const [kind, exit, text, code] of failures)
    assert.deepEqual(plain(Login.pictureReport(kind, exit, text, cache)), { ok: false, path: '', code }, `${kind} ${text}`)
})

test('the lock says which avatar it shows; no usable answer is a failure, never a guess', () => {
  const avatar = '/home/u/.cache/omarchy/foamy.lock/avatar.png'
  // Omarchy-shell prints the reply after anything else it says.
  const face = '/home/u/.face'
  assert.deepEqual(plain(Login.lockAvatarReport(0, 'note\n' + line({ userName: 'u', avatarPath: face, avatarRenderPath: avatar }))),
    { ok: true, path: avatar, source: face, code: '' })
  // The initial: the cached avatar.png left behind is not copied; the photo
  // it came from is still named, so Studio watches it.
  assert.deepEqual(plain(Login.lockAvatarReport(0, line({ avatarPath: face, avatarRenderPath: '' }))),
    { ok: true, path: '', source: face, code: '' })
  assert.deepEqual(plain(Login.lockAvatarReport(0, line({ avatarPath: '', avatarRenderPath: '' }))),
    { ok: true, path: '', source: '', code: '' })
  const failures = [
    [1, 'omarchy-shell is not running\n'], [124, ''], [-1, ''], [0, ''], [0, 'Target not found.\n'],
    [0, line({ avatarPath: avatar })], [0, line({ avatarPath: face, avatarRenderPath: null })],
    [0, line({ avatarPath: face, avatarRenderPath: 'avatar.png' })],
    [0, line({ avatarPath: face, avatarRenderPath: avatar + '\nx' })],
    [0, line({ avatarPath: face, avatarRenderPath: '/' + 'a'.repeat(4096) })],
    [0, line({ avatarRenderPath: avatar })], [0, line({ avatarPath: '.face', avatarRenderPath: avatar })],
    [0, line({ avatarPath: face + '\0', avatarRenderPath: avatar })],
    [1, line({ avatarPath: face, avatarRenderPath: avatar })], [0, line([avatar])]
  ]
  for (const [exit, text] of failures)
    assert.deepEqual(plain(Login.lockAvatarReport(exit, text)), { ok: false, path: '', source: '', code: 'lock-status' }, `${exit} ${text}`)
})

test('the publisher: 0 and 1 with JSON, 126 and 127 from pkexec, and never success otherwise', () => {
  const cases = [
    [0, line({ ok: true }), 'ok', ''],
    [0, 'pkexec noise\n' + line({ ok: true }), 'ok', ''],
    [126, '', 'cancelled', ''],
    [127, '', 'denied', ''],
    [1, line({ ok: false, code: 'NOT_OURS', error: 'x' }), 'failed', 'NOT_OURS'],
    [1, line({ ok: false, code: 'IO', error: 'x' }), 'failed', 'IO'],
    [0, '', 'failed', 'unexpected'],
    [0, line({ ok: false, code: 'IO' }), 'failed', 'unexpected'],
    [1, 'oops', 'failed', 'unexpected'],
    [3, '', 'failed', 'exit-3'],
    [124, '', 'failed', 'timeout'],
    [137, '', 'failed', 'timeout'],
    [-1, '', 'failed', 'start-failed'],
    // The publisher isn't an executable file (checked before exec).
    [70, '', 'failed', 'start-failed']
  ]
  for (const [exit, text, result, code] of cases)
    assert.deepEqual(plain(Login.publishReport(exit, text)), { result, code }, `${exit} ${text}`)
})

test('what the look leaves out names only what it shows', () => {
  const look = entry => Layout.parseLook(entry).look
  const hideAll = { media: { hidden: true }, weather: { hidden: true }, status: { hidden: true } }
  assert.deepEqual(plain(Login.leftOut(look({ preset: 'foamy', layout: hideAll }), false)), ['fingerprint'])
  assert.deepEqual(plain(Login.leftOut(look({ preset: 'foamy', layout: { weather: { hidden: false } } }), false)).filter(k => k === 'weather'), ['weather'])
  const system = look({ preset: 'foamy', layout: { media: { hidden: false }, status: { hidden: false, style: 'system' } } })
  assert.deepEqual(plain(Login.leftOut(system, false)).filter(k => k !== 'weather'), ['media', 'system', 'fingerprint'])
  const icons = look({ preset: 'foamy', layout: { status: { hidden: false, style: 'icons' } } })
  assert.ok(Login.leftOut(icons, false).includes('status'))
  const video = look({ preset: 'foamy', layout: hideAll, background: { source: 'picture', path: '/v/clip.mp4' } })
  assert.deepEqual(plain(Login.leftOut(video, false)), ['video', 'fingerprint'])
  assert.deepEqual(plain(Login.leftOut(look({ preset: 'foamy', layout: hideAll }), true)), ['video', 'fingerprint'])
  const aurora = look({ preset: 'foamy', layout: hideAll, background: { source: 'aurora' } })
  assert.deepEqual(plain(Login.leftOut(aurora, true)), ['fingerprint'])
  for (const key of Login.leftOut(system, true)) assert.ok(Login.LEFT_OUT.includes(key), key)
})

test('the publisher\'s ok counts only when status agrees', () => {
  const installed = hash => Login.statusReport(0, line(status({ state: 'installed', theme: 'foamy-lock', installed: { plugin: '1', hash } })))
  assert.equal(Login.confirmed('copy', installed(HASH), HASH), 'done')
  assert.equal(Login.confirmed('copy', installed('b'.repeat(64)), HASH), 'unconfirmed')
  assert.equal(Login.confirmed('copy', Login.statusReport(0, line(status())), HASH), 'unconfirmed')
  assert.equal(Login.confirmed('copy', { ok: false, code: 'IO' }, HASH), 'unconfirmed')
  assert.equal(Login.confirmed('restore', Login.statusReport(0, line(status())), ''), 'done')
  // SDDM is off Foamy's theme, but its files are still there.
  assert.equal(Login.confirmed('restore', Login.statusReport(0, line(status({ managed: { theme: true, dropin: false } }))), ''), 'unconfirmed')
  assert.equal(Login.confirmed('restore', Login.statusReport(0, line(status({ managed: { theme: false, dropin: true } }))), ''), 'unconfirmed')
  assert.equal(Login.confirmed('restore', installed(HASH), ''), 'unconfirmed')
  assert.equal(Login.confirmed('restore', Login.statusReport(0, line(status({ state: 'broken' }))), ''), 'unconfirmed')
  assert.equal(Login.confirmed('restore', null, ''), 'unconfirmed')
})

test('the avatar: a gone or unusable photo is no avatar, a failing sandbox stops the copy', () => {
  for (const code of ['avatar-missing', 'not-owned-regular-file', 'unsupported-format', 'animated-image', 'decode-failed', 'input-too-large'])
    assert.equal(Login.avatarAbsent(code), true, code)
  for (const code of ['decoder-unavailable', 'sandbox-architecture-unsupported', 'job-timeout', 'timeout', 'helper-failed', 'avatar-helper-failed', 'cache-busy', 'start-failed'])
    assert.equal(Login.avatarAbsent(code), false, code)
})
