pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit"
import "Layout.js" as LockLayout
import "Draft.js" as Draft

// The scene pages in the inspector pane (Library → Scene):
// - "background": the source (the Omarchy wallpaper, your picture, the
//   theme colour, black or a drawn scene), the picture, the blur and the
//   decoration (drawn tiles);
// - "glass": the dim, and the glass's opacity and tint.
// Values are the lock's 0–1 amounts shown as percentages, within its
// ranges. Every change is one Draft edit through the window (`app`);
// slider drags show live and commit once.
FocusScope {
  id: scene

  // The StudioWindow: draft, look, commit(), preview(), sources.
  property var app: null
  property string page: "background"

  readonly property var look: app ? app.look : LockLayout.defaults()
  readonly property var background: look.background
  readonly property var sources: app ? app.sources : null
  readonly property bool pictureChosen: background.path !== undefined && background.path !== ""

  Accessible.role: Accessible.Pane
  Accessible.name: page === "glass" ? FoamyI18n.t("studio.glassDim") : FoamyI18n.t("studio.background")

  function commit(next) { app.commit(next) }
  function preview(next) { app.preview(next) }
  function percent(value) { return FoamyI18n.t("studio.percent", Math.round(value * 100)) }

  // A source chosen: the picture without a path asks for one first.
  function chooseSource(source) {
    if (source === "picture" && !pictureChosen) sources.pick()
    else if (source === "picture") commit(Draft.setPicture(app.draft, background.path))
    else commit(Draft.setBackground(app.draft, "source", source))
  }

  // What went wrong with the picture, in words ("" when nothing did).
  function pictureProblem() {
    if (!sources) return ""
    if (sources.pickError) {
      if (sources.pickError === "helper-unavailable") return FoamyI18n.t("studio.helperUnavailable")
      const known = ["NO_SESSION_BUS", "PORTAL_UNAVAILABLE", "PORTAL_FAILED", "UNSUPPORTED"]
      return known.indexOf(sources.pickError) !== -1 ? FoamyI18n.t("studio.pick." + sources.pickError)
        : FoamyI18n.t("studio.pick.failed", sources.pickError)
    }
    if (background.source !== "picture" || !sources.pictureError) return ""
    if (sources.pictureError === "helper-unavailable") return FoamyI18n.t("studio.helperUnavailable")
    if (sources.pictureError === "background-missing") return FoamyI18n.t("studio.picture.missing")
    return FoamyI18n.t("studio.picture.failed", sources.pictureError)
  }

  // The picture's state in words.
  function pictureStatus() {
    if (!sources) return ""
    if (sources.picking) return FoamyI18n.t("studio.picture.choosing")
    if (background.source !== "picture") return pictureChosen ? FoamyI18n.t("studio.picture.notShown") : ""
    if (sources.preparing || (sources.pictureSource !== background.path && !sources.pictureError)) return FoamyI18n.t("studio.picture.preparing")
    return ""
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: flick.width
      spacing: FoamyStyle.gap

      Text {
        width: parent.width
        text: scene.page === "glass" ? FoamyI18n.t("studio.glassDim") : FoamyI18n.t("studio.background")
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.text
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.heading
        font.weight: Font.DemiBold
        Accessible.role: Accessible.Heading
        Accessible.name: text
      }

      // --- background -------------------------------------------------------
      Column {
        width: parent.width
        spacing: FoamyStyle.gap
        visible: scene.page === "background"

        SectionLabel {
          text: FoamyI18n.t("studio.source")
          topPadding: FoamyStyle.gapSmall
        }
        Column {
          id: sourceList
          width: parent.width
          spacing: FoamyStyle.gapTiny
          Accessible.role: Accessible.List
          Accessible.name: FoamyI18n.t("studio.source")

          Repeater {
            model: LockLayout.BACKGROUND_SOURCES
            StudioButton {
              required property string modelData
              required property int index
              objectName: "studioSource-" + modelData
              focus: index === 0 && scene.page === "background"
              width: sourceList.width
              horizontalAlignment: Text.AlignLeft
              text: FoamyI18n.t("studio.source." + modelData)
              detail: modelData === "picture" && !scene.pictureChosen ? FoamyI18n.t("studio.picture.choose") : ""
              checked: scene.background.source === modelData
              Accessible.role: Accessible.RadioButton
              Accessible.checkable: true
              onClicked: scene.chooseSource(modelData)
            }
          }
        }

        PaneNote {
          text: LockLayout.DRAWN_SOURCES.indexOf(scene.background.source) !== -1 ? FoamyI18n.t("studio.drawnHint")
            : scene.background.source === "omarchy" && scene.sources && scene.sources.wallpaperError === "video" ? FoamyI18n.t("studio.wallpaperVideo")
            : scene.background.source === "omarchy" && scene.sources && scene.sources.wallpaperIsVideo ? FoamyI18n.t("studio.wallpaperStill")
            : scene.background.source === "omarchy" && scene.sources && scene.sources.wallpaperError !== "" ? FoamyI18n.t("studio.wallpaperMissing")
            : ""
        }

        SectionLabel {
          text: FoamyI18n.t("studio.picture")
          topPadding: FoamyStyle.gap
        }
        PaneNote {
          objectName: "studioPicturePath"
          color: FoamyPalette.secondaryText
          elide: Text.ElideMiddle
          wrapMode: Text.NoWrap
          text: scene.pictureChosen ? scene.background.path : FoamyI18n.t("studio.picture.none")
        }
        RowLayout {
          width: parent.width
          StudioButton {
            objectName: "studioChoosePicture"
            text: FoamyI18n.t("studio.picture.chooseButton")
            enabled: scene.sources !== null && !scene.sources.picking
            onClicked: scene.sources.pick()
          }
          PaneNote {
            Layout.fillWidth: true
            text: scene.pictureStatus()
          }
        }
        PaneNote {
          objectName: "studioPictureProblem"
          color: FoamyPalette.onSurface(FoamyPalette.error)
          text: scene.pictureProblem()
          Accessible.role: Accessible.AlertMessage
        }

        StudioSlider {
          objectName: "studioBlur"
          width: parent.width
          visible: ["omarchy", "picture"].indexOf(scene.background.source) !== -1
          label: FoamyI18n.t("studio.blur")
          from: 0
          to: 1
          stepSize: 0.05
          value: scene.background.blur
          valueText: scene.percent(shown)
          onMoved: function(v) { scene.preview(Draft.setBackground(scene.app.draft, "blur", v)) }
          onCommitted: function(v) { scene.commit(Draft.setBackground(scene.app.draft, "blur", v)) }
        }
        PaneNote {
          visible: scene.background.source === "omarchy"
          text: FoamyI18n.t("studio.blurHint")
        }

        SectionLabel {
          text: FoamyI18n.t("studio.decoration")
          topPadding: FoamyStyle.gap
        }
        PaneNote { text: FoamyI18n.t("studio.decorationHint") }
        StyleTiles {
          objectName: "studioDecor"
          width: parent.width
          element: "decor"
          title: FoamyI18n.t("studio.decoration")
          options: LockLayout.DECORATIONS
          value: scene.background.decor || "none"
          labelFor: function(name) { return FoamyI18n.t("studio.decor." + name) }
          onPicked: function(decor) { scene.commit(Draft.setBackground(scene.app.draft, "decor", decor)) }
        }
      }

      // --- glass and dim ----------------------------------------------------
      Column {
        width: parent.width
        spacing: FoamyStyle.gap
        visible: scene.page === "glass"

        StudioSlider {
          objectName: "studioDim"
          focus: scene.page === "glass"
          width: parent.width
          label: FoamyI18n.t("studio.dim")
          from: Draft.SCENE_LIMITS.dim.min
          to: Draft.SCENE_LIMITS.dim.max
          stepSize: 0.05
          value: scene.background.dim
          valueText: scene.percent(shown)
          onMoved: function(v) { scene.preview(Draft.setBackground(scene.app.draft, "dim", v)) }
          onCommitted: function(v) { scene.commit(Draft.setBackground(scene.app.draft, "dim", v)) }
        }
        PaneNote { text: FoamyI18n.t("studio.dimHint") }

        SectionLabel {
          text: FoamyI18n.t("studio.glass")
          topPadding: FoamyStyle.gap
        }
        PaneNote { text: FoamyI18n.t("studio.glassHint") }
        StudioSlider {
          objectName: "studioGlassOpacity"
          width: parent.width
          label: FoamyI18n.t("studio.opacity")
          from: 0
          to: 1
          stepSize: 0.05
          value: scene.look.glass.opacity
          valueText: scene.percent(shown)
          onMoved: function(v) { scene.preview(Draft.setGlassLook(scene.app.draft, "opacity", v)) }
          onCommitted: function(v) { scene.commit(Draft.setGlassLook(scene.app.draft, "opacity", v)) }
        }
        RowLayout {
          width: parent.width
          Text {
            Layout.fillWidth: true
            text: FoamyI18n.t("studio.tint")
            horizontalAlignment: Text.AlignLeft
            color: FoamyPalette.secondaryText
            font.family: FoamyStyle.fontFamily
            font.pixelSize: FoamyStyle.font.body
          }
          Segmented {
            objectName: "studioTint"
            name: FoamyI18n.t("studio.tint")
            options: LockLayout.GLASS_TINTS.map(function(t) { return { value: t, label: FoamyI18n.t("studio.tint." + t) } })
            value: scene.look.glass.tint || "none"
            onPicked: function(value) { scene.commit(Draft.setGlassLook(scene.app.draft, "tint", value)) }
          }
        }
      }

      Item { width: 1; height: FoamyStyle.gap }
    }
  }
}
