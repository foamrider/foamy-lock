// studio/Draft.js: the background page's video card (round 3, video
// wallpapers): which video a look shows, the facts' parts, the card's state,
// video-convert's progress lines and its reply.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const Layout = require('../Layout.js')
const Model = require('../Model.js')

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
const dir = '/c/omarchy/foamy.lock/video/'
const hash = 'cd'.repeat(32)

test('the video a look shows', () => {
  const look = background => Layout.parseLook({ background }).look
  assert.equal(Draft.videoSource(look({ source: 'picture', path: '/v/a.mp4' }), ''), '/v/a.mp4')
  assert.equal(Draft.videoSource(look({ source: 'picture', path: '/p/a.png' }), '/w/loop.webm'), '')
  assert.equal(Draft.videoSource(look({ source: 'omarchy' }), '/w/loop.webm'), '/w/loop.webm')
  assert.equal(Draft.videoSource(look({ source: 'omarchy' }), ''), '')
  assert.equal(Draft.videoSource(look({ source: 'theme' }), '/w/loop.webm'), '')
  assert.equal(Draft.videoSource(null, '/w/loop.webm'), '')
})

test('the facts in parts', () => {
  assert.deepEqual(['h264', 'hevc', 'vp8', 'vp9', 'av1', 'prores', ''].map(Draft.codecLabel),
    ['H.264', 'HEVC', 'VP8', 'VP9', 'AV1', 'PRORES', ''])
  assert.deepEqual(plain(Draft.duration(252.1)), { minutes: 4, seconds: 12 })
  assert.deepEqual(plain(Draft.duration(59.6)), { minutes: 1, seconds: 0 })
  assert.deepEqual(plain(Draft.duration(0.2)), { minutes: 0, seconds: 1 })
  assert.equal(Draft.duration(null), null)
  assert.equal(Draft.duration(-1), null)
  assert.deepEqual(plain(Draft.megabytes(72318167)), { value: 72, decimals: 0 })
  assert.deepEqual(plain(Draft.megabytes(412000)), { value: 0.4, decimals: 1 })
  assert.deepEqual(plain(Draft.megabytes(12)), { value: 0.1, decimals: 1 })
  assert.deepEqual(plain(Draft.megabytes(9960000)), { value: 10, decimals: 1 })
})

test('the card follows the probe and the conversion', () => {
  const probe = extra => Model.videoProbeResult(JSON.stringify(Object.assign({ ok: true, violations: [],
    poster: dir + hash + '.png', clip: null, output: { width: 3440, height: 1440 } }, extra)), dir)
  assert.deepEqual(plain(Draft.videoCard(null, false, '')), { state: 'checking', code: '' })
  assert.deepEqual(plain(Draft.videoCard(probe({}), false, '')), { state: 'convertible', code: '' })
  assert.deepEqual(plain(Draft.videoCard(probe({}), true, '')), { state: 'converting', code: '' })
  const clip = dir + hash + '-3440x1440.mp4'
  assert.deepEqual(plain(Draft.videoCard(probe({ clip }), false, probe({ clip }).clip)), { state: 'ready', code: '' })
  assert.deepEqual(plain(Draft.videoCard(probe({ violations: ['unsupported-codec', 'input-too-wide'] }), false, '')),
    { state: 'limit', code: 'unsupported-codec' })
  const failed = Model.videoProbeResult('{"ok":false,"error":"decode-failed"}', dir)
  assert.deepEqual(plain(Draft.videoCard(failed, false, '')), { state: 'problem', code: 'decode-failed' })
})

test('progress lines and the reply', () => {
  assert.deepEqual(plain(Draft.videoProgress('{"progress":{"frames":900,"total":1800}}')), { frames: 900, total: 1800, fraction: 0.5 })
  assert.deepEqual(plain(Draft.videoProgress('{"progress":{"frames":2000,"total":1800}}')), { frames: 1800, total: 1800, fraction: 1 })
  for (const line of ['{"ok":true}', '{"progress":{"frames":1}}', '{"progress":{"frames":1,"total":0}}', 'nonsense', ''])
    assert.equal(Draft.videoProgress(line), null, line)
  const clip = dir + hash + '-3440x1440.mp4'
  const ok = JSON.stringify({ ok: true, clip, bytes: 72318167, frames: 1800 })
  assert.deepEqual(plain(Draft.convertReport(0, '{"progress":{"frames":1,"total":2}}\n' + ok + '\n', dir)),
    { ok: true, clip, bytes: 72318167, error: '' })
  assert.deepEqual(plain(Draft.convertReport(0, '{"ok":false,"error":"cancelled"}', dir)), { ok: false, clip: '', bytes: 0, error: 'cancelled' })
  assert.equal(Draft.convertReport(0, JSON.stringify({ ok: true, clip: '/tmp/' + hash + '-3440x1440.mp4' }), dir).error, 'video-helper-failed')
  assert.equal(Draft.convertReport(0, JSON.stringify({ ok: true, clip: dir + 'x.mp4' }), dir).ok, false)
  assert.equal(Draft.convertReport(127, '', dir).error, 'helper-unavailable')
  assert.equal(Draft.convertReport(1, '', dir).error, 'video-helper-failed')
})

test('motion and pauseOnBattery are background keys the draft can set', () => {
  let draft = Draft.setPicture({ preset: 'foamy' }, '/v/loop.mp4')
  draft = Draft.setBackground(draft, 'motion', 'play')
  assert.deepEqual(plain(draft), { preset: 'foamy', background: { source: 'picture', path: '/v/loop.mp4', motion: 'play' } })
  draft = Draft.setBackground(draft, 'pauseOnBattery', false)
  assert.deepEqual(plain(draft.background), { source: 'picture', path: '/v/loop.mp4', motion: 'play', pauseOnBattery: false })
  // Back to the defaults: the keys go.
  draft = Draft.setBackground(Draft.setBackground(draft, 'motion', 'still'), 'pauseOnBattery', true)
  assert.deepEqual(plain(draft), { preset: 'foamy', background: { source: 'picture', path: '/v/loop.mp4' } })
  // A value the lock refuses changes nothing.
  assert.equal(Draft.setBackground(draft, 'motion', 'loop'), draft)
})
