// Password shell: the real LockView's password field, driven with real key
// and mouse events (QtTest's TestEvent), against a wl-paste stand-in on
// PATH (password.rs). The editor types as Omarchy's lock does (an editable
// TextInput: the input method, editing keys, undo); paste never goes through
// Qt but through kit/clipboard.sh. Written into a temporary app by the
// harness.
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

ShellRoot {
  id: shell
  property int checks: 0
  property int failures: 0
  property var submitted: []
  property int stage: 0
  property double since: 0
  property string cancelledPid: ""
  readonly property string state: Quickshell.env("TEST_CLIPBOARD_STATE")

  function check(ok, label) {
    checks++
    if (ok) {
      console.log("PASS: " + label)
    } else {
      failures++
      console.log("FOAMY FAIL " + label)
    }
  }

  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 1280
    implicitHeight: 720
    color: "#182638"
    LockView {
      id: view
      width: 1280
      height: 720
      userName: "foamy"
      userDisplayName: "Foamy User"
      fingerprintConfigured: false
      loadBackground: false
      onPasswordTextEdited: function (value) {
        passwordText = value
      }
      onClearFailureRequested: failureMessage = ""
      onSubmitPassword: function (value) {
        shell.submitted = shell.submitted.concat([value])
      }
    }
  }

  TestEvent {
    id: ev
  }

  // Sets what the stand-in wl-paste does next (password.rs).
  Process {
    id: fixture
    property bool done: false
    onExited: fixture.done = true
  }
  function setMode(mode) {
    fixture.done = false
    fixture.command = ["clipboard-fixture", mode]
    fixture.running = true
  }
  // The stand-in's argv and pid of the last paste (QML_XHR_ALLOW_FILE_READ=1).
  function readFile(path) {
    var request = new XMLHttpRequest()
    request.open("GET", "file://" + path, false)
    request.send(null)
    return String(request.responseText || "")
  }

  function findNamed(item, name) {
    if (item.objectName === name)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findNamed(item.children[i], name)
      if (found)
        return found
    }
    return null
  }
  readonly property var input: findNamed(view, "passwordInput")
  readonly property var field: findNamed(view, "inputField")
  readonly property var notice: findNamed(view, "fingerprintNotice")

  function key(code, modifiers) {
    ev.keyClick(code, modifiers || Qt.NoModifier, -1)
  }
  function type(text) {
    for (var i = 0; i < text.length; i++)
      ev.keyClickChar(text.charAt(i), Qt.NoModifier, -1)
  }
  function paste() {
    shell.since = Date.now()
    key(Qt.Key_V, Qt.ControlModifier)
  }
  function elapsed() {
    return Date.now() - shell.since
  }
  function noticeSays(message) {
    return notice.visible && notice.text === message
  }
  function finish() {
    console.log("FOAMY RESULT " + checks + " checks, " + failures + " failed")
    console.log("FOAMY DONE")
    Qt.quit()
  }

  function next() {
    stage++
    since = Date.now()
  }

  Timer {
    interval: 100
    repeat: true
    running: true
    onTriggered: {
      if (shell.since && shell.elapsed() > 15000) {
        shell.check(false, "timed out at stage " + shell.stage)
        shell.finish()
        stop()
        return
      }
      shell.tick()
    }
  }

  function tick() {
    switch (stage) {
    case 0:
      if (!input || !window.visible)
        return
      view.forcePasswordFocus()
      next()
      return
    case 1:
      check(input.activeFocus, "the editor has the keyboard")
      check(input.readOnly === false, "the editor is editable, so the input method types into it as in Omarchy's lock")
      // Typing and editing keys, as a user types them.
      type("hunter2")
      check(view.passwordText === "hunter2", "typing reaches the view: " + view.passwordText)
      key(Qt.Key_Left)
      key(Qt.Key_Left)
      type("X")
      check(view.passwordText === "hunteXr2", "the cursor moves, and typing inserts at it: " + view.passwordText)
      key(Qt.Key_Backspace)
      check(view.passwordText === "hunter2", "Backspace deletes before the cursor: " + view.passwordText)
      key(Qt.Key_Delete)
      check(view.passwordText === "hunte2", "Delete deletes after it: " + view.passwordText)
      key(Qt.Key_Home, Qt.ShiftModifier)
      type("z")
      check(view.passwordText === "z2", "typing replaces a selection: " + view.passwordText)
      key(Qt.Key_Z, Qt.ControlModifier)
      check(view.passwordText === "hunte2", "Ctrl+Z undoes, as Qt's editor does: " + view.passwordText)
      key(Qt.Key_Escape)
      check(view.passwordText === "", "Escape clears: " + view.passwordText)
      setMode("normal")
      next()
      return
    case 2:
      if (!fixture.done)
        return
      // Qt's own clipboard holds other text: Qt's paste must never run.
      Quickshell.clipboardText = "QT-PASTE"
      type("x")
      paste()
      check(view.passwordText === "x", "a paste waits for the bounded read")
      next()
      return
    case 3:
      if (view.passwordText === "x")
        return
      check(view.passwordText === "xs3cret" && input.cursorPosition === 7, "Ctrl+V pastes through the bounded read at the cursor, never through Qt: " + view.passwordText)
      check(readFile(state + ".args").indexOf("--primary") < 0, "Ctrl+V reads the clipboard, not the primary selection")
      key(Qt.Key_Escape)
      shell.since = Date.now()
      key(Qt.Key_Insert, Qt.ShiftModifier)
      next()
      return
    case 4:
      if (view.passwordText === "")
        return
      check(view.passwordText === "s3cret", "Shift+Insert pastes through it too: " + view.passwordText)
      key(Qt.Key_Escape)
      var point = input.mapToItem(window.contentItem, input.width / 2, input.height / 2)
      ev.mouseClick(window.contentItem, point.x, point.y, Qt.MiddleButton, Qt.NoModifier, -1)
      next()
      return
    case 5:
      if (view.passwordText === "")
        return
      check(view.passwordText === "s3cret" && readFile(state + ".args").indexOf("--primary") >= 0, "a middle click pastes the primary selection: " + readFile(state + ".args"))
      key(Qt.Key_Escape)
      setMode("stream")
      next()
      return
    case 6:
      if (!fixture.done)
        return
      paste()
      next()
      return
    case 7:
      if (!notice.visible)
        return
      check(noticeSays("Clipboard text is too large or contains invalid characters.") && view.passwordText === "", "an endless clipboard is refused at the cap, on the notice line: " + notice.text)
      type("q")
      check(!notice.visible && view.passwordText === "q", "the next edit clears the notice")
      key(Qt.Key_Escape)
      setMode("stall")
      next()
      return
    case 8:
      if (!fixture.done)
        return
      paste()
      next()
      return
    case 9:
      if (!notice.visible)
        return
      check(noticeSays("Clipboard paste timed out. Copy the text again.") && elapsed() < 5000, "a stalled clipboard ends at the 2 s deadline, after " + elapsed() + " ms")
      type("w")
      key(Qt.Key_Escape)
      setMode("delayed")
      next()
      return
    case 10:
      if (!fixture.done)
        return
      // Type and delete a character before the delayed read answers.
      paste()
      type("y")
      key(Qt.Key_Backspace)
      next()
      return
    case 11:
      if (elapsed() < 1200)
        return
      check(view.passwordText === "" && !notice.visible, "a paste that answers after an edit (even an undone one) is dropped: " + JSON.stringify(view.passwordText))
      // Esc in an empty field changes no text: it must still stop the paste.
      paste()
      key(Qt.Key_Escape)
      next()
      return
    case 12:
      if (elapsed() < 1200)
        return
      check(view.passwordText === "" && !notice.visible, "Esc stops a paste in flight, even in an empty field: " + JSON.stringify(view.passwordText))
      setMode("ignore")
      next()
      return
    case 13:
      if (!fixture.done)
        return
      shell.cancelledPid = readFile(state + ".pid")
      paste()
      next()
      return
    case 14:
      // Authentication starts mid-read: the editor is disabled, the read stops.
      var pid = readFile(state + ".pid")
      if (pid === shell.cancelledPid)
        return
      shell.cancelledPid = pid
      view.authenticatingPassword = true
      check(!input.enabled && field.pasteRevision === -1, "disabling the editor cancels its paste")
      console.log("FOAMY PASTE PID " + pid)
      next()
      return
    case 15:
      if (elapsed() < 2500)
        return
      view.authenticatingPassword = false
      check(view.passwordText === "" && !notice.visible, "a cancelled paste never arrives: " + JSON.stringify(view.passwordText))
      view.forcePasswordFocus()
      next()
      return
    case 16:
      if (!input.activeFocus)
        return
      type("open")
      key(Qt.Key_Return)
      check(shell.submitted.length === 1 && shell.submitted[0] === "open" && view.passwordText === "", "Enter submits the typed password: " + JSON.stringify(shell.submitted))
      finish()
      return
    }
  }
}
