import QtQuick
import "../kit"

// The preview overlay's banner: says what this is, a look on the screen
// and not a lock, and how to close it. Plain text, in the shell's
// language.
//
// It is sized from its texts' own (unwrapped) widths, never from the column
// that holds them: a column sized by its children, whose width follows the
// column, settles at zero, and the banner then draws as an empty box.
Rectangle {
  id: banner

  // The widest it may be (the screen less its margins); the hint wraps
  // beyond it.
  property real maximumWidth: 640
  readonly property real padding: FoamyStyle.gap * 2
  readonly property alias title: bannerTitle
  readonly property alias hint: bannerHint

  objectName: "previewBanner"
  width: Math.max(0, Math.min(maximumWidth, Math.max(bannerTitle.implicitWidth, bannerHint.implicitWidth) + padding * 2))
  height: bannerColumn.implicitHeight + FoamyStyle.gap * 2
  radius: FoamyStyle.radius
  color: Qt.alpha(FoamyPalette.background, 0.92)
  border.width: 1
  border.color: FoamyPalette.border
  Accessible.role: Accessible.AlertMessage
  Accessible.name: bannerTitle.text + ". " + bannerHint.text

  Column {
    id: bannerColumn
    x: banner.padding
    y: FoamyStyle.gap
    width: Math.max(0, banner.width - banner.padding * 2)
    spacing: Math.round(FoamyStyle.gap / 2)

    Text {
      id: bannerTitle
      objectName: "previewBannerTitle"
      textFormat: Text.PlainText
      width: parent.width
      text: FoamyI18n.t("Preview")
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      color: FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.heading
      font.weight: Font.DemiBold
    }
    Text {
      id: bannerHint
      objectName: "previewBannerHint"
      textFormat: Text.PlainText
      width: parent.width
      text: FoamyI18n.t("Not locked. Any key or click closes the preview.")
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
    }
  }
}
