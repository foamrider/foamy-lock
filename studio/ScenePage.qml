pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons as Commons
import "kit"
import "Layout.js" as LockLayout
import "Draft.js" as Draft

// The scene pages in the inspector pane (Library → Scene):
// - "background": the source (Wallpaper, Custom image, Solid colour or
//   Animation), then what that source needs: the image (picture or video),
//   the colour (theme swatches and a #rrggbb field) or the animation (tiles
//   drawn by the lock's own code, one per Layout.DRAWN_SOURCES); then the
//   blur;
// - "glass": the dim (in 1 % steps), and the glass's opacity and tint;
// - "shapes": the look's shapes in drawing order (select, move up or
//   down, remove), Add shape (the templates' drawings, and a box around
//   the selected module), and the selected shape's keys: what it wraps,
//   its shape (padding, corners, width, edge, size, inset, style), fill,
//   border and whether it is the background of the modules inside;
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
    : page === "glass" ? FoamyI18n.t("studio.glassDim")
    : page === "shapes" ? FoamyI18n.t("studio.shapes") : FoamyI18n.t("studio.background")

  readonly property var look: app ? app.look : LockLayout.defaults()
  readonly property var background: look.background
  readonly property var sources: app ? app.sources : null
  readonly property bool pictureChosen: background.path !== undefined && background.path !== ""
  // Wallpaper, Custom image, Solid colour or Animation (Draft.SOURCE_CHOICES).
  readonly property string choice: Draft.sourceChoice(background.source)
  // The solid colour shown: a theme colour's name or "#rrggbb".
  readonly property string colorValue: LockLayout.solidColor(background) || LockLayout.BACKGROUND_DEFAULTS.color
  // The swatches: the theme's colours by name, then black.
  readonly property var swatches: LockLayout.THEME_COLORS.concat([LockLayout.BLACK])

  Accessible.role: Accessible.Pane
  Accessible.name: title

  function commit(next) { app.commit(next) }
  function preview(next) { app.preview(next) }
  function percent(value) { return FoamyI18n.t("studio.percent", Math.round(value * 100)) }

  // A source chosen: the picture without a path asks for one first.
  function chooseSource(choice) {
    if (choice === "picture" && !pictureChosen) sources.pick()
    else if (choice === "picture") commit(Draft.setPicture(app.draft, background.path))
    else commit(Draft.chooseSource(app.draft, choice))
  }

  // A swatch's colour on screen, and its name.
  function swatchColor(value) {
    if (value === "background") return Commons.Color.background
    if (value === "accent") return Commons.Color.accent
    if (value === "muted") return Commons.Color.muted
    if (value === "urgent") return Commons.Color.urgent
    return value
  }
  function swatchName(value) {
    return value === LockLayout.BLACK ? FoamyI18n.t("studio.color.black") : FoamyI18n.t("studio.color." + value)
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
    if (background.source !== "picture") return ""
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
            model: Draft.SOURCE_CHOICES
            StudioButton {
              required property string modelData
              required property int index
              objectName: "studioSource-" + modelData
              focus: index === 0 && scene.backgroundShown
              width: sourceList.width
              horizontalAlignment: Text.AlignLeft
              text: FoamyI18n.t("studio.source." + modelData)
              detail: modelData === "picture" && !scene.pictureChosen ? FoamyI18n.t("studio.picture.choose") : ""
              checked: scene.choice === modelData
              Accessible.role: Accessible.RadioButton
              Accessible.checkable: true
              onClicked: scene.chooseSource(modelData)
            }
          }
        }

        // Only what would surprise: a wallpaper the canvas can't show.
        PaneNote {
          objectName: "studioWallpaperNote"
          text: scene.choice !== "omarchy" || !scene.sources ? ""
            : scene.sources.wallpaperError === "video" ? FoamyI18n.t("studio.wallpaperVideo")
            : scene.sources.wallpaperError !== "" ? FoamyI18n.t("studio.wallpaperMissing")
            : ""
        }

        // --- the image (Custom image) -------------------------------------
        Column {
          objectName: "studioImageSection"
          width: parent.width
          spacing: FoamyStyle.gap
          visible: scene.choice === "picture"

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
        }
        // Outside the section: a chooser that failed says so whatever the
        // source (the chooser can open from the source list too).
        PaneNote {
          objectName: "studioPictureProblem"
          color: FoamyPalette.onSurface(FoamyPalette.error)
          text: scene.pictureProblem()
          Accessible.role: Accessible.AlertMessage
        }

        // --- the colour (Solid colour) -------------------------------------
        Column {
          objectName: "studioColorSection"
          width: parent.width
          spacing: FoamyStyle.gap
          visible: scene.choice === "color"

          SectionLabel {
            text: FoamyI18n.t("studio.color")
            topPadding: FoamyStyle.gap
          }
          // The theme's colours (they follow the theme) and black. Arrows
          // move between them; Enter or Space chooses.
          Flow {
            id: swatchRow
            objectName: "studioSwatches"
            width: parent.width
            spacing: FoamyStyle.gapSmall
            Accessible.role: Accessible.List
            Accessible.name: FoamyI18n.t("studio.color.swatches")

            Repeater {
              model: scene.swatches
              Rectangle {
                id: swatch
                required property string modelData
                required property int index
                readonly property bool chosen: scene.choice === "color" && scene.colorValue === modelData
                objectName: "studioSwatch-" + modelData
                width: FoamyStyle.actionSize + FoamyStyle.gapSmall
                height: width
                radius: FoamyStyle.radiusSmall
                color: "transparent"
                border.width: activeFocus ? 2 : chosen ? 2 : FoamyStyle.borderWidth
                border.color: activeFocus ? FoamyPalette.text : chosen ? FoamyPalette.accent : FoamyPalette.border
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: scene.swatchName(modelData)
                Accessible.checkable: true
                Accessible.checked: chosen
                function choose() { scene.commit(Draft.setColor(scene.app.draft, modelData)) }
                Accessible.onPressAction: choose()
                Keys.onReturnPressed: choose()
                Keys.onEnterPressed: choose()
                Keys.onSpacePressed: choose()
                Keys.onLeftPressed: swatchRow.focusSwatch(index + (LayoutMirroring.enabled ? 1 : -1))
                Keys.onRightPressed: swatchRow.focusSwatch(index + (LayoutMirroring.enabled ? -1 : 1))
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: 4
                  radius: Math.max(0, parent.radius - 2)
                  color: scene.swatchColor(swatch.modelData)
                  border.width: 1
                  border.color: Qt.alpha(FoamyPalette.text, 0.18)
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    swatch.forceActiveFocus(Qt.MouseFocusReason)
                    swatch.choose()
                  }
                }
              }
            }
            function focusSwatch(index) {
              if (index < 0 || index >= scene.swatches.length) return
              for (var i = 0; i < children.length; i++)
                if (children[i].objectName === "studioSwatch-" + scene.swatches[index]) children[i].forceActiveFocus(Qt.TabFocusReason)
            }
          }
          // Any colour: six hex digits, checked as typed and by the lock.
          RowLayout {
            width: parent.width
            spacing: FoamyStyle.gap
            FoamyTextSettingField {
              id: hexField
              objectName: "studioColorHex"
              Layout.fillWidth: true
              label: FoamyI18n.t("studio.color.custom")
              placeholderText: "#rrggbb"
              value: scene.colorValue.charAt(0) === "#" ? scene.colorValue : ""
              field.maximumLength: 7
              validate: function(text) { return text === "" || Draft.hexColor(text) !== "" || FoamyI18n.t("studio.color.invalid") }
              // Then shown as the lock keeps it ("C0FFEE" → "#c0ffee").
              onCommitted: function(text) {
                if (text === "") return
                scene.commit(Draft.setColor(scene.app.draft, text))
                Qt.callLater(function() { if (!hexField.dirty) hexField.show() })
              }
            }
            Rectangle {
              objectName: "studioColorPreview"
              Layout.preferredWidth: FoamyStyle.actionSize
              Layout.preferredHeight: FoamyStyle.actionSize
              Layout.alignment: Qt.AlignBottom
              radius: FoamyStyle.radiusSmall
              color: scene.swatchColor(scene.colorValue)
              border.width: FoamyStyle.borderWidth
              border.color: FoamyPalette.border
              Accessible.ignored: true
            }
          }
        }

        // --- the animation (Animation) -------------------------------------
        Column {
          objectName: "studioAnimationSection"
          width: parent.width
          spacing: FoamyStyle.gap
          visible: scene.choice === "animation"

          SectionLabel {
            text: FoamyI18n.t("studio.animation")
            topPadding: FoamyStyle.gap
          }
          // Each animation Layout.js lists, in its still frame.
          StyleTiles {
            objectName: "studioAnimation"
            width: parent.width
            element: "animation"
            title: FoamyI18n.t("studio.animation")
            options: LockLayout.DRAWN_SOURCES
            value: scene.choice === "animation" ? scene.background.source : ""
            labelFor: function(name) { return FoamyI18n.t("studio.source." + name) }
            onPicked: function(name) { scene.commit(Draft.setBackground(scene.app.draft, "source", name)) }
          }
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
          // 1 %: the presets use dims like 0.12.
          stepSize: 0.01
          value: scene.background.dim
          valueText: scene.percent(shown)
          onMoved: function(v) { scene.preview(Draft.setBackground(scene.app.draft, "dim", v)) }
          onCommitted: function(v) { scene.commit(Draft.setBackground(scene.app.draft, "dim", v)) }
        }

        SectionLabel {
          text: FoamyI18n.t("studio.glass")
          topPadding: FoamyStyle.gap
        }
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

      // --- shapes ------------------------------------------------------------
      Column {
        objectName: "studioSceneShapesSection"
        width: parent.width
        spacing: FoamyStyle.gap
        visible: scene.page === "shapes"

        // The list, in drawing order (frosted shapes are drawn first on the lock).
        Column {
          id: shapeList
          objectName: "studioShapeList"
          width: parent.width
          spacing: FoamyStyle.gapTiny
          Accessible.role: Accessible.List
          Accessible.name: FoamyI18n.t("studio.shapes")

          Repeater {
            model: scene.shapes.length
            RowLayout {
              id: shapeRow
              required property int index
              width: shapeList.width
              spacing: FoamyStyle.gapTiny
              StudioButton {
                objectName: "studioShape-" + shapeRow.index
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignLeft
                text: scene.shapeText(shapeRow.index)
                checked: scene.shapeIndex === shapeRow.index
                Accessible.role: Accessible.ListItem
                onClicked: scene.app.selectShape(shapeRow.index)
              }
              IconButton {
                objectName: "studioShapeUp-" + shapeRow.index
                icon: "chevron-up"
                name: FoamyI18n.t("studio.shape.up")
                enabled: shapeRow.index > 0
                onClicked: scene.moveShape(shapeRow.index, shapeRow.index - 1)
              }
              IconButton {
                objectName: "studioShapeDown-" + shapeRow.index
                icon: "chevron-down"
                name: FoamyI18n.t("studio.shape.down")
                enabled: shapeRow.index < scene.shapes.length - 1
                onClicked: scene.moveShape(shapeRow.index, shapeRow.index + 1)
              }
              IconButton {
                objectName: "studioShapeRemove-" + shapeRow.index
                icon: "trash"
                name: FoamyI18n.t("studio.shape.remove")
                onClicked: scene.removeShape(shapeRow.index)
              }
            }
          }
        }
        PaneNote {
          objectName: "studioShapesEmpty"
          visible: scene.shapes.length === 0
          text: FoamyI18n.t("studio.shapes.empty")
        }

        SectionLabel {
          text: FoamyI18n.t("studio.shape.add")
          topPadding: FoamyStyle.gap
        }
        StyleTiles {
          objectName: "studioAddShape"
          width: parent.width
          element: "decor"
          title: FoamyI18n.t("studio.shape.add")
          options: Draft.SHAPE_CHOICES
          value: ""
          enabled: scene.shapes.length < LockLayout.SHAPE_LIMITS.count
          opacity: enabled ? 1 : FoamyStyle.disabledOpacity
          labelFor: function(choice) { return scene.choiceLabel(choice) }
          onPicked: function(choice) { scene.addShape(choice) }
        }
        PaneNote {
          objectName: "studioAddShapeNote"
          text: scene.shapes.length >= LockLayout.SHAPE_LIMITS.count ? FoamyI18n.t("studio.shape.full")
            : scene.addRefused === "around" ? FoamyI18n.t("studio.shape.pickModule")
            : scene.addRefused !== "" ? FoamyI18n.t("studio.shape.noRoom", scene.choiceLabel(scene.addRefused))
            : ""
        }

        // --- the selected shape -------------------------------------------------
        Column {
          objectName: "studioShapeInspector"
          width: parent.width
          spacing: FoamyStyle.gap
          visible: scene.shape !== null

          SectionLabel {
            text: scene.shape ? scene.kindLabel(scene.shapeKind) : ""
            topPadding: FoamyStyle.sectionGap
          }
          PaneNote {
            objectName: "studioShapeBand"
            visible: scene.shape !== null && LockLayout.bottomBand([scene.shape])
            text: FoamyI18n.t("studio.shape.band")
          }

          // What it wraps.
          Labelled {
            width: parent.width
            visible: scene.shapeKind !== "frame"
            text: FoamyI18n.t("studio.shape.wraps")
            Segmented {
              objectName: "studioShapeWrap"
              name: FoamyI18n.t("studio.shape.wraps")
              options: ["zones", "modules"].concat(scene.shapeKind === "panel" ? ["none"] : [])
                .map(function(mode) { return { value: mode, label: FoamyI18n.t("studio.shape.wrap." + mode) } })
              value: Draft.wrapMode(scene.shape)
              onPicked: function(mode) { scene.commit(Draft.setWrapMode(scene.app.draft, scene.shapeIndex, mode)) }
            }
          }
          // In a RowLayout, so it starts on the reading start.
          RowLayout {
            width: parent.width
            visible: Draft.wrapMode(scene.shape) === "zones"
            ZonePicker {
              objectName: "studioShapeZones"
              name: FoamyI18n.t("studio.shape.zones")
              zones: scene.shape && scene.shape.wrap && scene.shape.wrap.zones ? scene.shape.wrap.zones : []
              onPicked: function(zone) {
                var on = scene.shape.wrap.zones.indexOf(zone) === -1
                scene.commit(Draft.toggleWrapped(scene.app.draft, scene.shapeIndex, zone, on))
              }
            }
            Item { Layout.fillWidth: true }
          }
          Column {
            objectName: "studioShapeModules"
            width: parent.width
            visible: Draft.wrapMode(scene.shape) === "modules"
            Accessible.role: Accessible.List
            Accessible.name: FoamyI18n.t("studio.shape.modules")
            Repeater {
              model: Draft.DISPLAY_ORDER
              StudioToggle {
                required property string modelData
                readonly property var wrapped: scene.shape && scene.shape.wrap && scene.shape.wrap.modules ? scene.shape.wrap.modules : []
                objectName: "studioShapeModule-" + modelData
                width: parent.width
                text: scene.app ? scene.app.moduleLabel(modelData) : modelData
                checked: wrapped.indexOf(modelData) !== -1
                // The last one stays.
                enabled: !checked || wrapped.length > 1
                opacity: enabled ? 1 : FoamyStyle.disabledOpacity
                onToggled: scene.commit(Draft.toggleWrapped(scene.app.draft, scene.shapeIndex, modelData, !checked))
              }
            }
          }

          // Its shape.
          SectionLabel {
            text: FoamyI18n.t("studio.shape.shape")
            topPadding: FoamyStyle.gap
          }
          Labelled {
            width: parent.width
            visible: scene.shapeKind === "panel"
            text: FoamyI18n.t("studio.shape.edge")
            Segmented {
              objectName: "studioShapeEdge"
              name: FoamyI18n.t("studio.shape.edge")
              options: LockLayout.SHAPE_EDGES.map(function(edge) { return { value: edge, label: FoamyI18n.t("studio.shape.edge." + edge) } })
              value: scene.shape && scene.shape.edge ? scene.shape.edge : ""
              onPicked: function(edge) { scene.setShape("edge", edge) }
            }
          }
          Labelled {
            width: parent.width
            visible: scene.shapeKind === "frame"
            text: FoamyI18n.t("studio.shape.style")
            Segmented {
              objectName: "studioShapeStyle"
              name: FoamyI18n.t("studio.shape.style")
              options: LockLayout.FRAME_STYLES.map(function(style) { return { value: style, label: FoamyI18n.t("studio.shape.style." + style) } })
              value: scene.shapeKind === "frame" ? scene.shapeValue("style") : ""
              onPicked: function(style) { scene.setShape("style", style) }
            }
          }
          Labelled {
            width: parent.width
            visible: scene.shapeKind === "box"
            text: FoamyI18n.t("studio.shape.padX")
            StepField {
              objectName: "studioShapePadX"
              name: FoamyI18n.t("studio.shape.padX")
              value: scene.shapeKind === "box" ? scene.shapeValue("pad").x : 0
              onCommitted: function(v) { scene.setShape("pad.x", v) }
            }
          }
          Labelled {
            width: parent.width
            visible: scene.shapeKind === "box"
            text: FoamyI18n.t("studio.shape.padY")
            StepField {
              objectName: "studioShapePadY"
              name: FoamyI18n.t("studio.shape.padY")
              value: scene.shapeKind === "box" ? scene.shapeValue("pad").y : 0
              onCommitted: function(v) { scene.setShape("pad.y", v) }
            }
          }
          Labelled {
            width: parent.width
            visible: scene.shapeKind === "panel"
            text: FoamyI18n.t("studio.shape.pad")
            StepField {
              objectName: "studioShapePad"
              name: FoamyI18n.t("studio.shape.pad")
              value: scene.shapeKind === "panel" ? scene.shapeValue("pad") : 0
              onCommitted: function(v) { scene.setShape("pad", v) }
            }
          }
          StudioToggle {
            objectName: "studioShapeAcross"
            width: parent.width
            visible: scene.shapeKind === "box"
            text: FoamyI18n.t("studio.shape.across")
            checked: scene.shapeKind === "box" && scene.shapeValue("stretch") === "across"
            onToggled: scene.setShape("stretch", checked ? null : "across")
          }
          // A panel's size: each bound off, a percentage of the screen across
          // it, or pixels.
          Repeater {
            model: scene.shapeKind === "panel" ? ["min", "max", "fillPast"] : []
            Column {
              id: boundRow
              required property string modelData
              width: parent ? parent.width : 0
              spacing: FoamyStyle.gapTiny
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: FoamyI18n.t("studio.shape." + boundRow.modelData)
                horizontalAlignment: Text.AlignLeft
                color: FoamyPalette.secondaryText
                font.family: FoamyStyle.fontFamily
                font.pixelSize: FoamyStyle.font.body
                wrapMode: Text.Wrap
              }
              // A RowLayout, so it starts on the reading start.
              RowLayout {
                width: parent.width
                spacing: FoamyStyle.gapSmall
                StepField {
                  objectName: "studioShapeSize-" + boundRow.modelData
                  visible: scene.boundUnit(boundRow.modelData) !== "off"
                  name: FoamyI18n.t("studio.shape." + boundRow.modelData)
                  value: scene.boundValue(boundRow.modelData)
                  onCommitted: function(v) { scene.setBound(boundRow.modelData, scene.boundUnit(boundRow.modelData), v) }
                }
                Segmented {
                  objectName: "studioShapeUnit-" + boundRow.modelData
                  name: FoamyI18n.t("studio.shape." + boundRow.modelData)
                  options: [{ value: "off", label: FoamyI18n.t("studio.shape.off") }, { value: "screen", label: "%" }, { value: "px", label: "px" }]
                  value: scene.boundUnit(boundRow.modelData)
                  onPicked: function(unit) { if (unit !== scene.boundUnit(boundRow.modelData)) scene.setBound(boundRow.modelData, unit) }
                }
                Item { Layout.fillWidth: true }
              }
            }
          }
          Labelled {
            width: parent.width
            visible: scene.shape !== null && (scene.shapeKind !== "box" || scene.shapeValue("stretch") === "across")
            text: FoamyI18n.t("studio.shape.inset")
            StepField {
              objectName: "studioShapeInset"
              name: FoamyI18n.t("studio.shape.inset")
              value: scene.shape ? scene.shapeValue("inset") : 0
              onCommitted: function(v) { scene.setShape("inset", v) }
            }
          }
          StudioToggle {
            objectName: "studioShapeRadiusAuto"
            width: parent.width
            visible: scene.shapeKind === "box"
            text: FoamyI18n.t("studio.shape.radiusAuto")
            checked: scene.shapeKind === "box" && scene.shapeValue("radius") === "auto"
            onToggled: scene.setShape("radius", checked ? null : "auto")
          }
          StudioSlider {
            objectName: "studioShapeRadius"
            width: parent.width
            visible: scene.shape !== null
            enabled: !(scene.shapeKind === "box" && scene.shapeValue("radius") === "auto")
            label: FoamyI18n.t("studio.shape.radius")
            from: 0
            to: scene.shape ? LockLayout.SHAPE_LIMITS.radius[scene.shapeKind].max : 1
            stepSize: 1
            value: scene.shape && scene.shapeValue("radius") !== "auto" ? scene.shapeValue("radius") : scene.shapeDefaults.radius || 0
            valueText: FoamyI18n.t("studio.px", FoamyI18n.number(shown, 0))
            onMoved: function(v) { scene.previewShape("radius", v) }
            onCommitted: function(v) { scene.setShape("radius", v) }
          }

          // Its fill.
          SectionLabel {
            visible: scene.shapeKind !== "frame"
            text: FoamyI18n.t("studio.shape.fill")
            topPadding: FoamyStyle.gap
          }
          Segmented {
            objectName: "studioShapeFill"
            visible: scene.shapeKind !== "frame"
            name: FoamyI18n.t("studio.shape.fill")
            options: LockLayout.SHAPE_FILLS.map(function(color) { return { value: color, label: FoamyI18n.t("studio.shape.fill." + color) } })
            value: scene.shape ? scene.fillValue("color") : ""
            onPicked: function(color) { scene.setShape("fill.color", color) }
          }
          PaneNote {
            objectName: "studioShapeFillNote"
            visible: scene.shapeKind !== "frame" && scene.fillValue("color") === "auto"
            text: FoamyI18n.t("studio.shape.fill.autoHint")
          }
          StudioSlider {
            objectName: "studioShapeOpacity"
            width: parent.width
            visible: scene.shapeKind !== "frame"
            label: FoamyI18n.t("studio.opacity")
            from: 0
            to: 1
            // 1 %: the templates use 0.55, 0.72 and 0.82.
            stepSize: 0.01
            value: scene.shape ? scene.fillValue("opacity") : 0
            valueText: scene.percent(shown)
            onMoved: function(v) { scene.previewShape("fill.opacity", v) }
            onCommitted: function(v) { scene.setShape("fill.opacity", v) }
          }
          StudioToggle {
            objectName: "studioShapeFrost"
            width: parent.width
            visible: scene.shapeKind !== "frame"
            text: FoamyI18n.t("studio.shape.frost")
            checked: scene.shape !== null && scene.fillValue("frost") === true
            onToggled: scene.setShape("fill.frost", checked ? null : true)
          }
          PaneNote {
            objectName: "studioShapeFrostNote"
            visible: scene.shapeKind !== "frame" && scene.fillValue("frost") === true
            text: FoamyI18n.t("studio.shape.frostNote")
          }

          // Its border.
          SectionLabel {
            visible: scene.shapeKind !== "frame"
            text: FoamyI18n.t("studio.shape.border")
            topPadding: FoamyStyle.gap
          }
          Segmented {
            objectName: "studioShapeBorder"
            visible: scene.shapeKind !== "frame"
            name: FoamyI18n.t("studio.shape.border")
            options: ["none"].concat(LockLayout.SHAPE_BORDERS).map(function(color) { return { value: color, label: FoamyI18n.t("studio.shape.border." + color) } })
            value: !scene.shape ? "" : scene.borderValue("width") === 0 ? "none" : scene.borderValue("color")
            onPicked: function(color) {
              if (color === "none") return scene.setShape("border.width", 0)
              var next = Draft.setShape(scene.app.draft, scene.shapeIndex, "border.color", color)
              if (scene.borderValue("width") === 0) next = Draft.setShape(next, scene.shapeIndex, "border.width", null)
              scene.commit(next)
            }
          }
          Labelled {
            width: parent.width
            visible: scene.shapeKind !== "frame" && scene.borderValue("width") > 0
            text: FoamyI18n.t("studio.shape.borderWidth")
            StepField {
              objectName: "studioShapeBorderWidth"
              name: FoamyI18n.t("studio.shape.borderWidth")
              value: scene.shape ? scene.borderValue("width") : 0
              onCommitted: function(v) { if (v >= 1) scene.setShape("border.width", v) }
            }
          }
          StudioToggle {
            objectName: "studioShapeInner"
            width: parent.width
            visible: scene.shapeKind === "panel" && scene.borderValue("width") > 0
            text: FoamyI18n.t("studio.shape.inner")
            checked: scene.shapeKind === "panel" && scene.borderValue("sides") === "inner"
            onToggled: scene.setShape("border.sides", checked ? null : "inner")
          }

          // The modules' only background.
          StudioToggle {
            objectName: "studioShapeAbsorb"
            width: parent.width
            visible: scene.shapeKind !== "frame"
            text: FoamyI18n.t("studio.shape.absorb")
            checked: scene.shape !== null && scene.shapeValue("absorb") === true
            onToggled: scene.setShape("absorb", checked ? null : true)
          }
          PaneNote {
            objectName: "studioShapeAbsorbNote"
            visible: scene.shapeKind !== "frame" && scene.shapeValue("absorb") === true
            text: FoamyI18n.t("studio.shape.absorbNote")
          }
        }
      }

      Item { width: 1; height: FoamyStyle.gap }
    }
  }

  // --- shapes -----------------------------------------------------------------
  readonly property var shapes: look.background.shapes || []
  readonly property int shapeIndex: app && app.selectedShape >= 0 && app.selectedShape < shapes.length ? app.selectedShape : -1
  readonly property var shape: shapeIndex >= 0 ? shapes[shapeIndex] : null
  readonly property string shapeKind: shape ? shape.kind : ""
  readonly property var shapeDefaults: shape ? LockLayout.SHAPE_DEFAULTS[shape.kind] : ({})
  // A template that had no room, or "around" without a module ("" when none).
  property string addRefused: ""

  function shapeValue(key) { return shape && shape[key] !== undefined ? shape[key] : shapeDefaults[key] }
  function fillValue(key) {
    var fill = shape && shape.fill ? shape.fill : {}
    return fill[key] !== undefined ? fill[key] : LockLayout.SHAPE_FILL_DEFAULTS[key]
  }
  function borderValue(key) {
    var border = shape && shape.border ? shape.border : {}
    return border[key] !== undefined ? border[key] : LockLayout.SHAPE_BORDER_DEFAULTS[key]
  }
  function setShape(path, value) { commit(Draft.setShape(app.draft, shapeIndex, path, value)) }
  function previewShape(path, value) { preview(Draft.setShape(app.draft, shapeIndex, path, value)) }
  function kindLabel(kind) { return FoamyI18n.t("studio.shape.kind." + kind) }
  // A shape in words: "Box around Clock, Date", "Frame: Glow", …
  function shapeText(index) {
    var item = shapes[index]
    if (!item) return ""
    if (item.kind === "frame") return FoamyI18n.t("studio.shape.frameText", FoamyI18n.t("studio.shape.style." + (item.style || "auto")))
    if (!item.wrap) return FoamyI18n.t("studio.shape.alone", [kindLabel(item.kind), FoamyI18n.t("studio.shape.edge." + item.edge).toLowerCase()])
    var names = Draft.wrappedModules(look, item)
    if (names.length === 0) return FoamyI18n.t("studio.shape.aroundNothing", kindLabel(item.kind))
    return FoamyI18n.t("studio.shape.around", [kindLabel(item.kind), names.map(function(name) { return app.moduleLabel(name) }).join(", ")])
  }
  function choiceLabel(choice) {
    if (choice !== "around") return FoamyI18n.t("studio.decor." + choice)
    return app && app.selected ? FoamyI18n.t("studio.decor.aroundModule", app.moduleLabel(app.selected)) : FoamyI18n.t("studio.decor.around")
  }
  // Add a template (or a box around the selected module) and select it.
  function addShape(choice) {
    var module = choice === "around" && app ? app.selected : ""
    if (!Draft.canAddShape(look, choice, module)) {
      addRefused = choice
      return
    }
    addRefused = ""
    var at = shapes.length
    commit(Draft.addShape(app.draft, choice, module))
    app.selectShape(at)
  }
  function moveShape(index, to) {
    commit(Draft.moveShape(app.draft, index, to))
    app.selectShape(to)
  }
  function removeShape(index) {
    commit(Draft.removeShape(app.draft, index))
    app.selectShape(Math.min(index, shapes.length - 1))
  }
  // A size bound's unit: "off", "screen" (a percentage) or "px".
  function boundUnit(bound) {
    var size = shape && shape.size ? shape.size : {}
    return !size[bound] ? "off" : size[bound].px !== undefined ? "px" : "screen"
  }
  function boundValue(bound) {
    var unit = boundUnit(bound)
    return unit === "off" ? 0 : unit === "px" ? shape.size[bound].px : Math.round(shape.size[bound].screen * 100)
  }
  readonly property var boundStarts: ({ min: { screen: 0.3, px: 400 }, max: { screen: 0.5, px: 800 }, fillPast: { screen: 0.6, px: 1200 } })
  function setBound(bound, unit, value) {
    if (unit === "off") return setShape("size." + bound, null)
    var next = {}
    next[unit] = value === undefined ? boundStarts[bound][unit] : unit === "screen" ? value / 100 : value
    setShape("size." + bound, next)
  }

  // A label on the reading start and a control on the end.
  component Labelled: RowLayout {
    property string text: ""
    default property alias control: slot.data
    spacing: FoamyStyle.gap
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: parent.text
      horizontalAlignment: Text.AlignLeft
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      wrapMode: Text.Wrap
    }
    Item {
      id: slot
      implicitWidth: childrenRect.width
      implicitHeight: childrenRect.height
    }
  }
}
