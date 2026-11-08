const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const I = require('./i18n.cjs');
const manifest = require('../manifest.json');
const tokens = s => [...s.matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
// A catalog value: a string, or plural forms ({one, other}).
const forms = value => typeof value === 'string' ? [value] : Object.values(value);
for (const [key, value] of Object.entries(I.en)) {
  // The lock's strings are keyed by their English text; Lock Studio's
  // (studio/) by `studio.*` keys, every one translated.
  if (key.startsWith('studio.')) {
    assert.ok(Object.hasOwn(I.no, key), `no translation: ${key}`);
    assert.equal(typeof I.no[key], typeof value, key);
    for (const form of forms(value)) assert.ok(form.length > 0, key);
    for (const form of forms(I.no[key])) assert.deepEqual(tokens(form), tokens(forms(value)[0]), key);
    continue;
  }
  assert.equal(value, key, `English source key: ${key}`);
  if (Object.hasOwn(I.no, key)) assert.deepEqual(tokens(I.no[key]), tokens(value), key);
}
for (const key of Object.keys(I.no)) if (key.startsWith('studio.')) assert.ok(Object.hasOwn(I.en, key), `only in no.json: ${key}`);
// Every literal studio key the app's QML uses is in the catalogs, and so is
// every key it builds from the lock's names (modules, zones, styles,
// presets, sources).
const studioDir = path.join(__dirname, '../studio');
for (const file of fs.readdirSync(studioDir).filter(name => name.endsWith('.qml'))) {
  const qml = fs.readFileSync(path.join(studioDir, file), 'utf8');
  // A key built with "+" is covered by the list below.
  for (const match of qml.matchAll(/FoamyI18n\.tn?\("(studio\.[^"]+)"(?!\s*\+)/g)) assert.ok(Object.hasOwn(I.en, match[1]), `${file}: ${match[1]}`);
  assert.ok(!/FoamyI18n\.tn?\("(?!studio\.)/.test(qml), `${file}: studio strings use studio.* keys`);
}
const Layout = require('../Layout.js');
const built = [...Layout.ELEMENTS.map(n => 'module.' + n), ...Layout.ZONES.map(z => 'zone.' + z),
  ...[...new Set(Object.values(Layout.STYLES).flat())].map(s => 'style.' + s), ...Layout.SELECTABLE_PRESETS.map(p => 'preset.' + p),
  ...Layout.BACKGROUND_SOURCES.map(s => 'source.' + s), ...Layout.SCREENS.map(s => 'screens.' + s),
  ...['move', 'nudge', 'zone', 'scale', 'hide', 'show', 'select', 'free', 'axis', 'undo', 'redo', 'panes', 'help', 'quit'].flatMap(k => ['key.' + k, 'key.' + k + '.keys']),
  ...['password-overlap', 'password-covered', 'password-offscreen', 'password-high', 'password-missing', 'element-offscreen', 'element-overlap'].map(c => 'problem.' + c),
  ...Layout.DECORATIONS.map(d => 'decor.' + d), ...Layout.GLASS_TINTS.map(t => 'tint.' + t),
  ...['NO_SESSION_BUS', 'PORTAL_UNAVAILABLE', 'PORTAL_FAILED', 'UNSUPPORTED'].map(c => 'pick.' + c),
  // Apply and Preview results (StudioWindow.resultText).
  ...['invalid-json', 'unsupported', 'no-entry', 'unexpected', 'not-ready', 'not-running', 'target-not-found', 'function-not-found',
    'no-omarchy-shell', 'failed', 'locked.apply', 'locked.preview'].map(r => 'result.' + r)];
for (const key of built) assert.ok(Object.hasOwn(I.en, 'studio.' + key), `studio.${key}`);
assert.equal(manifest.barWidget?.defaults?.language, undefined);
assert.equal((manifest.barWidget?.schema || []).some(f => f.key === 'language'), false);
assert.equal(I.text('Unknown %1 {name}', 'no', ['$& %2']), '$& %2 {name}'.replace(/^/, 'Unknown '));
assert.equal(I.text('constructor', 'no'), 'constructor');
const ui = fs.readFileSync(path.join(__dirname, '../kit/FoamyI18n.qml'), 'utf8');
assert.ok(ui.includes('Qt.createQmlObject'), '4.0 must not statically require a 4.5 QML type');

const service = fs.readFileSync(path.join(__dirname, '../Service.qml'), 'utf8');
// The preview overlay holds exclusive keyboard focus, so a key must close it.
assert.match(service, /Keys\.onPressed: function\(event\) \{ root\.previewKeyPressed\(event\) \}/);
assert.ok(!/\bIpcHandler\s*\{/.test(service), 'IPC goes through FoamyIpc');
const artworkQml = fs.readFileSync(path.join(__dirname, '../Artwork.qml'), 'utf8');
// Both jobs run the bundled native helper; the avatar job keeps its outer timeout.
assert.ok(artworkQml.includes('FoamyNative.command(FoamyNative.localPath(Qt.resolvedUrl(".")), "foamy-lock-helper", ["artwork"])'),
  'artwork runs the native helper');
assert.match(service, /\["timeout", "--kill-after=1s", "10s"\]\.concat\(FoamyNative\.command\(\s*FoamyNative\.localPath\(Qt\.resolvedUrl\("\."\)\), "foamy-lock-helper", \["artwork"\]\)\)/,
  'avatar helper is bounded');
assert.ok(!/python3|artwork\.py/.test(artworkQml + service), 'no Python helper remains');
assert.ok(!/exec magick/.test(service), 'no unsandboxed ImageMagick call');
