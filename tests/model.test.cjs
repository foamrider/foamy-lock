const assert = require('node:assert/strict')
const { test } = require('node:test')
const Model = require('../Model.js')
const config = (settings = {}) => JSON.stringify({version: 1, plugins: [{id: 'foamy.lock', ...settings}]})

test('defaults and all documented settings', () => {
  assert.deepEqual(Model.parseConfig(config()).settings, Model.defaults())
  const custom = {...Model.defaults(), timeFormat: '12h', showUserInfo: false, showMedia: false, blankAfterSec: null,
    showArtwork: false, artworkHosts: ['images.example.com'], artworkFileRoots: ['/tmp/album-covers']}
  assert.deepEqual(Model.parseConfig(config(custom)), {valid: true, settings: custom, error: '', stockLockEnabled: true,
    entry: {id: 'foamy.lock', ...custom}})
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
    {showArtwork: 1}, {showBrowserMedia: 'yes'}, {artworkHosts: null}, {artworkHosts: ['*.example.com']},
    {artworkHosts: ['http://example.com']}, {artworkHosts: ['127.0.0.1']},
    {artworkHosts: ['EXAMPLE.COM']}, {artworkHosts: Array(33).fill('example.com')},
    {artworkFileRoots: ['/']}, {artworkFileRoots: ['relative']}, {artworkFileRoots: ['/tmp/../home']},
    {artworkFileRoots: ['/tmp/\u0000']}, {artworkFileRoots: Array(15).fill('/tmp/images')},
    ...[0, -1, 1.5, '30', false, 2147484].map(blankAfterSec => ({blankAfterSec}))]) {
    assert.equal(Model.parseConfig(config(settings)).valid, false, JSON.stringify(settings))
  }
})

