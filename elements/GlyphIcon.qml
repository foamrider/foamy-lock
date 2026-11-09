import QtQuick

// A Nerd Font icon placed by its ink, not its advance. The mono icon font's
// glyphs are one cell wide (about 0.6 em) but most draw past the cell, the
// Wi-Fi and wired ones to twice its width, so a Text centred or laid out by
// its advance pushes the icon into whatever follows it. The implicit width is
// the drawn width, and the glyph is centred in whatever width it is given.
Item {
  id: glyph

  property alias text: label.text
  property alias color: label.color
  property alias font: label.font
  readonly property rect ink: metrics.tightBoundingRect

  implicitWidth: Math.ceil(ink.width)
  implicitHeight: label.implicitHeight

  TextMetrics {
    id: metrics
    font: label.font
    text: label.text
  }

  Text {
    id: label
    textFormat: Text.PlainText
    x: Math.round((glyph.width - glyph.ink.width) / 2 - glyph.ink.x)
    height: glyph.height
    verticalAlignment: Text.AlignVCenter
  }
}
