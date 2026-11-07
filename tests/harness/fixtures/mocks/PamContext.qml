import QtQuick
import Quickshell.Services.Pam
QtObject {
  id: pam
  property string config: ""
  property string user: ""
  property bool active: false
  property bool messageIsError: false
  property int starts: 0
  property bool responseRequired: false
  property int generation: 0
  // Report a failed password through both signals, as one PAM conversation may.
  property bool doubleReport: false
  signal completed(int result)
  signal error(int error)
  signal pamMessage()
  function start() {
    active = true
    starts++
    if (config === "omarchy-lock-fingerprint") return true
    Qt.callLater(function() { if (pam.active) pam.responseRequired = true })
    return true
  }
  function abort() { generation++; active = false; responseRequired = false }
  function respond(value) {
    responseRequired = false
    var attempt = generation
    Qt.callLater(function() {
      if (!pam.active || attempt !== generation) return
      pam.active = false
      if (value !== "test-password" && pam.doubleReport) pam.error(1)
      pam.completed(value === "test-password" ? PamResult.Success : PamResult.Failed)
    })
  }
}
