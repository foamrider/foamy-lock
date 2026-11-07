// The real view is exercised separately by the render and parity tests; no
// session-lock surface is created here.
import QtQuick
Item {
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool fingerprintUnavailable: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property var activePlayer: null
  property string artworkPath: ""
  property bool showUserInfo: true
  property string timeFormat: "24h"
  property string passwordText: ""
  property string userName: ""
  property string userDisplayName: ""
  property string avatarPath: ""
  property int avatarVersion: 0
  signal passwordTextEdited(string password)
  signal submitPassword(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  property var look: null
  property bool primary: true
  signal artworkFailed(string path)
  signal layoutFellBack(string error, string preset)
}
