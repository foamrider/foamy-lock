const assert = require('node:assert/strict')
const { test } = require('node:test')
const Model = require('../Model.js')
const config = (settings = {}) => JSON.stringify({version: 1, plugins: [{id: 'foamy.lock', ...settings}]})

test('defaults and all documented settings', () => {
  assert.deepEqual(Model.parseConfig(config()).settings, Model.defaults())
  const custom = {...Model.defaults(), timeFormat: '12h', showUserInfo: false, showMedia: false, blankAfterSec: null,
    showArtwork: false, artworkHosts: ['images.example.com'], artworkFileRoots: ['/tmp/album-covers']}
  assert.deepEqual(Model.parseConfig(config(custom)), {valid: true, settings: custom, error: ''})
  assert.equal(Model.parseConfig(config({blankAfterSec: 2147483})).valid, true)
})

test('invalid configuration returns an error without replacement preferences', () => {
  for (const source of ['{', '{}', 'null', JSON.stringify({version: 1, plugins: []}),
    JSON.stringify({version: 1, plugins: [{id: 'foamy.lock'}, {id: 'foamy.lock'}]})]) {
    const result = Model.parseConfig(source)
    assert.equal(result.valid, false)
    assert.equal(result.settings, null)
    assert.ok(result.error)
  }
  for (const settings of [{timeFormat: 'system'}, {showUserInfo: 'false'}, {showMedia: 1},
    {showArtwork: 1}, {artworkHosts: null}, {artworkHosts: ['*.example.com']},
    {artworkHosts: ['http://example.com']}, {artworkHosts: ['127.0.0.1']},
    {artworkHosts: ['EXAMPLE.COM']}, {artworkHosts: Array(33).fill('example.com')},
    {artworkFileRoots: ['/']}, {artworkFileRoots: ['relative']}, {artworkFileRoots: ['/tmp/../home']},
    {artworkFileRoots: ['/tmp/\u0000']}, {artworkFileRoots: Array(15).fill('/tmp/images')},
    ...[0, -1, 1.5, '30', false, 2147484].map(blankAfterSec => ({blankAfterSec}))]) {
    assert.equal(Model.parseConfig(config(settings)).valid, false, JSON.stringify(settings))
  }
})

test('artwork keys distinguish tracks and bound untrusted metadata', () => {
  assert.equal(Model.artworkKey(null), '')
  assert.equal(Model.artworkKey({trackArtUrl: ''}), '')
  assert.equal(Model.artworkKey({trackArtUrl: 'x'.repeat(8193)}), '')
  const player = {trackArtUrl: 'file:///tmp/cover.png', trackTitle: 'First'}
  const first = Model.artworkKey(player)
  player.trackTitle = 'Second'
  assert.notEqual(Model.artworkKey(player), first)
  player.trackTitle = 'x'.repeat(100000)
  assert.equal(JSON.parse(Model.artworkKey(player))[1].length, 512)
})

test('selects playing metadata, falls back when stopped or removed, accepts no player', () => {
  const paused = {trackTitle: 'Paused', isPlaying: false}
  const playing = {trackArtist: 'Artist', isPlaying: true}
  assert.equal(Model.selectPlayer([paused, playing]), playing)
  playing.isPlaying = false
  assert.equal(Model.selectPlayer([paused, playing]), paused)
  assert.equal(Model.selectPlayer([playing]), playing)
  assert.equal(Model.selectPlayer([null, {isPlaying: true}]), null)
  assert.equal(Model.selectPlayer([]), null)
})

test('transport respects player capabilities and play/pause fallbacks', () => {
  const calls = []
  const player = {isPlaying: true, canPause: true, pause: () => calls.push('pause'),
    canPlay: true, play: () => calls.push('play'), canGoNext: true, next: () => calls.push('next'),
    canTogglePlaying: true, togglePlaying: () => calls.push('toggle')}
  assert.equal(Model.runMediaAction(player, 'previous'), false)
  assert.equal(Model.runMediaAction(null, 'next'), false)
  assert.equal(Model.runMediaAction(player, 'unknown'), false)
  Model.runMediaAction(player, 'next')
  Model.runMediaAction(player, 'playPause')
  player.canTogglePlaying = false
  Model.runMediaAction(player, 'playPause')
  player.isPlaying = false
  Model.runMediaAction(player, 'playPause')
  player.canPlay = false
  assert.equal(Model.runMediaAction(player, 'playPause'), false)
  assert.deepEqual(calls, ['next', 'toggle', 'pause', 'play'])
})
