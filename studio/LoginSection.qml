pragma ComponentBehavior: Bound
import QtQuick
import "kit"

// The login screen page (Library → Scene → Login screen): the state of the
// SDDM login screen against the applied look, Copy to login screen and
// Restore Omarchy login screen (each asks first: StudioWindow's dialogs),
// what is running, and how the last copy or restore went. LoginScreen.qml
// owns the state and the processes; this only shows them.
Column {
  id: section

  // The StudioWindow: login (LoginScreen), unapplied, askLogin().
  property var app: null
  readonly property var login: app ? app.login : null
  readonly property string loginState: login ? login.sectionState : "checking"
  readonly property alias copyButton: copyButton
  readonly property alias restoreButton: restoreButton

  spacing: FoamyStyle.gap

  // The state in words.
  function stateText() {
    var status = login ? login.status : null
    switch (loginState) {
    case "checking":
      return FoamyI18n.t("studio.login.state.checking")
    case "error":
      return FoamyI18n.t("studio.login.state.error", reasonText(login.statusError))
    case "overridden":
      if (!status.theme)
        return FoamyI18n.t("studio.login.state.overriddenBuiltIn")
      return status.themeSetIn ? FoamyI18n.t("studio.login.state.overriddenIn", [status.theme, status.themeSetIn]) : FoamyI18n.t("studio.login.state.overridden", status.theme)
    case "not-installed":
    case "current":
    case "outdated":
    case "installed":
    case "broken":
      return FoamyI18n.t("studio.login.state." + loginState)
    }
    return ""
  }

  // What runs now ("" when nothing does).
  function busyText() {
    if (!login || !login.busy || login.op === "check")
      return ""
    if (login.step === "publish" || login.step === "restore")
      return FoamyI18n.t("studio.login.busy.password")
    return login.step === "status" ? FoamyI18n.t("studio.login.busy.checking") : FoamyI18n.t("studio.login.busy.preparing")
  }

  // A failure's code in words.
  function reasonText(code) {
    if (code === "helper-unavailable")
      return FoamyI18n.t("studio.helperUnavailable")
    var known = ["timeout", "start-failed", "unexpected", "not-possible", "BACKGROUND_MISSING", "NOT_OURS", "PUBLISHER_MISSING", "BUNDLE_INVALID", "NO_RUNTIME_DIR", "BUSY", "IO", "INVALID_REQUEST"]
    if (known.indexOf(code) !== -1)
      return FoamyI18n.t("studio.login.reason." + code)
    if (/^(background|avatar|video)-/.test(code) || code === "decoder-unavailable")
      return FoamyI18n.t("studio.login.reason.picture", code)
    return code
  }

  // The last copy or restore in words ("" without one).
  function resultText() {
    var result = login ? login.result : null
    if (!result || result.state !== loginState)
      return ""
    var action = result.action === "restore" ? "restore" : "copy"
    switch (result.outcome) {
    case "done":
      return FoamyI18n.t("studio.login.result." + action + ".done")
    case "cancelled":
    case "denied":
      return FoamyI18n.t("studio.login.result." + result.outcome)
    case "unconfirmed":
      return FoamyI18n.t("studio.login.result." + action + ".unconfirmed", reasonText(result.code))
    }
    // Refused before the publisher ran, or by the publisher itself (its
    // codes): nothing changed. A publisher that ended otherwise (killed,
    // an exit it never gives) may have changed something: the state
    // above, read again, says what the login screen has now.
    var nothing = result.before || /^[A-Z_]+$/.test(result.code)
    return FoamyI18n.t("studio.login.result." + action + (nothing ? ".failedNothing" : ".failed"), reasonText(result.code))
  }

  readonly property string result: resultText()
  // Done or cancelled is no problem; anything else is.
  readonly property bool resultGood: !!login && !!login.result && (login.result.outcome === "done" || login.result.outcome === "cancelled")

  PaneNote {
    objectName: "studioLoginState"
    color: section.loginState === "error" ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
    text: section.stateText()
    Accessible.role: section.loginState === "error" ? Accessible.AlertMessage : Accessible.StaticText
  }
  // The applied look is copied, never the draft.
  PaneNote {
    objectName: "studioLoginUnapplied"
    text: section.app && section.app.unapplied && section.loginState !== "error" ? FoamyI18n.t("studio.login.unapplied") : ""
  }
  // Foamy's theme is in use, but this look couldn't be compared with it.
  PaneNote {
    objectName: "studioLoginCompare"
    color: FoamyPalette.onSurface(FoamyPalette.warning)
    text: section.loginState === "installed" && section.login && section.login.compareError && !section.login.busy ? FoamyI18n.t("studio.login.compareFailed", section.reasonText(section.login.compareError)) : ""
  }

  FoamyButton {
    id: copyButton
    objectName: "studioLoginCopy"
    width: parent.width
    focusable: true
    focus: true
    kind: "primary"
    visible: section.loginState !== "error" && section.loginState !== "hidden"
    enabled: !!section.login && section.login.canCopy
    busy: !!section.login && section.login.op === "copy"
    text: FoamyI18n.t("studio.login.copy")
    onClicked: section.app.askLogin("copy")
  }
  FoamyButton {
    id: restoreButton
    objectName: "studioLoginRestore"
    width: parent.width
    focusable: true
    visible: ["current", "outdated", "installed", "overridden", "broken"].indexOf(section.loginState) !== -1
    enabled: !!section.login && section.login.canRestore
    busy: !!section.login && section.login.op === "restore"
    text: FoamyI18n.t("studio.login.restore")
    onClicked: section.app.askLogin("restore")
  }
  FoamyButton {
    objectName: "studioLoginRetry"
    focusable: true
    visible: section.loginState === "error"
    enabled: !!section.login && !section.login.busy
    busy: !!section.login && section.login.op === "check"
    text: FoamyI18n.t("studio.login.retry")
    onClicked: section.login.refresh()
  }

  PaneNote {
    objectName: "studioLoginBusy"
    text: section.busyText()
  }
  PaneNote {
    objectName: "studioLoginResult"
    color: section.resultGood ? FoamyPalette.secondaryText : FoamyPalette.onSurface(FoamyPalette.error)
    text: section.login && section.login.busy && section.login.op !== "check" ? "" : section.result
    Accessible.role: section.resultGood ? Accessible.StaticText : Accessible.AlertMessage
  }
}
