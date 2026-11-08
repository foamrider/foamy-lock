pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit"
import "Layout.js" as LockLayout
import "Draft.js" as Draft

// The scene pages in the inspector pane (Library → Scene):
// - "background": the source (Wallpaper, Custom image, the
//   theme colour, black or a drawn scene), the picture, the blur and the
//   decoration (drawn tiles);
// - "glass": the dim, and the glass's opacity and tint;
// - "look": both, for the look as a whole (nothing is selected: a click
//   beside the lock on the canvas, or Esc).
// Values are the lock's 0–1 amounts shown as percentages, within its
// ranges. Every change is one Draft edit through the window (`app`);
// slider drags show live and commit once.
FocusScope {
  id: scene

  // The StudioWindow: draft, look, commit(), preview(), sources.
  property var app: null
  property string page: "background"
  readonly property bool backgroundShown: page === "background" || page === "look"
  readonly property bool glassShown: page === "glass" || page === "look"
  readonly property string title: page === "look" ? FoamyI18n.t("studio.look")
    : page === "glass" ? FoamyI18n.t("studio.glassDim") : FoamyI18n.t("studio.background")

  readonly property var look: app ? app.look : LockLayout.defaults()
  readonly property var background: look.background
  readonly property var sources: app ? app.sources : null
  readonly property bool pictureChosen: background.path !== undefined && background.path !== ""

  Accessible.role: Accessible.Pane
  Accessible.name: title

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
    if (background.source !== "picture" || sources.pictureIsVideo || !sources.pictureError) return ""
    if (sources.pictureError === "helper-unavailable") return FoamyI18n.t("studio.helperUnavailable")
    if (sources.pictureError === "background-missing") return FoamyI18n.t("studio.picture.missing")
    return FoamyI18n.t("studio.picture.failed", sources.pictureError)
  }

  // --- the video card -----------------------------------------------------
  // The video the canvas shows (a picture source's, or a video Omarchy
  // wallpaper), from the helper's probe: facts, what converting makes of it,
  // the estimate, Convert or its progress and Cancel, the clip once ready,
  // and the motion. Nothing converts until Convert is pressed.
  readonly property bool videoShown: !!sources && sources.clipSource !== ""
  readonly property var probeReply: sources && sources.videoProbe && sources.videoProbeKey === sources.clipKey
    ? sources.videoProbe.reply : null
  readonly property var card: !sources ? null : Draft.videoCard(sources.videoProbeKey === sources.clipKey ? sources.videoProbe : null,
    sources.converting && sources.convertKey === sources.clipKey, sources.clip)
  readonly property string cardState: card ? card.state : "checking"
  readonly property string motion: background.motion === "play" ? "play" : "still"
  // Play can be chosen once there is a clip; a saved Play can always go back.
  readonly property bool motionEnabled: cardState === "ready" || motion === "play"

  function lengthText(seconds) {
    var length = Draft.duration(seconds)
    if (!length) return ""
    return length.minutes > 0 ? FoamyI18n.t("studio.video.minutes", [length.minutes, length.seconds])
      : FoamyI18n.t("studio.video.seconds", length.seconds)
  }
  function sizeText(bytes) {
    var size = Draft.megabytes(bytes)
    return FoamyI18n.t("studio.video.megabytes", FoamyI18n.number(size.value, size.decimals))
  }
  function rateText(fps) {
    var value = Number(fps) || 0
    return FoamyI18n.number(value, Math.abs(value - Math.round(value)) < 0.005 ? 0 : 2)
  }
  // "4 min 12 s · 3840 × 2160 · HEVC · 412 MB" (only the size over 2 GiB).
  function factsText() {
    var reply = probeReply
    if (!reply) return cardState === "checking" ? FoamyI18n.t("studio.video.checking") : ""
    if (reply.codec === null) return sizeText(reply.bytes)
    var parts = []
    var length = lengthText(reply.duration)
    if (length) parts.push(length)
    parts.push(FoamyI18n.t("studio.video.size", [reply.width, reply.height]))
    parts.push(Draft.codecLabel(reply.codec))
    parts.push(sizeText(reply.bytes))
    return parts.join(" · ")
  }
  // What converting makes of it.
  function planText() {
    var output = probeReply ? probeReply.output : null
    if (!output || cardState === "limit") return ""
    return output.cut ? FoamyI18n.t("studio.video.planCut", [60, output.width, output.height, rateText(output.fps)])
      : FoamyI18n.t("studio.video.plan", [output.width, output.height, rateText(output.fps)])
  }
  function estimateText() {
    return probeReply && typeof probeReply.estimate === "number"
      ? FoamyI18n.t("studio.video.estimate", lengthText(probeReply.estimate)) : ""
  }
  // Why it can't be converted or played, or how the last conversion ended.
  function videoProblem() {
    if (!sources || !card) return ""
    var code = card.code
    if (cardState === "limit") {
      if (code === "unsupported-codec") return FoamyI18n.t("studio.video.limit.unsupported-codec", Draft.codecLabel(probeReply ? probeReply.codec : ""))
      if (["input-too-large", "input-too-wide"].indexOf(code) !== -1) return FoamyI18n.t("studio.video.limit." + code)
      return FoamyI18n.t("studio.video.problem", code)
    }
    if (cardState === "problem") {
      if (code === "helper-unavailable") return FoamyI18n.t("studio.helperUnavailable")
      if (["decode-failed", "unsupported-format", "video-missing", "decoder-unavailable"].indexOf(code) !== -1)
        return FoamyI18n.t("studio.video.problem." + code)
      return FoamyI18n.t("studio.video.problem", code)
    }
    var failed = sources.convertKey === sources.clipKey && !sources.converting ? sources.convertError : ""
    if (!failed) return ""
    if (failed === "cancelled") return FoamyI18n.t("studio.video.cancelled")
    if (failed === "helper-unavailable") return FoamyI18n.t("studio.helperUnavailable")
    if (["busy", "job-timeout", "output-too-large"].indexOf(failed) !== -1) return FoamyI18n.t("studio.video.failed." + failed)
    return FoamyI18n.t("studio.video.failed", failed)
  }

  // The picture's state in words.
  function pictureStatus() {
    if (!sources) return ""
    if (sources.picking) return FoamyI18n.t("studio.picture.choosing")
    // A video's state is on its card.
    if (sources.pictureIsVideo) return ""
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
        objectName: "studioScenePageTitle"
        textFormat: Text.PlainText
        width: parent.width
        text: scene.title
        horizontalAlignment: Text.AlignLeft
        color: FoamyPalette.text
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.heading
        font.weight: Font.DemiBold
        Accessible.role: Accessible.Heading
        Accessible.name: text
      }

      PaneNote {
        visible: scene.page === "look"
        text: FoamyI18n.t("studio.lookHint")
      }

      // --- background -------------------------------------------------------
      Column {
        objectName: "studioSceneBackgroundSection"
        width: parent.width
        spacing: FoamyStyle.gap
        visible: scene.backgroundShown

        SectionLabel {
          visible: scene.page === "look"
          text: FoamyI18n.t("studio.background")
          topPadding: FoamyStyle.gap
        }

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
              focus: index === 0 && scene.backgroundShown
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
          FoamyButton {
            objectName: "studioChoosePicture"
            focusable: true
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

        // --- the video card -------------------------------------------------
        Column {
          id: videoCard
          objectName: "studioVideoCard"
          width: parent.width
          spacing: FoamyStyle.gapSmall
          visible: scene.videoShown

          SectionLabel {
            text: FoamyI18n.t("studio.video")
            topPadding: FoamyStyle.gap
          }
          RowLayout {
            width: parent.width
            spacing: FoamyStyle.gap
            Rectangle {
              Layout.preferredWidth: 112
              Layout.preferredHeight: 63
              Layout.alignment: Qt.AlignTop
              radius: FoamyStyle.radiusSmall
              color: FoamyPalette.fieldFill
              clip: true
              Image {
                id: videoPoster
                objectName: "studioVideoPoster"
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 224
                sourceSize.height: 126
                readonly property string path: scene.sources && scene.sources.videoProbe && scene.sources.videoProbeKey === scene.sources.clipKey
                  ? scene.sources.videoProbe.poster : ""
                source: path ? "file://" + path.split("/").map(encodeURIComponent).join("/") : ""
                Accessible.role: Accessible.Graphic
                Accessible.name: FoamyI18n.t("studio.video.poster")
              }
            }
            Column {
              Layout.fillWidth: true
              spacing: FoamyStyle.gapTiny
              PaneNote {
                objectName: "studioVideoFacts"
                width: parent.width
                text: scene.factsText()
              }
              PaneNote {
                objectName: "studioVideoPlan"
                width: parent.width
                color: FoamyPalette.secondaryText
                text: scene.planText()
              }
            }
          }
          PaneNote {
            objectName: "studioVideoProblem"
            color: FoamyPalette.onSurface(FoamyPalette.error)
            text: scene.videoProblem()
            Accessible.role: Accessible.AlertMessage
          }
          PaneNote {
            objectName: "studioVideoEstimate"
            visible: scene.cardState === "convertible"
            text: scene.estimateText() + " " + FoamyI18n.t("studio.video.why")
          }
          RowLayout {
            width: parent.width
            spacing: FoamyStyle.gap
            FoamyButton {
              objectName: "studioVideoConvert"
              focusable: true
              kind: "primary"
              visible: ["converting", "ready"].indexOf(scene.cardState) === -1
              text: FoamyI18n.t("studio.video.convert")
              enabled: scene.cardState === "convertible" && !scene.sources.converting
              onClicked: scene.sources.convertVideo()
            }
            FoamyButton {
              objectName: "studioVideoCancel"
              focusable: true
              visible: scene.cardState === "converting"
              text: FoamyI18n.t("studio.video.cancel")
              onClicked: scene.sources.cancelConvert()
            }
            PaneNote {
              objectName: "studioVideoReady"
              Layout.fillWidth: true
              visible: scene.cardState === "ready"
              text: visible ? FoamyI18n.t("studio.video.ready", scene.sizeText(scene.sources.clipBytes)) : ""
            }
            PaneNote {
              objectName: "studioVideoProgressText"
              Layout.fillWidth: true
              visible: scene.cardState === "converting"
              readonly property var progress: scene.sources ? scene.sources.convertProgress : null
              text: !visible ? "" : progress ? FoamyI18n.t("studio.video.converting", [FoamyI18n.number(progress.frames, 0), FoamyI18n.number(progress.total, 0)])
                : FoamyI18n.t("studio.video.starting")
            }
          }
          // The frames done out of the total.
          Rectangle {
            id: progressTrack
            objectName: "studioVideoProgress"
            width: parent.width
            height: 6
            radius: height / 2
            visible: scene.cardState === "converting"
            color: FoamyPalette.fieldFill
            readonly property real fraction: scene.sources && scene.sources.convertProgress ? scene.sources.convertProgress.fraction : 0
            Accessible.role: Accessible.ProgressBar
            Accessible.name: FoamyI18n.t("studio.video.progress")
            Rectangle {
              objectName: "studioVideoProgressFill"
              // Start to end in either direction.
              x: LayoutMirroring.enabled ? parent.width - width : 0
              width: Math.round(parent.width * progressTrack.fraction)
              height: parent.height
              radius: parent.radius
              color: FoamyPalette.accent
            }
          }
          SectionLabel {
            text: FoamyI18n.t("studio.motion")
            topPadding: FoamyStyle.gapSmall
          }
          // Its own row: "Play (experimental)" is long in some languages.
          Segmented {
            objectName: "studioMotion"
            name: FoamyI18n.t("studio.motion")
            enabled: scene.motionEnabled
            opacity: enabled ? 1 : FoamyStyle.disabledOpacity
            options: LockLayout.MOTIONS.map(function(m) { return { value: m, label: FoamyI18n.t("studio.motion." + m) } })
            value: scene.motion
            onPicked: function(value) { scene.commit(Draft.setBackground(scene.app.draft, "motion", value)) }
          }
          PaneNote {
            objectName: "studioMotionNote"
            text: scene.motionEnabled ? FoamyI18n.t("studio.motion.hint") : FoamyI18n.t("studio.motion.needsClip")
          }
          StudioToggle {
            objectName: "studioPauseOnBattery"
            width: parent.width
            visible: scene.motion === "play"
            text: FoamyI18n.t("studio.pauseOnBattery")
            checked: scene.background.pauseOnBattery !== false
            onToggled: scene.commit(Draft.setBackground(scene.app.draft, "pauseOnBattery", !checked))
          }
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
          visible: scene.background.source === "omarchy" || (scene.sources !== null && scene.sources.pictureIsVideo)
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
        objectName: "studioSceneGlassSection"
        width: parent.width
        spacing: FoamyStyle.gap
        visible: scene.glassShown

        SectionLabel {
          visible: scene.page === "look"
          text: FoamyI18n.t("studio.glassDim")
          topPadding: FoamyStyle.sectionGap
        }

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
            textFormat: Text.PlainText
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
