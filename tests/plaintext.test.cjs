// Lint: every Text in the plugin's QML says `textFormat: Text.PlainText`.
// Text's default, AutoText, renders anything that looks like markup as rich
// text: a file name such as `<img src='data:…'>.png` would make Qt decode
// the image bytes in the lock or Studio process, outside the helper's
// sandbox. So every Text (and Label) sets PlainText as a direct property,
// and no file asks for RichText, StyledText or MarkdownText. An exception
// needs an entry in ALLOWED with the reason.
//
// Checked: every tracked .qml file outside tests/ (kit/ too: foamy-kit's
// components already comply, and a kit change that didn't would fail here
// before it reached the lock). tests/ holds harness scenes that never ship.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')

// { file, contains, reason }: a Text block in `file` whose source contains
// `contains` may go without PlainText. None is needed today.
const ALLOWED = []

function qmlFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue
    const full = path.join(dir, entry.name)
    const rel = path.relative(root, full)
    if (entry.isDirectory()) {
      if (rel === 'tests' || rel === 'target' || rel.endsWith('/target')) continue
      qmlFiles(full, out)
    } else if (entry.name.endsWith('.qml')) {
      out.push(rel)
    }
  }
  return out.sort()
}

// The source with comments, strings and template literals blanked (same
// length, newlines kept), so braces in them don't count.
function blank(source) {
  let out = ''
  let i = 0
  const keep = c => (c === '\n' ? '\n' : ' ')
  while (i < source.length) {
    const c = source[i]
    const next = source[i + 1]
    if (c === '/' && next === '/') {
      while (i < source.length && source[i] !== '\n') { out += ' '; i++ }
    } else if (c === '/' && next === '*') {
      const end = source.indexOf('*/', i + 2)
      const stop = end === -1 ? source.length : end + 2
      while (i < stop) { out += keep(source[i]); i++ }
    } else if (c === '"' || c === "'" || c === '`') {
      out += c
      i++
      while (i < source.length && source[i] !== c) {
        if (source[i] === '\\') { out += ' '; i++ }
        if (i < source.length) { out += keep(source[i]); i++ }
      }
      if (i < source.length) { out += c; i++ }
    } else {
      out += c
      i++
    }
  }
  return out
}

// Every Text/Label object in `source`: its type, line, its own properties
// (depth 1 only, children blanked) and its whole source.
function textBlocks(source) {
  const code = blank(source)
  const blocks = []
  const opener = /(^|[^\w.])((?:[A-Za-z_]\w*\.)?(?:Text|Label))\s*\{/g
  let match
  while ((match = opener.exec(code))) {
    const open = match.index + match[0].length - 1
    let depth = 0
    let own = ''
    let close = code.length
    for (let i = open; i < code.length; i++) {
      const c = code[i]
      if (c === '{') depth++
      else if (c === '}') {
        depth--
        if (depth === 0) { close = i; break }
      }
      if (depth === 1 && c !== '{') own += c
      else if (depth > 1) own += c === '\n' ? '\n' : ' '
    }
    blocks.push({
      type: match[2],
      line: code.slice(0, open).split('\n').length,
      own,
      source: source.slice(open, close + 1),
    })
  }
  return blocks
}

const PLAIN = /(^|[\s;{])textFormat\s*:\s*Text\.PlainText\s*($|[\s;}])/m

function violations(rel) {
  const source = fs.readFileSync(path.join(root, rel), 'utf8')
  const found = []
  for (const block of textBlocks(source)) {
    if (PLAIN.test(block.own)) continue
    const allowed = ALLOWED.find(entry => entry.file === rel && block.source.includes(entry.contains))
    if (allowed) continue
    found.push(`${rel}:${block.line}: ${block.type} without textFormat: Text.PlainText`)
  }
  const code = blank(source)
  const rich = /\b(?:Text|TextEdit)\.(RichText|StyledText|MarkdownText|AutoText)\b/g
  let match
  while ((match = rich.exec(code))) {
    const line = code.slice(0, match.index).split('\n').length
    found.push(`${rel}:${line}: ${match[0]} (only PlainText may be rendered)`)
  }
  return found
}

test('the lint sees Text blocks, their own properties and nothing in strings', () => {
  const sample = [
    'Item {',
    '  // Text { in a comment }',
    '  property string s: "Text { in a string"',
    '  Text { text: "a"; textFormat: Text.PlainText }',
    '  Text {',
    '    id: two',
    '    Rectangle { Text { textFormat: Text.PlainText } }',
    '  }',
    '  component Note: Text {',
    '    textFormat: Text.PlainText',
    '  }',
    '  Controls.Label { text: "x" }',
    '  TextMetrics { text: "m" }',
    '}',
  ].join('\n')
  const blocks = textBlocks(sample)
  assert.deepEqual(blocks.map(b => [b.type, b.line, PLAIN.test(b.own)]), [
    ['Text', 4, true],
    ['Text', 5, false], // its child's PlainText isn't its own
    ['Text', 7, true],
    ['Text', 9, true],
    ['Controls.Label', 12, false],
  ])
  assert.ok(!PLAIN.test('textFormat: Text.PlainTextX'))
  assert.ok(!PLAIN.test('textFormat: rich ? Text.RichText : Text.PlainText'))
})

test('every Text and Label in the plugin is PlainText', () => {
  const files = qmlFiles(root)
  for (const expected of ['LockView.qml', 'studio/StudioWindow.qml', 'studio/PaneNote.qml',
    'studio/SectionLabel.qml', 'elements/ClockElement.qml', 'kit/FoamyButton.qml']) {
    assert.ok(files.includes(expected), `${expected} is checked`)
  }
  assert.ok(!files.some(file => file.startsWith('tests/')))
  const found = files.flatMap(violations)
  assert.deepEqual(found, [], `Text without PlainText:\n${found.join('\n')}`)
  let blocks = 0
  for (const file of files) blocks += textBlocks(fs.readFileSync(path.join(root, file), 'utf8')).length
  assert.ok(blocks > 100, `only ${blocks} Text blocks found: the lint lost them`)
})