test('the foamy.lock entry is returned for the look keys, even when a setting is invalid', () => {
  const look = {preset: 'corner', layout: {media: {hidden: true}}}
  assert.deepEqual(Model.parseConfig(config(look)).entry, {id: 'foamy.lock', ...look})
  const invalid = Model.parseConfig(config({...look, timeFormat: 'system'}))
  assert.equal(invalid.valid, false)
  assert.deepEqual(invalid.entry, {id: 'foamy.lock', ...look, timeFormat: 'system'})
  for (const source of ['{', JSON.stringify({version: 1, plugins: []}),
    JSON.stringify({version: 1, plugins: [{id: 'foamy.lock'}, {id: 'foamy.lock'}]})])
    assert.equal(Model.parseConfig(source).entry, null, source)
  // Look keys are not settings: they never invalidate or appear in them.
  assert.deepEqual(Model.parseConfig(config({preset: 'nonsense'})).settings, Model.defaults())
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


test('wallpaper paths distinguish video and produce versioned local URLs', () => {
  assert.equal(Model.isVideoPath('/tmp/loop.MP4'), true)
  assert.equal(Model.isVideoPath('/tmp/loop.webm'), true)
  assert.equal(Model.isVideoPath('/tmp/loop.mp4.png'), false)
  assert.equal(Model.isVideoPath(''), false)
  assert.equal(Model.fileUrl('', 3), '')
  assert.equal(Model.fileUrl('/tmp/a #?%.png', 3), 'file:///tmp/a%20%23%3F%25.png?v=3')
  assert.notEqual(Model.fileUrl('/tmp/a.png', 1), Model.fileUrl('/tmp/a.png', 2))
})

test('a foamy.lock entry without omarchy.lock in disabledPlugins is a conflict', () => {
  const entry = {id: 'foamy.lock'}
  assert.equal(Model.parseConfig(JSON.stringify({version: 1, plugins: [entry]})).stockLockEnabled, true)
  assert.equal(Model.parseConfig(JSON.stringify({version: 1, plugins: [entry], disabledPlugins: ['omarchy.lock']})).stockLockEnabled, false)
  assert.equal(Model.parseConfig(JSON.stringify({version: 1, plugins: [entry], disabledPlugins: ['omarchy.idle']})).stockLockEnabled, true)
  assert.equal(Model.parseConfig('{').stockLockEnabled, null)
})

test('media-is-playing semantics match the shared contract', () => {
  const vectors = require('./media-playing.json')
  for (const {players, playing} of vectors.cases)
    assert.equal(Model.mediaPlaying(players), playing, JSON.stringify(players))
  assert.equal(Model.mediaPlaying(null), false)
})

test('browser players stay off the lock screen unless opted in', () => {
  const browsers = [{dbusName: 'org.mpris.MediaPlayer2.firefox.instance_1_42'},
    {dbusName: 'org.mpris.MediaPlayer2.chromium.instance9', identity: 'Chromium'},
    {desktopEntry: 'brave-browser'}, {desktopEntry: 'google-chrome'}, {desktopEntry: 'zen'},
    {identity: 'Mozilla Firefox'}, {dbusName: 'org.mpris.MediaPlayer2.plasma-browser-integration'}]
  for (const names of browsers) assert.equal(Model.isBrowserPlayer(names), true, JSON.stringify(names))
  for (const names of [{desktopEntry: 'spotify', identity: 'Spotify'}, {dbusName: 'org.mpris.MediaPlayer2.mpv'},
    {desktopEntry: 'zenity'}, {identity: 'Chromecast speaker'}, null])
    assert.equal(Model.isBrowserPlayer(names), false, JSON.stringify(names))
  const tab = {trackTitle: 'Private video', isPlaying: true, desktopEntry: 'firefox'}
  const music = {trackTitle: 'Song', isPlaying: false, desktopEntry: 'spotify'}
  assert.equal(Model.selectPlayer([tab, music]), music)
  assert.equal(Model.selectPlayer([tab]), null)
  assert.equal(Model.selectPlayer([tab, music], true), tab)
})

test('artwork precheck refuses what the helper would, without spawning it', () => {
  assert.equal(Model.artworkPrecheck('https://i.scdn.co/image/a', [], []), 'host-not-allowed')
  assert.equal(Model.artworkPrecheck('https://I.SCDN.CO:443/image/a', ['i.scdn.co'], []), '')
  assert.equal(Model.artworkPrecheck('https://other.example/a', ['i.scdn.co'], []), 'host-not-allowed')
  assert.equal(Model.artworkPrecheck('http://i.scdn.co/a', ['i.scdn.co'], []), 'unsupported-scheme')
  assert.equal(Model.artworkPrecheck('data:image/png;base64,AA', [], []), 'unsupported-scheme')
  assert.equal(Model.artworkPrecheck('', [], []), 'invalid-url')
  assert.equal(Model.artworkPrecheck('file:///home/u/.cache/a%20b.png', [], ['/home/u/.cache']), '')
  assert.equal(Model.artworkPrecheck('file:///home/u/.cache/a.png', [], ['/home/u/.cache/']), '')
  assert.equal(Model.artworkPrecheck('file:///home/u/.cachex/a.png', [], ['/home/u/.cache']), 'file-outside-roots')
  // Anything the precheck cannot parse is left to the helper, which rejects it.
  assert.equal(Model.artworkPrecheck('https://user@i.scdn.co/a', [], []), '')
  assert.equal(Model.artworkPrecheck('file:///bad%zz.png', [], ['/tmp']), '')
})

test('artwork roots are normalised exactly like os.path.abspath (the helper\'s rule)', () => {
  const cases = {'/home/u/Music/.': '/home/u/Music', '/home//u/Music': '/home/u/Music', '/home/u/Music/': '/home/u/Music',
    '//home/u': '//home/u', '///home/u': '/home/u', '/.': '/', '//': '//', '/a/./b': '/a/b', '/a/b/../c': '/a/c'}
  for (const [root, normal] of Object.entries(cases)) assert.equal(Model.normalizeRoot(root), normal, root)
  const url = 'file:///home/u/Music/a.png'
  for (const root of ['/home/u/Music/.', '/home//u/Music', '/home/u/./Music', '/home/u/Music//', '/.', '//'])
    assert.equal(Model.artworkPrecheck(url, [], [root]), '', root)
  assert.equal(Model.artworkPrecheck(url, [], ['//home/u/Music']), 'file-outside-roots')
  assert.equal(Model.artworkPrecheck(url, [], ['/home/u/Music/sub/..']), 'invalid-roots')
  assert.equal(Model.artworkPrecheck('file:///home/u/Music/../Music/a.png', [], ['/home/u/Music']), 'invalid-file-path')
  assert.equal(Model.artworkPrecheck('https://i.scdn.co/a', ['BAD HOST'], []), 'invalid-hosts')
})

test('ISO week numbers, across year boundaries', () => {
  const week = (y, m, d) => Model.isoWeek(new Date(y, m - 1, d))
  assert.deepEqual(week(2026, 9, 26), {week: 39, year: 2026})
  assert.deepEqual(week(2026, 1, 1), {week: 1, year: 2026}, 'a Thursday')
  assert.deepEqual(week(2027, 1, 1), {week: 53, year: 2026}, 'a Friday in 2026\'s last week')
  assert.deepEqual(week(2027, 1, 4), {week: 1, year: 2027})
  assert.deepEqual(week(2024, 12, 30), {week: 1, year: 2025}, 'a Monday in next year\'s first week')
  assert.deepEqual(week(2021, 1, 3), {week: 53, year: 2020}, 'a Sunday ends the week')
  assert.deepEqual(week(2021, 1, 4), {week: 1, year: 2021})
  assert.deepEqual(week(2023, 1, 1), {week: 52, year: 2022})
  assert.deepEqual(week(2026, 12, 31), {week: 53, year: 2026})
  // Every day of a long span: weeks run 1..52|53 and change only on Mondays.
  let last = week(2019, 12, 30)
  for (let day = new Date(2019, 11, 31); day < new Date(2031, 0, 1); day.setDate(day.getDate() + 1)) {
    const now = Model.isoWeek(day)
    if (day.getDay() === 1) assert.ok(now.week === last.week + 1 || (now.week === 1 && last.week >= 52), day.toDateString())
    else assert.deepEqual(now, last, day.toDateString())
    last = now
  }
})

test('weather replies are checked field by field and hidden when old', () => {
  const now = Date.parse('2026-11-08T10:00:00Z')
  const good = {ok: true, temperature: 6, unit: 'C', code: 'lightrain', condition: 'Light rain', high: 10, low: 2,
    location: 'Bergen', updatedAt: '2026-11-08T08:30:00.000Z'}
  const parse = (value, at = now) => Model.parseWeather(typeof value === 'string' ? value : JSON.stringify(value), at)
  assert.deepEqual(parse(good), {state: 'ok', weather: {temperature: 6, unit: 'C', code: 'lightrain', group: 'rain',
    condition: 'Light rain', high: 10, low: 2, location: 'Bergen', updatedAtMs: Date.parse(good.updatedAt)}})
  assert.equal(parse({...good, high: null, low: null}).weather.high, null)
  assert.equal(parse({...good, unit: 'F', temperature: -40}).state, 'ok')
  assert.equal(parse({...good, condition: '', location: ''}).state, 'ok')
  for (const reason of ['no-location', 'offline', 'unsupported', 'error', 'whatever'])
    assert.deepEqual(parse({ok: false, reason}), {state: 'unavailable', weather: null}, reason)
  assert.deepEqual(parse({ok: false, reason: 'pending'}), {state: 'pending', weather: null})
  // Three hours is the cutoff; a clock slightly ahead is fine, far ahead is not.
  assert.equal(parse(good, Date.parse('2026-11-08T11:30:00Z')).state, 'ok')
  assert.equal(parse(good, Date.parse('2026-11-08T11:30:01Z')).state, 'stale')
  assert.equal(parse(good, Date.parse('2026-11-08T08:25:00Z')).state, 'ok')
  assert.equal(parse(good, Date.parse('2026-11-08T08:00:00Z')).state, 'stale')
  assert.equal(parse({...good, updatedAt: ''}).state, 'stale', 'unknown age')
  assert.equal(Model.weatherFresh(parse(good).weather, Date.parse('2026-11-08T12:00:00Z')), false)
  const invalid = [
    '', 'nope', '[]', 'null', '{"ok":"true"}', JSON.stringify({...good, ok: undefined}), 'x'.repeat(5000),
    {...good, temperature: '6'}, {...good, temperature: 6.5}, {...good, temperature: 1e9}, {...good, temperature: null},
    {...good, high: '10'}, {...good, low: true}, {...good, unit: 'K'}, {...good, unit: undefined},
    {...good, code: 'Light Rain'}, {...good, code: 'a'.repeat(49)}, {...good, code: ''}, {...good, code: 3},
    {...good, condition: 'x'.repeat(65)}, {...good, condition: 'Rain\nand more'}, {...good, condition: 7}, {...good, condition: undefined},
    {...good, location: 'y'.repeat(81)}, {...good, location: 'Ber‮gen'}, {...good, location: '<b>x</b>\u0000'},
    {...good, updatedAt: 'yesterday'}, {...good, updatedAt: '2026-11-08'}, {...good, updatedAt: 1762590600000}, {...good, updatedAt: undefined}
  ]
  for (const value of invalid)
    assert.deepEqual(parse(value), {state: 'invalid', weather: null}, typeof value === 'string' ? value.slice(0, 40) : JSON.stringify(value).slice(0, 120))
  // Markup is only text: the lock draws it as plain text.
  assert.equal(parse({...good, condition: '<img src=x>'}).weather.condition, '<img src=x>')
})

test('MET symbol codes map to eight icon groups', () => {
  const groups = {clearsky_day: 'clear', clearsky_night: 'clear', clearsky_polartwilight: 'clear', fair_day: 'partly',
    partlycloudy_night: 'partly', cloudy: 'cloudy', fog: 'fog', lightrain: 'rain', rainshowers_day: 'rain', heavyrain: 'rain',
    sleet: 'sleet', lightsleetshowers_night: 'sleet', snow: 'snow', heavysnowshowers_day: 'snow', rainandthunder: 'thunder',
    lightssnowshowersandthunder_day: 'thunder', heavysleetandthunder: 'thunder', somethingnew: 'cloudy', '': 'cloudy'}
  for (const [code, group] of Object.entries(groups)) assert.equal(Model.weatherGroup(code), group, code)
  assert.equal(new Set(Object.values(groups)).size, 8)
})

test('the keyboard layout comes from the keyboard being typed on', () => {
  const devices = {keyboards: [
    {name: 'power-button', active_keymap: 'English (US)', active_layout_index: 3},
    {name: 'at-translated-set-2-keyboard', active_keymap: 'English (US)', active_layout_index: 0},
    {name: 'usb-keyboard', active_keymap: 'Norwegian', active_layout_index: 1},
    {name: 'hl-virtual-keyboard', active_keymap: 'English (US)', active_layout_index: 5}
  ]}
  const text = JSON.stringify(devices)
  assert.equal(Model.keyboardLayout(text, ''), 'Norwegian', 'furthest through the list')
  assert.equal(Model.keyboardLayout(text, 'at-translated-set-2-keyboard'), 'English (US)', 'named by the event')
  assert.equal(Model.keyboardLayout(text, 'power-button'), 'Norwegian', 'never a button')
  for (const bad of ['', 'nope', '{}', '{"keyboards":{}}', '{"keyboards":[]}', '{"keyboards":[{"name":"k","active_keymap":"x\\ny"}]}',
    JSON.stringify({keyboards: [{name: 'k', active_keymap: 'z'.repeat(81)}]}), JSON.stringify({keyboards: [{name: 'k'}]})])
    assert.equal(Model.keyboardLayout(bad, ''), '', bad)
  assert.equal(Model.eventKeyboardName('usb-keyboard,Norwegian'), 'usb-keyboard')
  assert.equal(Model.eventKeyboardName('hl-virtual-keyboard,English (US)'), '')
  assert.equal(Model.keyboardShort('English (US)'), 'ENG')
  assert.equal(Model.keyboardShort('Norwegian'), 'NOR')
  assert.equal(Model.keyboardShort(''), '')
})

test('video backgrounds: the screen size and the probe reply', () => {
  assert.deepEqual(Model.videoScreenSize([{width: 3440, height: 1440, transform: 0}, {width: 1920, height: 1080, transform: 1}], []), [3440, 1440])
  // A turned screen swaps its mode; the larger by area wins.
  assert.deepEqual(Model.videoScreenSize([{width: 3840, height: 2160, transform: 3}, {width: 1920, height: 1080}], []), [2160, 3840])
  assert.deepEqual(Model.videoScreenSize([], [{width: 2752, height: 1152}, {width: 800, height: 600}]), [2752, 1152])
  assert.deepEqual(Model.videoScreenSize([{width: 0, height: 0}], [{width: 1280, height: 720}]), [1280, 720])
  assert.deepEqual(Model.videoScreenSize(null, null), [1920, 1080])
  assert.deepEqual(Model.videoScreenSize([{width: 10240, height: 4320}], []), [7680, 4320])
  const dir = '/c/omarchy/foamy.lock/video/'
  const hash = 'ab'.repeat(32)
  const reply = (extra) => JSON.stringify(Object.assign({ok: true, poster: dir + hash + '.png', clip: dir + hash + '-3440x1440.mp4',
    output: {width: 3440, height: 1440}}, extra))
  const good = Model.videoProbeResult('{"progress":{}}\n' + reply({}), dir)
  assert.deepEqual([good.ok, good.poster, good.clip], [true, dir + hash + '.png', dir + hash + '-3440x1440.mp4'])
  // Outside the cache, misnamed, or for another size: not taken.
  for (const extra of [{poster: '/tmp/' + hash + '.png'}, {poster: dir + '../' + hash + '.png'}, {poster: dir + hash + '.jpg'}, {poster: 5}])
    assert.equal(Model.videoProbeResult(reply(extra), dir).poster, '', JSON.stringify(extra))
  for (const extra of [{clip: dir + hash + '-1920x1080.mp4'}, {clip: '/tmp/' + hash + '-3440x1440.mp4'}, {clip: dir + hash + '.mp4'},
    {clip: null}, {output: null}, {clip: dir + 'x' + hash.slice(1) + '-3440x1440.mp4'}])
    assert.equal(Model.videoProbeResult(reply(extra), dir).clip, '', JSON.stringify(extra))
  assert.deepEqual(Model.videoProbeResult('{"ok":false,"error":"decode-failed"}', dir), {ok: false, error: 'decode-failed', poster: '', clip: '', reply: null})
  assert.equal(Model.videoProbeResult('nonsense', dir).error, 'video-helper-failed')
  assert.equal(Model.videoProbeResult('{"ok":false,"error":"Bad Code"}', dir).error, 'video-helper-failed')
})
