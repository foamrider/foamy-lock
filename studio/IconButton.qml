import QtQuick
import "kit"

// An icon-only button: the kit's FoamyButton (secondary, in the Tab chain)
// with an icon and no label. `name` is its accessible name and tooltip,
// with `keys` (a shortcut) after it in the tooltip and as its description.
// `flipped` turns the icon around (the redo arrow is the undo arrow
// mirrored; the kit has no redo icon), on top of the kit's own mirroring
// of directional icons right to left.
FoamyButton {
  id: button

  property string icon: ""
  property string name: ""
  property string keys: ""
  property bool flipped: false

  focusable: true
  implicitWidth: FoamyStyle.controlHeight
  implicitHeight: FoamyStyle.controlHeight
  tooltipText: keys !== "" ? FoamyI18n.t("studio.withKeys", [name, keys]) : name
  Accessible.name: name
  Accessible.description: keys

  FoamyIcon {
    id: glyph
    anchors.centerIn: parent
    width: FoamyStyle.iconSize
    height: width
    name: button.icon
    color: button.foreground
    mirror: (FoamyI18n.rightToLeft && glyph.directional.indexOf(glyph.name) !== -1) !== button.flipped
  }
}
