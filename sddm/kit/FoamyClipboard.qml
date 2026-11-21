import QtQuick

// The login screen's FoamyClipboard. The greeter runs before any user
// session, so there is no clipboard to paste a password from: start() takes
// no read (it returns false, as for a busy reader) and neither signal
// follows. The members are foamy-kit's FoamyClipboard's, which reads the
// clipboard through clipboard.sh and Quickshell.Io (not in the greeter).
QtObject {
  property string clipboardScript: ""
  readonly property bool busy: false

  signal read(string text)
  signal failed(string message)

  function start(primary) {
    return false
  }

  function cancel() {
  }
}
