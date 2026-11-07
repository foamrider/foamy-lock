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
  // "start", "center" or "end" (logical: mirrors with the language).
  property string alignment: "center"
  // Off on a surface that doesn't get the keys: the editor stays live and
  // focused there, only the field's chrome is hidden (see LockView.primary).
  property bool chromeVisible: true
  // "pill" (glass pill once typing starts) or "underline" (a line under the
  // text, no surface). Only the surround changes; the editor is the same.
  property string styleName: "pill"
  readonly property bool underline: styleName === "underline"
  // A password being typed is never invisible, whichever surface has it.
  readonly property bool chromeShown: chromeVisible || view.passwordText.length > 0
  readonly property alias input: passwordInput
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1

  objectName: "inputField"
  width: view.fieldWidth
  height: view.fieldHeight
  radius: underline ? 0 : height / 2
  color: !underline && chromeShown && view.showPassword ? view.glass : "transparent"
  border.width: !underline && chromeShown && view.showPassword ? 1 : 0
  border.color: view.errorState ? Commons.Color.lock.borderError : view.glassBorder
  // Not clipped: the unlock hint below shows only while the field has no
  // fill or border, and a translated hint can be wider than the pill.
  // The editor and its placeholder clip and elide on their own.

  Rectangle {
    objectName: "fieldUnderline"
    visible: field.underline && field.chromeShown
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.max(1, Math.round(1.5 * field.view.uiScale))
    color: field.view.errorState ? Commons.Color.lock.borderError : field.view.foreground
    opacity: field.view.errorState ? 1 : (field.view.showPassword ? 0.85 : 0.5)
  }

  TextMetrics {
    id: dotMetrics
    font.family: field.view.textFontFamily
    font.pixelSize: field.view.passwordDotFontSize
    font.letterSpacing: field.view.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  // The hint is bounded by the view's content width, not the pill: it wraps
  // to a second line (two lines fit the field's height) and elides only beyond.
  Row {
    id: unlockHint
    objectName: "unlockHint"
    anchors.centerIn: parent
    spacing: Math.round(10 * field.view.uiScale)
    visible: field.chromeShown && !field.view.showPassword

    FingerprintIcon {
      id: unlockHintIcon
      width: Math.round(26 * field.view.uiScale)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      lineColor: field.view.foreground
      visible: field.view.fingerprintConfigured && !field.view.fingerprintUnavailable
    }

    Text {
      objectName: "unlockHintText"
      textFormat: Text.PlainText
      text: field.view.fingerprintConfigured && !field.view.fingerprintUnavailable ? FoamyI18n.t("Use fingerprint or enter password") : FoamyI18n.t("Enter password to unlock")
      width: Math.min(implicitWidth, field.view.contentWidth
        - (unlockHintIcon.visible ? unlockHintIcon.width + unlockHint.spacing : 0))
      color: field.view.foreground
      font.family: field.view.textFontFamily
      font.pixelSize: Math.round(15 * field.view.uiScale)
      horizontalAlignment: Text.AlignHCenter
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
    anchors.left: parent.left
    anchors.leftMargin: field.view.fieldLeadingInset
    anchors.right: parent.right
    anchors.rightMargin: Math.round(70 * field.view.uiScale)
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    verticalAlignment: TextInput.AlignVCenter
    horizontalAlignment: TextInput.AlignLeft
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
    font.family: field.view.textFontFamily
    font.pixelSize: text.length > 0
      ? Math.max(1, Math.floor(field.view.passwordDotFontSize * field.passwordDotScale))
      : field.view.fieldFontSize
    font.letterSpacing: text.length > 0 ? field.view.passwordDotLetterSpacing * field.passwordDotScale : 0
    cursorVisible: activeFocus && field.view.showPasswordCursor && text.length > 0
    cursorDelegate: Rectangle {
      width: 2
      color: field.view.foreground
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
    font.family: field.view.textFontFamily
    font.pixelSize: field.view.fieldFontSize
    font.italic: field.view.errorState
    horizontalAlignment: Text.AlignLeft
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  Item {
    visible: field.chromeShown && field.view.showPassword
    width: Math.round(70 * field.view.uiScale)
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    opacity: field.view.authenticatingPassword ? 0.55 : (field.view.passwordText.length > 0 ? 1 : 0.9)

    Rectangle {
      anchors.centerIn: parent
      width: Math.round(38 * field.view.uiScale)
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
      width: Math.round(30 * field.view.uiScale)
      height: Math.round(26 * field.view.uiScale)
      // The submit arrow points along the reading direction, mirrored
      // around its own centre (a bare `width` inside Scale is the view's).
      transform: Scale { origin.x: submitArrow.width / 2; xScale: field.view.rightToLeft ? -1 : 1 }

      Rectangle {
        x: Math.round(2 * field.view.uiScale)
        width: Math.round(23 * field.view.uiScale)
        height: Math.max(1, Math.round(1.6 * field.view.uiScale))
        anchors.verticalCenter: parent.verticalCenter
        radius: height / 2
        color: field.view.foreground
      }

      Rectangle {
        x: Math.round(15 * field.view.uiScale)
        width: Math.round(10 * field.view.uiScale)
        height: Math.max(1, Math.round(1.6 * field.view.uiScale))
        anchors.verticalCenter: parent.verticalCenter
        transformOrigin: Item.Right
        rotation: 45
        radius: height / 2
        color: field.view.foreground
      }

      Rectangle {
        x: Math.round(15 * field.view.uiScale)
        width: Math.round(10 * field.view.uiScale)
        height: Math.max(1, Math.round(1.6 * field.view.uiScale))
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
    anchors.top: parent.bottom
    anchors.topMargin: Math.round(8 * field.view.uiScale)
    anchors.horizontalCenter: field.alignment === "center" ? parent.horizontalCenter : undefined
    anchors.left: field.alignment === "start" ? parent.left : undefined
    anchors.right: field.alignment === "end" ? parent.right : undefined
    width: field.alignment === "center" ? field.view.contentWidth : field.width
    visible: field.chromeShown && field.view.fingerprintUnavailable
    textFormat: Text.PlainText
    text: FoamyI18n.t("Fingerprint reader unavailable")
    color: field.view.foreground
    font.family: field.view.textFontFamily
    font.pixelSize: Math.round(13 * field.view.uiScale)
    horizontalAlignment: field.alignment === "start" ? Text.AlignLeft : field.alignment === "end" ? Text.AlignRight : Text.AlignHCenter
    wrapMode: Text.WordWrap
  }
}
