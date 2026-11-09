// The drawn backgrounds (elements/Backdrop.qml): every animation Layout.js
// lists has its shader, compiled, with the shared uniform block; the CPU
// still frame's hash is the shaders' bit for bit; older names still load.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const Layout = require('../Layout.js');

const shaders = path.join(__dirname, '..', 'elements', 'shaders');
const read = file => fs.readFileSync(path.join(shaders, file), 'utf8');

test('every animation has a compiled shader that includes the shared block', () => {
  assert.ok(fs.existsSync(path.join(shaders, 'backdrop.vert.qsb')));
  assert.match(read('backdrop.vert'), /#include "common.glsl"/);
  for (const name of Layout.DRAWN_SOURCES) {
    const source = read(name + '.frag');
    assert.match(source, /#include "common.glsl"/, name);
    assert.ok(!/uniform\s+buf/.test(source), name + ' declares the block only through common.glsl');
    const baked = fs.readFileSync(path.join(shaders, name + '.frag.qsb'));
    assert.ok(baked.length > 0, name + '.frag.qsb');
  }
  // No other fragment shaders lie around.
  const frags = fs.readdirSync(shaders).filter(f => f.endsWith('.frag')).map(f => f.slice(0, -5)).sort();
  assert.deepEqual(frags, [...Layout.DRAWN_SOURCES].sort());
});

test('the uniforms Backdrop sets are the block\'s', () => {
  const block = read('common.glsl').match(/uniform buf \{([^}]*)\}/)[1];
  const names = [...block.matchAll(/\b(u_\w+);/g)].map(m => m[1]).sort();
  const qml = fs.readFileSync(path.join(__dirname, '..', 'elements', 'Backdrop.qml'), 'utf8');
  const set = [...qml.matchAll(/property \w+ (u_\w+):/g)].map(m => m[1]).sort();
  assert.deepEqual(set, names);
});

test('the still frame hashes like the shaders', () => {
  // BackdropStill.js is a QML JavaScript library: read it as a script.
  const file = path.join(__dirname, '..', 'elements', 'BackdropStill.js');
  const code = fs.readFileSync(file, 'utf8').replace(/^\.pragma library\n/, '');
  const still = new Function(code + '\nreturn { hash: hash, lowbias: lowbias, FIELDS: FIELDS, POINTS: POINTS }')();
  // Reference values from hash.glsl's integer math (lowbias32).
  assert.equal(still.lowbias(1), 1753845952);
  assert.equal(still.hash(0, 0, 300), 3992989 / 16777216);
  assert.equal(still.hash(-1, 5, 41), 7083328 / 16777216);
  for (const name of Layout.DRAWN_SOURCES) assert.ok(still.FIELDS[name], name + ' has a still field');
});

test('older names of animations still load, as the new one', () => {
  assert.equal(Layout.drawnSource('constellation'), 'stars');
  assert.equal(Layout.drawnSource('color'), '');
  for (const name of Layout.DRAWN_SOURCES) assert.equal(Layout.drawnSource(name), name);
  const old = Layout.parseLook({background: {source: 'constellation'}});
  assert.ok(old.valid);
  assert.equal(old.look.background.source, 'stars');
  assert.deepEqual(Layout.canonical(old.look), Layout.canonical(Layout.parseLook({background: {source: 'stars'}}).look));
  assert.equal(Layout.preset('constellation').background.source, 'stars');
});
