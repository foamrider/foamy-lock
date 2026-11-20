pragma Singleton
import QtQuick

// The login screen's colours: the snapshot's `colors` (Commons.Color and
// FoamyPalette's values as the lock read them when the look was copied).
// Main.qml sets `colors`; a key that is missing or not "#rrggbb" or
// "#aarrggbb" takes its value from `fallback`, Omarchy's default theme
// (Tokyo Night), so a snapshot that doesn't parse still draws the login
// screen. foamy-kit's FoamyPalette reads Commons.Color and the theme's
// colors.toml, which the greeter can't reach.
QtObject {
  id: root

  property var colors: ({})
  readonly property var fallback: ({
      background: "#1a1b26",
      foreground: "#a9b1d6",
      accent: "#7aa2f7",
      muted: "#444b6a",
      urgent: "#f7768e",
      lockBackground: "#1a1b26",
      lockBorder: "#a9b1d6",
      lockBorderError: "#f7768e",
      lockPlaceholder: "#a9b1d6",
      lockSelection: "#7aa2f7",
      lockText: "#a9b1d6",
      lockTextError: "#f7768e",
      popupsBackground: "#1a1b26",
      popupsBorder: "#a9b1d6",
      popupsText: "#a9b1d6",
      warning: "#e0af68",
      success: "#9ece6a",
      error: "#f7768e",
      info: "#7dcfff"
    })

  // The colour stored under `key` (a snapshot colour key).
  function pick(key) {
    var value = root.colors ? root.colors[key] : undefined
    if (typeof value === "string" && /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value))
      return value
    return root.fallback[key]
  }

  // FoamyPalette's members that the lock's elements read.
  readonly property color background: pick("popupsBackground")
  readonly property color text: pick("popupsText")
  readonly property color border: pick("popupsBorder")
  readonly property color accent: pick("accent")
  readonly property color urgent: pick("urgent")
  readonly property color warning: pick("warning")
  readonly property color success: pick("success")
  readonly property color error: pick("error")
  readonly property color info: pick("info")
}
