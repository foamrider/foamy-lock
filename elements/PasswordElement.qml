import QtQuick
import "../kit"

// The password field: the editor, its placeholder and states, the unlock hint
// and the submit arrow. Authentication itself stays in the service; this only
// reports text and submission through the host view.
Rectangle {
  id: field
  // The host view (LockLayout: the lock or the login screen): data, scale and the
  // theme colours, lockBorderError and lockTextError among them (its
  // properties aren't visible to qmllint as Item).
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
  // style has a fixed size (its own, times the look's factors), whatever is
  // typed or shown.
  // - "pill": a glass pill (by default once typing starts; see reveal).
  // - "underline": a line under the text, no surface.
  // - "box": a squarer glass box, always shown, with the hint inside and the
  //   submit arrow in its own segment.
  // - "dots": no surface: centred dots, the hint and states as small text
  //   (with reveal "always", over a dotted track).
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
  // "always" or "typing" (Layout.revealOf: the pill and dots default to
  // "typing", their drawing before round 4, the others to "always").
  // "typing": nothing of the field but the hint shows while nothing is
  // typed and no failure or check shows: the underline, box, terminal and
  // card hide their surface, border, line, prompt, greeting and arrow, the
  // pill its glass, the dots their track. "always": the field shows while
  // empty too: the pill keeps its glass and border (the hint inside it), the
  // dots a dotted track under the editor. Either way the unlock hint and the
  // fingerprint notice stay, the editor stays focused (at opacity 0, as on
  // every idle surface) and the field keeps its size, so nothing moves when
  // it appears.
  property string reveal: "always"
  // The look's shape and text keys (Layout.js, ELEMENT_OPTIONS.password):
  // widthFactor and heightFactor multiply the style's own size, textSize
  // the field's text (the arrow follows uiScale only). submit false leaves
  // out the arrow, maskGlyph is the typed characters' glyph and
  // mutedHint draws the unlock hint in the theme's placeholder colour.
  // textAlign "start", "center" or "end" lines up the hint, the placeholder
  // and states and the typed characters (logical); "auto" keeps each
  // style's own (the hint centred, the terminal's at the start; the rest at
  // the start, the dots' centred).
  property real widthFactor: 1
  property real heightFactor: 1
  property real textSize: 1
  property bool submit: true
  property string maskGlyph: "●"
  property bool mutedHint: false
  property string textAlign: "auto"
  readonly property bool textAligned: textAlign !== "auto"
  // The explicit alignment as a Text alignment (it mirrors with the view).
  readonly property int textAlignment: textAlign === "center" ? Text.AlignHCenter : textAlign === "end" ? Text.AlignRight : Text.AlignLeft
  readonly property real textScale: uiScale * textSize
  readonly property bool idleShown: reveal === "always"
  readonly property bool surfaceIdleHidden: reveal === "typing" && (underline || box || terminal || card) && !view.showPassword
  // The centre column at this element's scale (it bounds the hint and the
  // notice), and the field's own sizes.
  readonly property real contentWidth: view.contentWidthAt(uiScale)
  // The style's own width and height at 1080p, before scale and the factors.
  readonly property int baseWidth: box || card ? 360 : terminal ? 440 : 320
  readonly property int baseHeight: box ? 56 : terminal ? 50 : card ? 50 : 51
  readonly property real fieldWidth: Math.min(Math.round(baseWidth * uiScale * widthFactor), contentWidth)
  // The card's height is its inner pill's; the greeting's room stays.
  readonly property int fieldHeight: Math.round(baseHeight * uiScale * heightFactor)
  readonly property int fieldLeadingInset: Math.round(24 * uiScale)
  readonly property int fieldFontSize: Math.round(18 * textScale)
  readonly property int passwordDotFontSize: Math.round(17 * textScale)
  readonly property int passwordDotLetterSpacing: Math.round(2 * textScale)
  readonly property alias input: passwordInput
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0 ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth) : 1
  readonly property bool mirrored: view.rightToLeft
  readonly property string editorFontFamily: terminal ? FoamyStyle.monoFamily : view.textFontFamily
  // The surface behind everything: glass for the pill (while typing, or
  // always with reveal "always"), the box and card, a dark panel for the
  // terminal, none otherwise.
  readonly property bool surfaceShown: chromeShown && !surfaceIdleHidden && (box || card || terminal || (styleName === "pill" && (view.showPassword || idleShown)))
  readonly property real submitWidth: Math.round(70 * uiScale)
  // The styles that draw the submit arrow (unless submit is false); the
  // dots and terminal submit with Enter alone.
  readonly property bool submitStyle: submit && !dotsOnly && !terminal
  // The arrow: the pill, underline and card while typing, the box always.
  readonly property bool submitShown: chromeShown && !surfaceIdleHidden && submitStyle && (box || view.showPassword)
  // The editor's inset from the leading and trailing edges of its area.
  readonly property real inset: Math.round(16 * uiScale)
  readonly property real editorLeading: terminal ? 0 : dotsOnly ? inset : fieldLeadingInset
  readonly property real editorTrailing: submitStyle ? submitWidth : dotsOnly || terminal ? inset : fieldLeadingInset
  readonly property real cardPadding: Math.round(16 * uiScale)

  objectName: "inputField"
  width: fieldWidth
  // Rounded once, as before the factors (the card's 138 at 1080p).
  height: card ? Math.round((88 + baseHeight * heightFactor) * uiScale) : fieldHeight
  radius: box ? Math.round(12 * uiScale) : terminal ? Math.round(6 * uiScale) : card ? Math.round(24 * uiScale) : underline || dotsOnly ? 0 : height / 2
  color: !surfaceShown ? "transparent" : terminal ? Qt.rgba(0.012, 0.016, 0.03, 0.72) : glassFill
  border.width: surfaceShown ? 1 : 0
  border.color: view.errorState ? view.lockBorderError : view.glassBorder
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
    height: field.card ? field.fieldHeight : field.height
  }

  // Where the idle hint sits: the editor area without the box's arrow
  // segment (the whole area while the box is hidden or has no arrow).
  Item {
    id: hintArea
    readonly property bool segment: field.box && field.submitStyle && !field.surfaceIdleHidden
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
    font.pixelSize: Math.round(20 * field.textScale)
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
    border.color: field.view.errorState ? field.view.lockBorderError : field.view.glassBorder
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
    font.pixelSize: Math.round(16 * field.textScale)
    font.weight: Font.Medium
  }

  // The box's submit segment: a divider before the arrow.
  Rectangle {
    objectName: "boxDivider"
    visible: field.box && field.submitStyle && field.chromeShown && !field.surfaceIdleHidden
    x: field.mirrored ? field.submitWidth : field.width - field.submitWidth - width
    y: Math.round(10 * field.uiScale)
    width: 1
    height: field.height - 2 * y
    color: field.view.glassBorder
  }

  // The dots' track (reveal "always"): a dotted line along the bottom
  // edge, idle and under the typed dots; the error colour on a failure.
  Row {
    id: dotsTrack
    objectName: "dotsTrack"
    readonly property real dot: Math.max(2, Math.round(3 * field.uiScale))
    visible: field.dotsOnly && field.idleShown && field.chromeShown
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    spacing: Math.round(6 * field.uiScale)
    Repeater {
      model: Math.max(1, Math.floor((field.width - 2 * field.inset + dotsTrack.spacing) / (dotsTrack.dot + dotsTrack.spacing)))
      Rectangle {
        width: dotsTrack.dot
        height: width
        radius: width / 2
        color: field.view.errorState ? field.view.lockBorderError : field.view.foreground
        opacity: field.view.errorState ? 1 : field.view.showPassword ? 0.6 : 0.38
      }
    }
  }

  Rectangle {
    objectName: "fieldUnderline"
    visible: field.underline && field.chromeShown && !field.surfaceIdleHidden
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.max(1, Math.round(1.5 * field.uiScale))
    color: field.view.errorState ? field.view.lockBorderError : field.view.foreground
    opacity: field.view.errorState ? 1 : (field.view.showPassword ? 0.85 : 0.5)
  }

  TextMetrics {
    id: dotMetrics
    font.family: field.editorFontFamily
    font.pixelSize: field.passwordDotFontSize
    font.letterSpacing: field.passwordDotLetterSpacing
    text: field.maskGlyph.repeat(passwordInput.text.length)
  }

  // The hint is bounded by the view's content width, not the pill: it wraps
  // to a second line (two lines fit the field's height) and elides only beyond.
  // Inside a box, card, terminal or a pill shown while empty (reveal
  // "always") it stays within the surface; the terminal starts it after the
  // prompt.
  Row {
    id: unlockHint
    objectName: "unlockHint"
    readonly property bool contained: field.box || field.card || field.terminal || (field.styleName === "pill" && field.idleShown)
    // With textAlign, the hint keeps to the editor's span (its leading
    // and trailing insets, on screen) and lines up in it.
    readonly property real leading: field.editorLeading
    readonly property real trailing: field.dotsOnly || field.terminal ? field.inset : field.fieldLeadingInset
    readonly property real spanX: hintArea.x + (field.mirrored ? trailing : leading)
    readonly property real span: Math.max(0, hintArea.width - leading - trailing)
    readonly property real limit: field.textAligned ? span : contained ? hintArea.width - (field.terminal ? field.inset : Math.round(24 * field.uiScale)) : field.contentWidth
    readonly property color tone: field.mutedHint ? field.view.secondary : field.view.foreground
    x: field.textAligned ? spanX + (field.textAlign === "center" ? (span - width) / 2 : (field.textAlign === "start") !== field.mirrored ? 0 : span - width) : !field.terminal ? hintArea.x + (hintArea.width - width) / 2 : field.mirrored ? hintArea.x + hintArea.width - field.inset - width : hintArea.x
    y: hintArea.y + (hintArea.height - height) / 2
    spacing: Math.round(10 * field.textScale)
    visible: field.chromeShown && !field.view.showPassword && field.view.showUnlockHint

    FingerprintIcon {
      id: unlockHintIcon
      width: Math.round((field.dotsOnly || field.terminal ? 20 : 26) * field.textScale)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      lineColor: unlockHint.tone
      visible: field.view.fingerprintConfigured && !field.view.fingerprintUnavailable
    }

    Text {
      objectName: "unlockHintText"
      textFormat: Text.PlainText
      text: field.view.fingerprintConfigured && !field.view.fingerprintUnavailable ? FoamyI18n.t("Use fingerprint or enter password") : FoamyI18n.t("Enter password to unlock")
      width: Math.min(implicitWidth, unlockHint.limit - (unlockHintIcon.visible ? unlockHintIcon.width + unlockHint.spacing : 0))
      color: unlockHint.tone
      // The theme's placeholder colour carries its own alpha.
      opacity: !field.mutedHint && (field.dotsOnly || field.terminal) ? 0.82 : 1
      font.family: field.editorFontFamily
      font.pixelSize: Math.round((field.dotsOnly || field.terminal ? 13 : unlockHint.contained ? 14 : 15) * field.textScale)
      horizontalAlignment: field.textAligned ? field.textAlignment : field.terminal ? Text.AlignLeft : Text.AlignHCenter
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // The editor is a TextInput that is always read-only; the field edits it.
  // Qt reads the whole clipboard on the UI thread with no byte cap or
  // deadline, so a clipboard owner that keeps sending could hold the lock
  // screen and the shell it runs in. An editable TextInput does that read
  // by itself on every clipboard change (q_canPasteChanged, for canPaste),
  // without a paste; a read-only one never reads the clipboard. So:
  // - Qt keeps the drawing, the cursor and selection keys (arrows, Home/End,
  //   Shift, Ctrl+A), the mouse and Enter.
  // - editKey() types printable text and deletes (Backspace, Delete and
  //   their word variants) through the editor's insert() and remove(),
  //   which work on a read-only editor and keep its maximum length.
  // - Ctrl+V, Shift+Insert and a middle click read the clipboard through
  //   foamy-kit's FoamyClipboard (at most 16 KiB, killed at 2 s).
  // - There is no input method (it needs an editable editor) and no undo,
  //   as in a Qt password field; copy and cut never run on a password.
  //
  // A paste's text arrives later. editRevision counts every change it could
  // land in the wrong place after (the text, the cursor, the selection); a
  // paste keeps the revision it started at (pasteRevision, -1 for none), and
  // a result from an older one, or after the editor lost focus or was
  // disabled, is dropped. A failed paste shows on the notice line under the
  // field until the next edit.
  property int editRevision: 0
  property int pasteRevision: -1
  property string pasteError: ""

  // Inserts text over the selection, or at the cursor, through the editor's
  // own insert (its maximum length and cursor).
  function insertText(text) {
    var start = passwordInput.selectionStart
    var end = passwordInput.selectionEnd
    if (start !== end)
      passwordInput.remove(start, end)
    passwordInput.insert(start !== end ? start : passwordInput.cursorPosition, text)
  }

  // Where the code point before `position` starts (a surrogate pair stays whole).
  function previousPoint(text, position) {
    var low = text.charCodeAt(position - 1)
    var high = position >= 2 ? text.charCodeAt(position - 2) : 0
    return low >= 0xdc00 && low < 0xe000 && high >= 0xd800 && high < 0xdc00 ? position - 2 : position - 1
  }

  // Where the code point after `position` ends.
  function nextPoint(text, position) {
    var high = text.charCodeAt(position)
    var low = position + 1 < text.length ? text.charCodeAt(position + 1) : 0
    return high >= 0xd800 && high < 0xdc00 && low >= 0xdc00 && low < 0xe000 ? position + 2 : position + 1
  }

  // The keys an editable TextInput handles and a read-only one doesn't,
  // applied to the read-only editor. Returns whether the field takes
  // `event`; with `apply` it also acts on it (without, it only claims the
  // key before a shortcut does).
  function editKey(event, apply) {
    // Never on a password: undo, redo, copy and cut (Qt's do nothing on one).
    if (event.matches(StandardKey.Undo) || event.matches(StandardKey.Redo) || event.matches(StandardKey.Copy) || event.matches(StandardKey.Cut))
      return true
    var text = passwordInput.text
    // Qt moves to the previous word (Ctrl+Left; on a password, the start in
    // the text's direction) only when editable; the next word it always does.
    if (event.matches(StandardKey.MoveToPreviousWord)) {
      if (apply) {
        let reversed = text.length > 0 && passwordInput.positionToRectangle(1).x < passwordInput.positionToRectangle(0).x
        passwordInput.cursorPosition = reversed ? text.length : 0
      }
      return true
    }
    var start = passwordInput.selectionStart
    var end = passwordInput.selectionEnd
    var position = passwordInput.cursorPosition
    var selected = start !== end
    var from = -1
    var to = -1
    // As Qt's: Backspace (also with Shift), Delete, and the word variants,
    // which delete to the start or the end (the dots are one word). Each
    // deletes the selection when there is one.
    var control = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Backspace && !control) {
      from = selected ? start : position > 0 ? field.previousPoint(text, position) : 0
      to = selected ? end : position
    } else if (event.matches(StandardKey.Delete)) {
      from = selected ? start : position
      to = selected ? end : position < text.length ? field.nextPoint(text, position) : position
    } else if (event.key === Qt.Key_Backspace || event.matches(StandardKey.DeleteStartOfWord)) {
      from = selected ? start : 0
      to = selected ? end : position
    } else if (event.matches(StandardKey.DeleteEndOfWord) || event.matches(StandardKey.DeleteEndOfLine)) {
      from = selected ? start : position
      to = selected ? end : text.length
    }
    if (from >= 0) {
      if (apply && from !== to)
        passwordInput.remove(from, to)
      return true
    }
    // Printable text, as Qt's QInputControl::isAcceptableInput: Ctrl and
    // Ctrl+Shift combinations are shortcuts (Ctrl+Alt still types, as AltGr
    // can arrive), and control characters never type.
    var typed = event.text
    if (typed === "" || event.modifiers === Qt.ControlModifier || event.modifiers === (Qt.ControlModifier | Qt.ShiftModifier))
      return false
    var first = typed.charCodeAt(0)
    if (first < 0x20 || (first >= 0x7f && first < 0xa0))
      return false
    if (apply)
      field.insertText(typed)
    return true
  }

  function requestPaste(primary) {
    if (!passwordInput.enabled || clipboard.busy)
      return
    field.pasteError = ""
    field.pasteRevision = field.editRevision
    clipboard.start(primary)
  }

  function cancelPaste() {
    field.pasteRevision = -1
    clipboard.cancel()
  }

  // Whether the paste's result still applies; it is used up either way.
  function takePaste() {
    var current = field.pasteRevision >= 0 && field.pasteRevision === field.editRevision && passwordInput.enabled && passwordInput.activeFocus
    field.pasteRevision = -1
    return current
  }

  FoamyClipboard {
    id: clipboard
    onRead: function (text) {
      if (field.takePaste() && text !== "")
        field.insertText(text)
    }
    onFailed: function (message) {
      if (field.takePaste())
        field.pasteError = message
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
    horizontalAlignment: field.textAlign === "center" || (!field.textAligned && field.dotsOnly) ? TextInput.AlignHCenter : field.textAlign === "end" ? TextInput.AlignRight : TextInput.AlignLeft
    activeFocusOnPress: true
    clip: true
    enabled: field.view.inputEnabled && !field.view.authenticatingPassword
    // Always: an editable TextInput reads the clipboard on every change (above).
    readOnly: true
    echoMode: TextInput.Password
    passwordCharacter: field.maskGlyph
    passwordMaskDelay: 0
    color: field.view.foreground
    selectionColor: field.view.selection
    selectedTextColor: field.view.foreground
    font.family: field.editorFontFamily
    font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(field.passwordDotFontSize * field.passwordDotScale)) : field.fieldFontSize
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
      field.editRevision++
      field.pasteError = ""
      if (!field.view.syncingPasswordText)
        field.view.passwordTextEdited(text)
      if (text.length > 0)
        field.view.wakeRequested()
      if (text.length > 0 && field.view.failureMessage.length > 0)
        field.view.clearFailureRequested()
    }
    onCursorPositionChanged: field.editRevision++
    onSelectionStartChanged: field.editRevision++
    onSelectionEndChanged: field.editRevision++
    onEnabledChanged: if (!enabled)
      field.cancelPaste()
    onActiveFocusChanged: if (!activeFocus)
      field.cancelPaste()

    onAccepted: field.view.submitCurrentPassword()

    Keys.onPressed: function (event) {
      if (event.isAutoRepeat && field.view.dropsAutoRepeat(event.key)) {
        event.accepted = true
        return
      }
      field.view.wakeRequested()
      if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
        // Clearing an empty field changes no text, so stop a paste in
        // flight here rather than through editRevision.
        field.cancelPaste()
        field.pasteError = ""
        field.view.passwordTextEdited("")
        field.view.clearFailureRequested()
        event.accepted = true
        return
      }
      if (event.matches(StandardKey.Paste)) {
        field.requestPaste(false)
        event.accepted = true
        return
      }
      // Typing and deleting; the rest (cursor, selection, Enter) is Qt's.
      if (field.editKey(event, true))
        event.accepted = true
    }
    // A read-only TextInput claims no shortcuts; claim the keys the field
    // edits with, as an editable one does.
    Keys.onShortcutOverride: function (event) {
      if (event.matches(StandardKey.Paste) || field.editKey(event, false))
        event.accepted = true
    }

    // Middle-click pastes the primary selection through the same bounded
    // read; the left button stays the editor's.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.MiddleButton
      onPressed: function (mouse) {
        passwordInput.forceActiveFocus()
        passwordInput.cursorPosition = passwordInput.positionAt(mouse.x, mouse.y)
      }
      onClicked: field.requestPaste(true)
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.fill: passwordInput
    text: field.view.authenticatingPassword ? FoamyI18n.t("Checking…") : (field.view.failureMessage.length > 0 ? field.view.failedAttempts > 0 ? FoamyI18n.t("Authentication failed (%1)", FoamyI18n.number(field.view.failedAttempts)) : FoamyI18n.t(field.view.failureMessage) : field.view.placeholderText)
    visible: field.chromeShown && field.view.showPassword && passwordInput.text.length === 0
    color: field.view.authenticatingPassword ? field.view.foreground : (field.view.errorState ? field.view.lockTextError : field.view.secondary)
    font.family: field.editorFontFamily
    font.pixelSize: field.dotsOnly ? Math.round(13 * field.textScale) : field.terminal ? Math.round(15 * field.textScale) : field.fieldFontSize
    font.italic: field.view.errorState
    horizontalAlignment: field.textAligned ? field.textAlignment : field.dotsOnly ? Text.AlignHCenter : Text.AlignLeft
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
      color: submitMouse.containsMouse && submitMouse.enabled ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
    }

    Item {
      id: submitArrow
      objectName: "submitArrow"
      anchors.centerIn: parent
      width: Math.round(30 * field.uiScale)
      height: Math.round(26 * field.uiScale)
      // The submit arrow points along the reading direction, mirrored
      // around its own centre (a bare `width` inside Scale is the view's).
      transform: Scale {
        origin.x: submitArrow.width / 2
        xScale: field.view.rightToLeft ? -1 : 1
      }

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

  // The notice line: a paste that failed (until the next edit), otherwise
  // the fingerprint reader's state.
  Text {
    objectName: "fingerprintNotice"
    // Plain x/y, mirrored here (see AccountElement: no anchors toggled at runtime).
    y: field.height + Math.round(8 * field.uiScale)
    x: field.alignment === "center" ? (field.width - width) / 2 : (field.alignment === "start") !== field.view.rightToLeft ? 0 : field.width - width
    width: field.alignment === "center" ? field.contentWidth : field.width
    visible: field.chromeShown && (field.pasteError !== "" || field.view.fingerprintUnavailable)
    textFormat: Text.PlainText
    text: field.pasteError !== "" ? FoamyI18n.t(field.pasteError) : FoamyI18n.t("Fingerprint reader unavailable")
    color: field.view.foreground
    font.family: field.view.textFontFamily
    font.pixelSize: Math.round(13 * field.textScale)
    horizontalAlignment: field.alignment === "start" ? Text.AlignLeft : field.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    wrapMode: Text.WordWrap
  }
}
