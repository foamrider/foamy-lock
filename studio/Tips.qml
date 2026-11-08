pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit"

// The tips card, pinned to the bottom edge of the library pane (the module
// list scrolls above it): one tip at a time, previous and next (wrapping),
// and an action where a tip has one. The first tip is about the picture
// and name the lock shows, which come from the account (AccountsService
// and ~/.face, what Mugshot writes): "Open Mugshot" starts it, and without
// Mugshot installed the tip says how to install it instead. The tip seen
// last is kept in the app's state (LockSources.setTip), so the next start
// shows it again.
//
// Tips about features still to come (the keyboard layout in the status)
// join the list with those features.
Rectangle {
  id: tips

  // LockSources: tip, setTip(), mugshotAvailable, openMugshot().
  property var sources: null
  readonly property var ids: ["mugshot", "library", "drag", "keys", "look", "presets", "preview", "shortcuts"]
  readonly property string current: sources && ids.indexOf(sources.tip) !== -1 ? sources.tip : ids[0]
  readonly property int index: Math.max(0, ids.indexOf(current))
  readonly property bool mugshotShown: current === "mugshot" && sources !== null && sources.mugshotAvailable
  readonly property string text: tipText(current)

  implicitHeight: column.implicitHeight + 2 * FoamyStyle.gapLarge
  color: FoamyPalette.menuFill

  Accessible.role: Accessible.Grouping
  Accessible.name: FoamyI18n.t("studio.tips")

  function tipText(id) {
    if (id === "mugshot" && !(sources && sources.mugshotAvailable)) return FoamyI18n.t("studio.tip.mugshotMissing")
    return FoamyI18n.t("studio.tip." + id)
  }

  // The tip `step` away from this one (wrapping), remembered.
  function go(step) {
    var count = ids.length
    if (sources) sources.setTip(ids[((index + step) % count + count) % count])
  }

  // The hairline between it and the list.
  Rectangle {
    width: parent.width
    height: 1
    color: FoamyPalette.divider
  }

  Column {
    id: column
    x: FoamyStyle.gapLarge
    y: FoamyStyle.gapLarge
    width: parent.width - 2 * FoamyStyle.gapLarge
    spacing: FoamyStyle.gap

    RowLayout {
      width: parent.width
      spacing: FoamyStyle.gapSmall

      // Sized by the layout, not by its picture (whose size follows its own).
      FoamyIcon {
        name: "info"
        color: FoamyPalette.accent
        Layout.preferredWidth: FoamyStyle.iconSize
        Layout.preferredHeight: FoamyStyle.iconSize
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        Layout.fillWidth: true
        text: FoamyI18n.t("studio.tip")
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.mutedText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.caption
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        elide: Text.ElideRight
        Accessible.role: Accessible.Heading
        Accessible.name: text
      }
      Text {
        objectName: "studioTipCount"
        text: FoamyI18n.t("studio.tip.count", [FoamyI18n.number(tips.index + 1, 0), FoamyI18n.number(tips.ids.length, 0)])
        color: FoamyPalette.mutedText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.caption
      }
      IconButton {
        objectName: "studioTipPrevious"
        implicitWidth: FoamyStyle.actionSize
        implicitHeight: FoamyStyle.actionSize
        icon: "chevron-left"
        name: FoamyI18n.t("studio.tip.previous")
        onClicked: tips.go(-1)
      }
      IconButton {
        objectName: "studioTipNext"
        implicitWidth: FoamyStyle.actionSize
        implicitHeight: FoamyStyle.actionSize
        icon: "chevron-right"
        name: FoamyI18n.t("studio.tip.next")
        onClicked: tips.go(1)
      }
    }

    // Every tip is laid out, the others transparent, so the card keeps the
    // height of the longest and the list above doesn't move when paging.
    Item {
      id: tipBox
      width: parent.width
      height: childrenRect.height

      Repeater {
        model: tips.ids
        Text {
          required property string modelData
          readonly property bool shown: modelData === tips.current
          objectName: shown ? "studioTipText" : ""
          width: tipBox.width
          opacity: shown ? 1 : 0
          text: tips.tipText(modelData)
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.Wrap
          color: FoamyPalette.secondaryText
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.bodySmall
          Accessible.role: Accessible.StaticText
          Accessible.name: text
          Accessible.ignored: !shown
        }
      }
    }

    FoamyButton {
      objectName: "studioTipAction"
      visible: tips.mugshotShown
      focusable: true
      iconName: "external-link"
      text: FoamyI18n.t("studio.tip.mugshotOpen")
      onClicked: tips.sources.openMugshot()
    }
    PaneNote {
      visible: tips.mugshotShown && tips.sources.mugshotFailed
      text: FoamyI18n.t("studio.tip.mugshotFailed")
      color: FoamyPalette.onSurface(FoamyPalette.error)
      Accessible.role: Accessible.AlertMessage
    }
  }
}
