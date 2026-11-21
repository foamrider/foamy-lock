import QtQuick
import "kit"
import "elements"
import "Layout.js" as Layout
import "Greeter.js" as Greeter

// Foamy Lock's login screen (SDDM 0.21, Qt 6): the lock's look from the
// snapshot that Lock Studio copied (theme.conf's `snapshot`, see
// Greeter.js), drawn by the lock's own LockLayout and elements, with
// SDDM's login in place of the lock's PAM.
//
// SDDM makes one view per screen, each with its own Main.qml, sized to the
// screen (QQuickView::SizeRootObjectToView), and sets these context
// properties on each (src/greeter/GreeterApp.cpp, addViewForScreen()):
// `sddm` (login(), loginFailed), `userModel` (lastUser), `sessionModel`
// (lastIndex), `config` (theme.conf's [General]) and `primaryScreen`
// (QGuiApplication::primaryScreen() == this view's screen, set once when
// the view is made). Every screen draws the look. The account and the
// field's chrome show on the view whose window has the keys (Window.active)
// and on SDDM's primary screen, so feedback shows where the user types even
// after the focus or the primary monitor changes.
//
// Each view has its own QML engine, so views share no state. Only the view
// with the keys submits; SDDM answers every view (loginFailed). A second
// submission from another screen while the first is still being checked is
// dropped by SDDM (Auth already running), and that view then shows the
// first attempt's result.
//
// Whatever the snapshot holds, the screen keeps a password field: a
// snapshot that doesn't parse, or a look Layout.js rejects, shows the
// default preset in the theme colours (Greeter.fallbackEntry), and a look
// that doesn't fit the screen falls back as on the lock (LockLayout).
Item {
  id: root

  // One of userModel's users, by role name.
  component Account: QtObject {
    required property string name
    required property string realName
  }

  // SDDM's context properties, read once here.
  readonly property var greeter: sddm
  readonly property var users: userModel
  readonly property var sessions: sessionModel
  readonly property bool primary: primaryScreen
  readonly property var parsed: Greeter.parseSnapshot(config.snapshot)
  readonly property var snapshot: parsed.snapshot
  readonly property string lastUser: Greeter.loginUser(snapshot, String(users.lastUser || ""), firstAccount)

  // The copied picture beside this file, as a path (LockLayout makes the URL).
  readonly property string backgroundFile: snapshot.background ? decodeURIComponent(Qt.resolvedUrl("background.png").toString().replace(/^file:\/\//, "")) : ""
  readonly property var look: {
    var shown = Layout.parseLook(Greeter.lookEntry(snapshot, backgroundFile))
    if (shown.valid)
      return shown.look
    console.warn("Foamy Lock login screen: showing the default look:", shown.error)
    return Layout.parseLook(Greeter.fallbackEntry()).look
  }

  // userModel's real name for the last user ("" until known), and its
  // first user's name (the last resort for who logs in).
  property string lastUserRealName: ""
  property string firstAccount: ""

  function findRealName() {
    const first = accounts.count > 0 ? accounts.objectAt(0) as Account : null
    root.firstAccount = first ? first.name : ""
    for (let i = 0; i < accounts.count; i++) {
      const account = accounts.objectAt(i) as Account
      if (account && account.name === root.lastUser) {
        root.lastUserRealName = account.realName
        return
      }
    }
    root.lastUserRealName = ""
  }

  // The session Omarchy's theme picks: the uwsm one, else the last.
  function sessionIndex() {
    var names = []
    for (let i = 0; i < sessions.rowCount(); i++)
      names.push(sessions.data(sessions.index(i, 0), Qt.DisplayRole))
    return Greeter.sessionIndex(names, sessions.lastIndex)
  }

  function login(password) {
    view.failureMessage = ""
    view.authenticatingPassword = true
    greeter.login(root.lastUser, password, root.sessionIndex())
  }

  // SDDM refused the password: the field shows "Authentication failed (n)"
  // and takes the keys again, as on the lock.
  function loginFailed() {
    view.authenticatingPassword = false
    view.failedAttempts += 1
    view.failureMessage = "Authentication failed"
    Qt.callLater(view.forcePasswordFocus)
  }

  Component.onCompleted: {
    if (parsed.error !== "")
      console.warn("Foamy Lock login screen: " + parsed.error + "; showing the default look")
  }

  Binding {
    target: FoamyPalette
    property: "colors"
    value: root.snapshot.colors
  }
  Binding {
    target: FoamyI18n
    property: "strings"
    value: root.snapshot.strings
  }
  Binding {
    target: FoamyI18n
    property: "language"
    value: root.snapshot.language
  }
  Binding {
    target: FoamyI18n
    property: "formatLocale"
    value: root.snapshot.formatLocale
  }
  Binding {
    target: FoamyI18n
    property: "rightToLeft"
    value: root.snapshot.rightToLeft
  }

  Connections {
    target: root.greeter
    function onLoginFailed() {
      root.loginFailed()
    }
  }

  // userModel's users by role name (name, realName), to find lastUser's.
  Instantiator {
    id: accounts
    model: root.users
    delegate: Account {}
    onObjectAdded: root.findRealName()
    onObjectRemoved: root.findRealName()
  }
  onLastUserChanged: findRealName()

  FoamyWallClock {
    id: clock
  }

  LockLayout {
    id: view
    objectName: "greeterView"
    anchors.fill: parent

    themeBackground: FoamyPalette.pick("background")
    themeForeground: FoamyPalette.pick("foreground")
    accent: FoamyPalette.pick("accent")
    themeMuted: FoamyPalette.pick("muted")
    themeUrgent: FoamyPalette.pick("urgent")
    lockBackground: FoamyPalette.pick("lockBackground")
    lockBorder: FoamyPalette.pick("lockBorder")
    lockBorderError: FoamyPalette.pick("lockBorderError")
    lockPlaceholder: FoamyPalette.pick("lockPlaceholder")
    lockSelection: FoamyPalette.pick("lockSelection")
    lockText: FoamyPalette.pick("lockText")
    lockTextError: FoamyPalette.pick("lockTextError")
    lockThemed: root.snapshot.lockThemed
    withheld: Greeter.WITHHELD

    // The status element's readings, which LockView takes from its services:
    // none here. The status is withheld, but its hidden element still
    // binds to them.
    readonly property bool hasBattery: false
    readonly property int batteryPercentage: 0
    readonly property string networkLabel: ""
    readonly property string networkIcon: ""
    readonly property bool hasVolume: false
    readonly property int volumePercent: 0
    readonly property bool volumeMuted: false
    readonly property bool hasBluetooth: false
    readonly property bool bluetoothEnabled: false
    readonly property int bluetoothConnected: 0
    readonly property string keyboardLayout: ""
    readonly property real systemUptime: -1
    readonly property string systemLoad: ""
    readonly property real memoryTotal: 0
    readonly property real memoryAvailable: 0

    function batteryIcon(level) {
      return ""
    }

    look: root.look
    // SDDM's primary screen, and whichever view has the keys now.
    primary: root.primary || Window.active
    now: clock.date
    timeFormat: root.snapshot.timeFormat
    // No account without a user to log in.
    showUserInfo: root.snapshot.showUserInfo && root.lastUser !== ""
    userName: root.lastUser
    userDisplayName: root.lastUserRealName
    avatarPath: Greeter.showsAvatar(root.snapshot, root.lastUser) ? decodeURIComponent(Qt.resolvedUrl("avatar.png").toString().replace(/^file:\/\//, "")) : ""
    backgroundPath: root.backgroundFile
    // The helper already blurred the copied picture to the look's amount.
    backgroundPrepared: true
    // A login, not an unlock.
    unlockHintText: FoamyI18n.t("Enter password")
    // SDDM gives no feedback on a fingerprint: the field asks for the password.
    fingerprintConfigured: false
    fingerprintUnavailable: false

    onPasswordTextEdited: function (password) {
      passwordText = password
    }
    onClearFailureRequested: failureMessage = ""
    onSubmitPassword: function (password) {
      root.login(password)
    }
    onLayoutFellBack: function (error, preset) {
      console.warn("Foamy Lock login screen: the look doesn't fit (" + error + "); showing " + preset)
    }
  }
}
