import QtQuick
// Qualify the theme singleton to avoid QtQuick.Color taking precedence.
import qs.Commons as Commons
import "../kit"

// The password field: the editor, its placeholder and states, the unlock hint
// and the submit arrow. Authentication itself stays in the service; this only
// reports text and submission through the host view.
Rectangle {
  id: field
  // The host LockView: data, theme and scale (its properties aren't visible to qmllint as Item).
  required property var view
  // This element's size: the view's scale for its screen (LockView sets it).
  required property real uiScale
  // The opacity of its glass surface (the look's, or its own `glass`).
  required property real glassOpacity
  readonly property color glassFill: view.glassAt(glassOpacity)
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  // Off on a surface that doesn't get the keys: the editor stays live and
  // focused there, only the field's chrome is hidden (see LockView.primary).
  property bool chromeVisible: true
  // Only the surround changes between styles; the editor is the same. Each
  // style has a fixed size, whatever is typed or shown.
  // - "pill": a glass pill once typing starts.
  // - "underline": a line under the text, no surface.
  // - "box": a squarer glass box, always shown, with the hint inside and the
  //   submit arrow in its own segment.
  // - "dots": no surface: centred dots, the hint and states as small text.
  // - "terminal": a dark box in the mono font with a "Password:" prompt
  //   before the editor and a block caret.
  // - "card": a glass card with a greeting above a pill.
  property string styleName: "pill"
  readonly property bool underline: styleName === "underline"
  readonly property bool box: styleName === "box"
  readonly property bool dotsOnly: styleName === "dots"
  readonly property bool terminal: styleName === "terminal"
  readonly property bool card: styleName === "card"
  // A password being typed is never invisible, whichever surface has it.
  readonly property bool chromeShown: chromeVisible || view.passwordText.length > 0
  // "always" (the default) or "typing": the underline, box, terminal and
  // card hide their surface, border, line, prompt, greeting and arrow while
  // nothing is typed and no failure or check shows. The unlock hint and the
  // fingerprint notice stay, the editor stays focused (at opacity 0, as on
  // every idle surface) and the field keeps its size, so nothing moves when
  // it appears. The pill and dots already show only the hint when idle.
  property string reveal: "always"
  readonly property bool surfaceIdleHidden: reveal === "typing" && (underline || box || terminal || card) && !view.showPassword
  // The centre column at this element's scale (it bounds the hint and the
  // notice), and the field's own sizes.
  readonly property real contentWidth: view.contentWidthAt(uiScale)
  readonly property real fieldWidth: Math.min(Math.round(320 * uiScale), contentWidth)
  readonly property int fieldHeight: Math.round(51 * uiScale)
  readonly property int fieldLeadingInset: Math.round(24 * uiScale)
  readonly property int fieldFontSize: Math.round(18 * uiScale)
  readonly property int passwordDotFontSize: Math.round(17 * uiScale)
  readonly property int passwordDotLetterSpacing: Math.round(2 * uiScale)
  readonly property alias input: passwordInput
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool mirrored: view.rightToLeft
  readonly property string editorFontFamily: terminal ? FoamyStyle.monoFamily : view.textFontFamily
  // The surface behind everything: glass for the pill while typing, always
  // for the box and card, a dark panel for the terminal, none otherwise.
  readonly property bool surfaceShown: chromeShown && !surfaceIdleHidden
    && (box || card || terminal || (styleName === "pill" && view.showPassword))
  readonly property real submitWidth: Math.round(70 * uiScale)
  // The submit arrow: the pill and card while typing, the box always; the
  // dots and terminal submit with Enter alone.
  readonly property bool submitShown: chromeShown && !surfaceIdleHidden && (box || (!dotsOnly && !terminal && view.showPassword))
  // The editor's inset from the leading and trailing edges of its area.
  readonly property real inset: Math.round(16 * uiScale)
  readonly property real editorLeading: terminal ? 0 : dotsOnly ? inset : fieldLeadingInset
  readonly property real editorTrailing: dotsOnly || terminal ? inset : submitWidth
  readonly property real cardPadding: Math.round(16 * uiScale)

  objectName: "inputField"
  width: box || terminal || card ? Math.min(Math.round((terminal ? 440 : 360) * uiScale), contentWidth) : fieldWidth
  height: box ? Math.round(56 * uiScale) : terminal ? Math.round(50 * uiScale)
    : card ? Math.round(138 * uiScale) : fieldHeight
  radius: box ? Math.round(12 * uiScale) : terminal ? Math.round(6 * uiScale)
    : card ? Math.round(24 * uiScale) : underline || dotsOnly ? 0 : height / 2
  color: !surfaceShown ? "transparent" : terminal ? Qt.rgba(0.012, 0.016, 0.03, 0.72) : glassFill
  border.width: surfaceShown ? 1 : 0
  border.color: view.errorState ? Commons.Color.lock.borderError : view.glassBorder
  // Not clipped: the unlock hint below shows only while the field has no
  // fill or border, and a translated hint can be wider than the pill.
  // The editor and its placeholder clip and elide on their own.

  // Where the editor sits: the whole field, the part after the terminal's
  // prompt, or the card's inner pill. Plain x/y, mirrored by hand.
  Item {
    id: editorArea
    objectName: "editorArea"
    readonly property real promptEnd: field.inset + prompt.implicitWidth + Math.round(10 * field.uiScale)
    x: field.card ? field.cardPadding : field.terminal && !field.mirrored ? promptEnd : 0
    y: field.card ? field.height - height - field.cardPadding : 0
    width: field.card ? field.width - 2 * field.cardPadding : field.terminal ? field.width - promptEnd : field.width
    height: field.card ? Math.round(50 * field.uiScale) : field.height
  }

  // Where the idle hint sits: the editor area without the box's arrow
  // segment (the whole area while the box is hidden).
  Item {
    id: hintArea
    readonly property bool segment: field.box && !field.surfaceIdleHidden
    x: editorArea.x + (segment && field.mirrored ? field.submitWidth : 0)
    y: editorArea.y
    width: editorArea.width - (segment ? field.submitWidth : 0)
    height: editorArea.height
  }

  Text {
    id: greeting
    objectName: "cardGreeting"
    visible: field.card && field.chromeShown && !field.surfaceIdleHidden
    x: Math.round(22 * field.uiScale)
    y: Math.round(20 * field.uiScale)
    width: field.width - 2 * x
    textFormat: Text.PlainText
    text: FoamyI18n.t("Welcome back")
    color: field.view.foreground
    font.family: field.view.textFontFamily
    font.pixelSize: Math.round(20 * field.uiScale)
    font.weight: Font.Medium
    horizontalAlignment: field.alignment === "start" ? Text.AlignLeft : field.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    elide: Text.ElideRight
  }

  // The card's inner pill, around the editor.
  Rectangle {
    objectName: "cardPill"
    visible: field.card && field.chromeShown && !field.surfaceIdleHidden
    x: editorArea.x
    y: editorArea.y
    width: editorArea.width
    height: editorArea.height
    radius: height / 2
    color: Qt.rgba(1, 1, 1, field.view.showPassword ? 0.08 : 0.05)
    border.width: 1
    border.color: field.view.errorState ? Commons.Color.lock.borderError : field.view.glassBorder
  }

  Text {
    id: prompt
    objectName: "terminalPrompt"
    visible: field.terminal && field.chromeShown && !field.surfaceIdleHidden
    x: field.mirrored ? field.width - field.inset - width : field.inset
    y: Math.round((field.height - height) / 2)
    textFormat: Text.PlainText
    text: FoamyI18n.t("Password:")
    color: field.view.foreground
    opacity: 0.72
    font.family: FoamyStyle.monoFamily
    font.pixelSize: Math.round(16 * field.uiScale)
    font.weight: Font.Medium
  }

  // The box's submit segment: a divider before the arrow.
  Rectangle {
    objectName: "boxDivider"
    visible: field.box && field.chromeShown && !field.surfaceIdleHidden
    x: field.mirrored ? field.submitWidth : field.width - field.submitWidth - width
    y: Math.round(10 * field.uiScale)
    width: 1
    height: field.height - 2 * y
    color: field.view.glassBorder
  }

  Rectangle {
    objectName: "fieldUnderline"
    visible: field.underline && field.chromeShown && !field.surfaceIdleHidden
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.max(1, Math.round(1.5 * field.uiScale))
    color: field.view.errorState ? Commons.Color.lock.borderError : field.view.foreground
    opacity: field.view.errorState ? 1 : (field.view.showPassword ? 0.85 : 0.5)
  }

  TextMetrics {
    id: dotMetrics
    font.family: field.editorFontFamily
    font.pixelSize: field.passwordDotFontSize
    font.letterSpacing: field.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  // The hint is bounded by the view's content width, not the pill: it wraps
  // to a second line (two lines fit the field's height) and elides only beyond.
  // Inside a box, card or terminal it stays within the surface; the terminal
  // starts it after the prompt.
  Row {
    id: unlockHint
    objectName: "unlockHint"
    readonly property bool contained: field.box || field.card || field.terminal
    readonly property real limit: contained ? hintArea.width - (field.terminal ? field.inset : Math.round(24 * field.uiScale)) : field.contentWidth
    x: !field.terminal ? hintArea.x + (hintArea.width - width) / 2
      : field.mirrored ? hintArea.x + hintArea.width - field.inset - width : hintArea.x
    y: hintArea.y + (hintArea.height - height) / 2
    spacing: Math.round(10 * field.uiScale)
    visible: field.chromeShown && !field.view.showPassword && field.view.showUnlockHint

    FingerprintIcon {
      id: unlockHintIcon
      width: Math.round((field.dotsOnly || field.terminal ? 20 : 26) * field.uiScale)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      lineColor: field.view.foreground
      visible: field.view.fingerprintConfigured && !field.view.fingerprintUnavailable
    }

    Text {
      objectName: "unlockHintText"
      textFormat: Text.PlainText
      text: field.view.fingerprintConfigured && !field.view.fingerprintUnavailable ? FoamyI18n.t("Use fingerprint or enter password") : FoamyI18n.t("Enter password to unlock")
      width: Math.min(implicitWidth, unlockHint.limit
        - (unlockHintIcon.visible ? unlockHintIcon.width + unlockHint.spacing : 0))
      color: field.view.foreground
      opacity: field.dotsOnly || field.terminal ? 0.82 : 1
      font.family: field.editorFontFamily
      font.pixelSize: Math.round((field.dotsOnly || field.terminal ? 13 : unlockHint.contained ? 14 : 15) * field.uiScale)
      horizontalAlignment: field.terminal ? Text.AlignLeft : Text.AlignHCenter
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  TextInput {
    id: passwordInput
    objectName: "passwordInput"
    // Kept focused while invisible so the first character is retained.
    opacity: field.chromeShown && field.view.showPassword ? 1 : 0
    // Fixed anchors to the editor area; only its geometry and the margins
    // follow the style.
    anchors.left: editorArea.left
    anchors.leftMargin: field.editorLeading
    anchors.right: editorArea.right
    anchors.rightMargin: field.editorTrailing
    anchors.top: editorArea.top
    anchors.bottom: editorArea.bottom
    verticalAlignment: TextInput.AlignVCenter
    horizontalAlignment: field.dotsOnly ? TextInput.AlignHCenter : TextInput.AlignLeft
    activeFocusOnPress: true
    clip: true
    enabled: field.view.inputEnabled && !field.view.authenticatingPassword
    readOnly: field.view.authenticatingPassword
    echoMode: TextInput.Password
    passwordCharacter: "●"
    passwordMaskDelay: 0
    color: field.view.foreground
    selectionColor: field.view.selection
    selectedTextColor: field.view.foreground
    font.family: field.editorFontFamily
    font.pixelSize: text.length > 0
      ? Math.max(1, Math.floor(field.passwordDotFontSize * field.passwordDotScale))
      : field.fieldFontSize
    font.letterSpacing: text.length > 0 ? field.passwordDotLetterSpacing * field.passwordDotScale : 0
    cursorVisible: activeFocus && field.view.showPasswordCursor && text.length > 0
    // The terminal's caret is a block.
    cursorDelegate: Rectangle {
      width: field.terminal ? Math.round(10 * field.uiScale) : 2
      color: field.view.foreground
      opacity: field.terminal ? 0.7 : 1
      visible: passwordInput.cursorVisible
    }

    onTextChanged: {
      if (!field.view.syncingPasswordText) field.view.passwordTextEdited(text)
      if (text.length > 0) field.view.wakeRequested()
      if (text.length > 0 && field.view.failureMessage.length > 0) field.view.clearFailureRequested()
    }

    onAccepted: field.view.submitCurrentPassword()

    Keys.onPressed: function(event) {
      if (event.isAutoRepeat && field.view.dropsAutoRepeat(event.key)) {
        event.accepted = true
        return
      }
      field.view.wakeRequested()
      if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
        field.view.passwordTextEdited("")
        field.view.clearFailureRequested()
        event.accepted = true
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.fill: passwordInput
    text: field.view.authenticatingPassword
      ? FoamyI18n.t("Checking…")
      : (field.view.failureMessage.length > 0 ? field.view.failedAttempts > 0 ? FoamyI18n.t("Authentication failed (%1)", FoamyI18n.number(field.view.failedAttempts)) : FoamyI18n.t(field.view.failureMessage) : field.view.placeholderText)
    visible: field.chromeShown && field.view.showPassword && passwordInput.text.length === 0
    color: field.view.authenticatingPassword
      ? field.view.foreground
      : (field.view.errorState ? Commons.Color.lock.textError : field.view.secondary)
    font.family: field.editorFontFamily
    font.pixelSize: field.dotsOnly ? Math.round(13 * field.uiScale) : field.terminal ? Math.round(15 * field.uiScale) : field.fieldFontSize
    font.italic: field.view.errorState
    horizontalAlignment: field.dotsOnly ? Text.AlignHCenter : Text.AlignLeft
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Item {
    visible: field.submitShown
    width: field.submitWidth
    anchors.right: editorArea.right
    anchors.top: editorArea.top
    anchors.bottom: editorArea.bottom
    opacity: field.view.authenticatingPassword ? 0.55 : (field.view.passwordText.length > 0 ? 1 : field.view.showPassword ? 0.9 : 0.55)

    Rectangle {
      anchors.centerIn: parent
      width: Math.round(38 * field.uiScale)
      height: width
      radius: width / 2
      color: submitMouse.containsMouse && submitMouse.enabled
        ? Qt.rgba(1, 1, 1, 0.1)
        : "transparent"
    }

    Item {
      id: submitArrow
      objectName: "submitArrow"
      anchors.centerIn: parent
      width: Math.round(30 * field.uiScale)
      height: Math.round(26 * field.uiScale)
      // The submit arrow points along the reading direction, mirrored
      // around its own centre (a bare `width` inside Scale is the view's).
      transform: Scale { origin.x: submitArrow.width / 2; xScale: field.view.rightToLeft ? -1 : 1 }

      Rectangle {
        x: Math.round(2 * field.uiScale)
        width: Math.round(23 * field.uiScale)
        height: Math.max(1, Math.round(1.6 * field.uiScale))
        anchors.verticalCenter: parent.verticalCenter
        radius: height / 2
        color: field.view.foreground
      }

      Rectangle {
        x: Math.round(15 * field.uiScale)
        width: Math.round(10 * field.uiScale)
        height: Math.max(1, Math.round(1.6 * field.uiScale))
        anchors.verticalCenter: parent.verticalCenter
        transformOrigin: Item.Right
        rotation: 45
        radius: height / 2
        color: field.view.foreground
      }

      Rectangle {
        x: Math.round(15 * field.uiScale)
        width: Math.round(10 * field.uiScale)
        height: Math.max(1, Math.round(1.6 * field.uiScale))
        anchors.verticalCenter: parent.verticalCenter
        transformOrigin: Item.Right
        rotation: -45
        radius: height / 2
        color: field.view.foreground
      }
    }

    MouseArea {
      id: submitMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: field.view.inputEnabled && !field.view.authenticatingPassword && field.view.passwordText.length > 0
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: field.view.submitCurrentPassword()
    }
  }

  Text {
    objectName: "fingerprintNotice"
    // Plain x/y, mirrored here (see AccountElement: no anchors toggled at runtime).
    y: field.height + Math.round(8 * field.uiScale)
    x: field.alignment === "center" ? (field.width - width) / 2
      : (field.alignment === "start") !== field.view.rightToLeft ? 0 : field.width - width
    width: field.alignment === "center" ? field.contentWidth : field.width
    visible: field.chromeShown && field.view.fingerprintUnavailable
    textFormat: Text.PlainText
    text: FoamyI18n.t("Fingerprint reader unavailable")
    color: field.view.foreground
    font.family: field.view.textFontFamily
    font.pixelSize: Math.round(13 * field.uiScale)
    horizontalAlignment: field.alignment === "start" ? Text.AlignLeft : field.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    wrapMode: Text.WordWrap
  }
}
