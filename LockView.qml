import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Networking
import Quickshell.Services.UPower
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
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
  property bool syncingPasswordText: false
  property string userName: ""
  property string userDisplayName: ""
  property string avatarPath: ""
  property int avatarVersion: 0

  readonly property string displayName: String(userDisplayName || "").trim()
    || String(userName || "").trim()
  readonly property string textFontFamily: "Adwaita Sans"
  readonly property string iconFontFamily: "JetBrainsMono Nerd Font"
  readonly property string placeholderText: "Enter password"
  readonly property real uiScale: Math.max(0.82, Math.min(1.12, height / 1080))
  readonly property real contentWidth: Math.min(Math.round(560 * uiScale), width - Math.round(64 * uiScale))
  readonly property real fieldWidth: Math.min(Math.round(320 * uiScale), contentWidth)
  readonly property int fieldHeight: Math.round(51 * uiScale)
  readonly property int fieldLeadingInset: Math.round(24 * uiScale)
  readonly property int fieldFontSize: Math.round(18 * uiScale)
  readonly property int passwordDotFontSize: Math.round(17 * uiScale)
  readonly property int passwordDotLetterSpacing: Math.round(2 * uiScale)
  readonly property color foreground: Qt.rgba(0.98, 0.98, 1, 0.96)
  readonly property color secondary: Qt.rgba(0.94, 0.95, 1, 0.68)
  readonly property color glass: Qt.rgba(0.025, 0.035, 0.065, 0.34)
  readonly property color glassBorder: Qt.rgba(0.95, 0.96, 1, 0.18)
  readonly property bool hasMedia: activePlayer !== null
    && (String(activePlayer.trackTitle || "") !== "" || String(activePlayer.trackArtist || "") !== "")
  readonly property var batteryDevice: UPower.displayDevice
  readonly property bool hasBattery: batteryDevice
    && batteryDevice.ready
    && batteryDevice.isPresent
    && batteryDevice.isLaptopBattery
  readonly property int batteryPercentage: hasBattery ? Math.round(Number(batteryDevice.percentage || 0) * 100) : 0
  readonly property bool wiredConnected: hasConnectedDevice(DeviceType.Wired)
  readonly property string networkLabel: networkStatusLabel()
  readonly property string networkIcon: wiredConnected ? "" : (networkLabel === "Offline" ? "󰤮" : "")
  readonly property var userLocale: Qt.locale(environmentLocaleName())
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  // Keep the editor focused while invisible so the first character is retained.
  readonly property bool compactLayout: width < 1100 * uiScale
  readonly property bool showPassword: passwordText.length > 0 || authenticatingPassword || errorState

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  signal artworkFailed(string path)

  function environmentLocaleName() {
    var raw = Quickshell.env("LC_TIME") || Quickshell.env("LC_ALL") || Quickshell.env("LANG") || "C"
    return String(raw).split(".")[0].split("@")[0]
  }

  // Cache-bust profile and wallpaper images when their files change in place.
  function fileUrl(path, version) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + Number(version || 0)
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  function submitCurrentPassword() {
    if (!inputEnabled || authenticatingPassword || passwordText.length === 0) return
    var submitted = passwordText
    passwordTextEdited("")
    submitPassword(submitted)
  }

  function networkStatusLabel() {
    if (Networking.connectivity === NetworkConnectivity.Full) return "Connected"
    if (Networking.connectivity === NetworkConnectivity.Portal) return "Sign-in required"
    if (Networking.connectivity === NetworkConnectivity.Limited) return "Limited connection"
    if (Networking.connectivity === NetworkConnectivity.None) return "Offline"

    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].connected) return "Connected"
    }
    return "Offline"
  }

  function hasConnectedDevice(deviceType) {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].type === deviceType && devices[i].connected) return true
    }
    return false
  }

  function batteryIcon(level) {
    var device = root.batteryDevice
    if (!device) return ""

    var index = Math.max(0, Math.min(9, Math.floor(level / 10)))
    var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
    var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

    if (!UPower.onBattery && device.state === UPowerDeviceState.Charging) return chargingIcons[index]
    if (!UPower.onBattery
        && (device.state === UPowerDeviceState.FullyCharged || device.state === UPowerDeviceState.PendingCharge)) return "󱟢"
    return defaultIcons[index]
  }

  function runMediaAction(action) {
    if (!activePlayer) return
    Model.runMediaAction(activePlayer, action)
    wakeRequested()
    forcePasswordFocus()
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  component LineIcon: Image {
    property string pathData: ""
    source: "data:image/svg+xml," + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">'
      + '<path d="' + pathData + '" fill="none" stroke="white" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>')
    sourceSize.width: Math.ceil(width * 2)
    sourceSize.height: Math.ceil(height * 2)
  }

  component FingerprintIcon: Canvas {
    property color lineColor: root.foreground

    antialiasing: true
    onLineColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var context = getContext("2d")
      var centerX = width / 2
      var centerY = height / 2
      var unit = Math.min(width, height)
      context.clearRect(0, 0, width, height)
      context.strokeStyle = lineColor
      context.fillStyle = lineColor
      context.lineWidth = Math.max(1.4, unit * 0.075)
      context.lineCap = "round"
      context.lineJoin = "round"

      context.beginPath()
      context.arc(centerX, centerY + unit * 0.02, unit * 0.34, Math.PI * 1.06, Math.PI * 1.94)
      context.stroke()
      context.beginPath()
      context.arc(centerX, centerY + unit * 0.08, unit * 0.24, Math.PI * 1.04, Math.PI * 1.96)
      context.stroke()
      context.beginPath()
      context.arc(centerX, centerY + unit * 0.13, unit * 0.13, Math.PI * 1.02, Math.PI * 1.98)
      context.stroke()
      context.beginPath()
      context.moveTo(centerX - unit * 0.31, centerY + unit * 0.12)
      context.quadraticCurveTo(centerX - unit * 0.25, centerY + unit * 0.38, centerX - unit * 0.09, centerY + unit * 0.45)
      context.moveTo(centerX + unit * 0.31, centerY + unit * 0.12)
      context.quadraticCurveTo(centerX + unit * 0.25, centerY + unit * 0.38, centerX + unit * 0.09, centerY + unit * 0.45)
      context.stroke()
    }
  }

  TextMetrics {
    id: dotMetrics
    font.family: root.textFontFamily
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath, root.backgroundVersion) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    // A light scrim preserves wallpaper detail while keeping white type legible.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0.005, 0.01, 0.025, 0.25)
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    SystemClock {
      id: lockClock
      precision: SystemClock.Minutes
    }

    Column {
      id: mainColumn
      z: 2
      width: root.contentWidth
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Math.round(42 * root.uiScale), Math.round(parent.height * 0.09))
      // Offset the clock font’s top bearing to bring the visible numerals closer to the date.
      spacing: Math.round(-20 * root.uiScale)

      Text {
        textFormat: Text.PlainText
        id: dateLabel
        width: parent.width
        text: lockClock.date.toLocaleString(root.userLocale, "dddd, d MMMM")
        color: root.foreground
        font.family: "URW Gothic"
        font.pixelSize: Math.round(30 * root.uiScale)
        font.weight: Font.Normal
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        id: clockLabel
        width: parent.width
        text: Qt.formatDateTime(lockClock.date, root.timeFormat === "12h" ? "h:mm AP" : "HH:mm")
        fontSizeMode: Text.Fit
        minimumPixelSize: Math.round(48 * root.uiScale)
        color: root.foreground
        font.family: "URW Gothic"
        font.pixelSize: Math.round(192 * root.uiScale)
        font.weight: Font.Normal
        horizontalAlignment: Text.AlignHCenter
      }
    }

    Column {
      id: loginColumn
      width: root.contentWidth
      anchors.horizontalCenter: parent.horizontalCenter
      // Reserve authentication space independently of media and input state.
      y: Math.min(root.height * 0.65, root.height - height - (root.compactLayout ? 140 : 36) * root.uiScale)
      spacing: Math.round(14 * root.uiScale)

      Item {
        id: identityBlock
        visible: root.showUserInfo
        width: parent.width
        height: avatar.height + nameLabel.anchors.topMargin + nameLabel.height

        Rectangle {
          id: avatar
          width: Math.round(84 * root.uiScale)
          height: width
          radius: width / 2
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          color: Qt.rgba(0.025, 0.03, 0.055, 0.55)

          Item {
            id: avatarMask
            anchors.fill: parent
            visible: false
            layer.enabled: true

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: "white"
            }
          }

          Image {
            id: avatarImage
            anchors.fill: parent
            source: root.avatarPath ? root.fileUrl(root.avatarPath, root.avatarVersion) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            smooth: true
            // The service provides a Lanczos-filtered runtime thumbnail so Qt
            // only performs the small final scale to the physical output.
            sourceSize.width: 256
            sourceSize.height: 256
            visible: false
          }

          MultiEffect {
            anchors.fill: parent
            source: avatarImage
            visible: avatarImage.status === Image.Ready
            maskEnabled: true
            maskSource: avatarMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 0.05
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: avatarImage.status !== Image.Ready
            text: root.displayName.length > 0 ? root.displayName.charAt(0).toLocaleUpperCase() : "?"
            color: root.foreground
            font.family: root.textFontFamily
            font.pixelSize: Math.round(34 * root.uiScale)
            font.weight: Font.Light
          }

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.22)
          }
        }

        Text {
          textFormat: Text.PlainText
          id: nameLabel
          anchors.top: avatar.bottom
          anchors.topMargin: Math.round(7 * root.uiScale)
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.round(34 * root.uiScale)
          text: root.displayName
          color: root.foreground
          font.family: root.textFontFamily
          font.pixelSize: Math.round(20 * root.uiScale)
          font.weight: Font.Normal
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }

      Rectangle {
        id: inputField
        width: root.fieldWidth
        x: Math.round((parent.width - width) / 2)
        height: root.fieldHeight
        radius: height / 2
        color: root.showPassword ? root.glass : "transparent"
        border.width: root.showPassword ? 1 : 0
        border.color: root.errorState ? Color.lock.borderError : root.glassBorder
        clip: true

        Row {
          anchors.centerIn: parent
          spacing: Math.round(10 * root.uiScale)
          visible: !root.showPassword

          FingerprintIcon {
            width: Math.round(26 * root.uiScale)
            height: width
            anchors.verticalCenter: parent.verticalCenter
            visible: root.fingerprintConfigured
          }

          Text {
            textFormat: Text.PlainText
            text: root.fingerprintConfigured ? "Use fingerprint or enter password" : "Enter password to unlock"
            color: root.foreground
            font.family: root.textFontFamily
            font.pixelSize: Math.round(15 * root.uiScale)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        TextInput {
          id: passwordInput
          objectName: "passwordInput"
          opacity: root.showPassword ? 1 : 0
          anchors.left: parent.left
          anchors.leftMargin: root.fieldLeadingInset
          anchors.right: parent.right
          anchors.rightMargin: Math.round(70 * root.uiScale)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          verticalAlignment: TextInput.AlignVCenter
          horizontalAlignment: TextInput.AlignLeft
          activeFocusOnPress: true
          clip: true
          enabled: root.inputEnabled && !root.authenticatingPassword
          readOnly: root.authenticatingPassword
          echoMode: TextInput.Password
          passwordCharacter: "\u25CF"
          passwordMaskDelay: 0
          color: root.foreground
          selectionColor: Qt.rgba(1, 1, 1, 0.25)
          selectedTextColor: root.foreground
          font.family: root.textFontFamily
          font.pixelSize: text.length > 0
            ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale))
            : root.fieldFontSize
          font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
          cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
          cursorDelegate: Rectangle {
            width: 2
            color: root.foreground
            visible: passwordInput.cursorVisible
          }

          onTextChanged: {
            if (!root.syncingPasswordText) root.passwordTextEdited(text)
            if (text.length > 0) root.wakeRequested()
            if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
          }

          onAccepted: root.submitCurrentPassword()

          Keys.onPressed: function(event) {
            root.wakeRequested()
            if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
              root.passwordTextEdited("")
              root.clearFailureRequested()
              event.accepted = true
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.fill: passwordInput
          text: root.authenticatingPassword
            ? "Checking…"
            : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
          visible: root.showPassword && passwordInput.text.length === 0
          color: root.authenticatingPassword
            ? root.foreground
            : (root.errorState ? Color.lock.textError : root.secondary)
          font.family: root.textFontFamily
          font.pixelSize: root.fieldFontSize
          font.italic: root.errorState
          horizontalAlignment: Text.AlignLeft
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }

        Item {
          visible: root.showPassword
          width: Math.round(70 * root.uiScale)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          opacity: root.authenticatingPassword ? 0.55 : (root.passwordText.length > 0 ? 1 : 0.9)

          Rectangle {
            anchors.centerIn: parent
            width: Math.round(38 * root.uiScale)
            height: width
            radius: width / 2
            color: submitMouse.containsMouse && submitMouse.enabled
              ? Qt.rgba(1, 1, 1, 0.1)
              : "transparent"
          }

          Item {
            anchors.centerIn: parent
            width: Math.round(30 * root.uiScale)
            height: Math.round(26 * root.uiScale)

            Rectangle {
              x: Math.round(2 * root.uiScale)
              width: Math.round(23 * root.uiScale)
              height: Math.max(1, Math.round(1.6 * root.uiScale))
              anchors.verticalCenter: parent.verticalCenter
              radius: height / 2
              color: root.foreground
            }

            Rectangle {
              x: Math.round(15 * root.uiScale)
              width: Math.round(10 * root.uiScale)
              height: Math.max(1, Math.round(1.6 * root.uiScale))
              anchors.verticalCenter: parent.verticalCenter
              transformOrigin: Item.Right
              rotation: 45
              radius: height / 2
              color: root.foreground
            }

            Rectangle {
              x: Math.round(15 * root.uiScale)
              width: Math.round(10 * root.uiScale)
              height: Math.max(1, Math.round(1.6 * root.uiScale))
              anchors.verticalCenter: parent.verticalCenter
              transformOrigin: Item.Right
              rotation: -45
              radius: height / 2
              color: root.foreground
            }
          }

          MouseArea {
            id: submitMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.inputEnabled && !root.authenticatingPassword && root.passwordText.length > 0
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.submitCurrentPassword()
          }
        }
      }

    }

    Rectangle {
      id: mediaRow
      width: Math.min(Math.round(470 * root.uiScale), root.width - 48 * root.uiScale)
      height: Math.round(92 * root.uiScale)
      anchors.left: parent.left
      // Stack below authentication on narrow displays to avoid overlap.
      anchors.leftMargin: root.compactLayout
        ? Math.round((root.width - width) / 2)
        : Math.round(32 * root.uiScale)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.round(32 * root.uiScale)
      visible: root.hasMedia
      radius: Math.round(22 * root.uiScale)
      color: root.glass
      border.width: 1
      border.color: root.glassBorder

      Rectangle {
        id: albumArt
        width: Math.round(64 * root.uiScale)
        height: width
        radius: Math.round(9 * root.uiScale)
        anchors.left: parent.left
        anchors.leftMargin: Math.round(14 * root.uiScale)
        anchors.verticalCenter: parent.verticalCenter
        color: Qt.rgba(0.025, 0.035, 0.065, 0.55)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12)
        clip: true

        Image {
          id: artworkImage
          objectName: "artworkImage"
          anchors.fill: parent
          // Only the isolated helper's fixed-size thumbnail reaches Qt.
          source: root.artworkPath ? root.fileUrl(root.artworkPath, 0) : ""
          sourceSize.width: 256
          sourceSize.height: 256
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          visible: status === Image.Ready
          onStatusChanged: if (status === Image.Error) root.artworkFailed(root.artworkPath)
        }

        Text {
          objectName: "artworkFallback"
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: artworkImage.status !== Image.Ready
          text: "󰝚"
          color: root.secondary
          opacity: 0.78
          font.family: root.iconFontFamily
          font.pixelSize: Math.round(20 * root.uiScale)
          font.weight: Font.Light
        }
      }

      Column {
        id: trackInfo
        anchors.left: albumArt.right
        anchors.leftMargin: Math.round(17 * root.uiScale)
        anchors.right: mediaControls.left
        anchors.rightMargin: Math.round(16 * root.uiScale)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(3 * root.uiScale)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.activePlayer ? String(root.activePlayer.trackTitle || "") : ""
          color: root.foreground
          font.family: root.textFontFamily
          font.pixelSize: Math.round(17 * root.uiScale)
          font.weight: Font.Medium
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.activePlayer ? String(root.activePlayer.trackArtist || "") : ""
          color: root.secondary
          font.family: root.textFontFamily
          font.pixelSize: Math.round(15 * root.uiScale)
          font.weight: Font.Light
          elide: Text.ElideRight
        }
      }

      Row {
        id: mediaControls
        anchors.right: parent.right
        anchors.rightMargin: Math.round(12 * root.uiScale)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(5 * root.uiScale)

        Item {
          width: Math.round(42 * root.uiScale)
          height: width
          opacity: root.activePlayer && root.activePlayer.canGoPrevious ? 1 : 0.38

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: previousMouse.containsMouse && previousMouse.enabled
              ? Qt.rgba(1, 1, 1, 0.1)
              : "transparent"
          }

          LineIcon {
            anchors.centerIn: parent
            width: Math.round(21 * root.uiScale)
            height: width
            pathData: "M6 5v14 M19 5 8 12l11 7Z"
            opacity: 0.9
          }

          MouseArea {
            id: previousMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.activePlayer && root.activePlayer.canGoPrevious
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.runMediaAction("previous")
          }
        }

        Item {
          width: Math.round(46 * root.uiScale)
          height: width
          opacity: root.activePlayer
            && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause) ? 1 : 0.38

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: playMouse.containsMouse && playMouse.enabled
              ? Qt.rgba(1, 1, 1, 0.1)
              : "transparent"
          }

          LineIcon {
            anchors.centerIn: parent
            width: Math.round(26 * root.uiScale)
            height: width
            pathData: root.activePlayer && root.activePlayer.isPlaying ? "M8 5v14 M16 5v14" : "M7 4 20 12 7 20Z"
            opacity: 0.9
          }

          MouseArea {
            id: playMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.activePlayer
              && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause)
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.runMediaAction("playPause")
          }
        }

        Item {
          width: Math.round(42 * root.uiScale)
          height: width
          opacity: root.activePlayer && root.activePlayer.canGoNext ? 1 : 0.38

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: nextMouse.containsMouse && nextMouse.enabled
              ? Qt.rgba(1, 1, 1, 0.1)
              : "transparent"
          }

          LineIcon {
            anchors.centerIn: parent
            width: Math.round(21 * root.uiScale)
            height: width
            pathData: "M18 5v14 M5 5l11 7-11 7Z"
            opacity: 0.9
          }

          MouseArea {
            id: nextMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.activePlayer && root.activePlayer.canGoNext
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.runMediaAction("next")
          }
        }
      }
    }

    Row {
      id: statusFooter
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Math.round(24 * root.uiScale)
      height: Math.round(38 * root.uiScale)
      spacing: Math.round(10 * root.uiScale)

      Item {
        id: networkPill
        width: networkStatusContent.implicitWidth + Math.round(24 * root.uiScale)
        height: parent.height


        Row {
          id: networkStatusContent
          anchors.centerIn: parent
          spacing: Math.round(8 * root.uiScale)

          Text {
            textFormat: Text.PlainText
            height: statusFooter.height
            anchors.verticalCenter: parent.verticalCenter
            text: root.networkIcon
            color: root.foreground
            opacity: 0.76
            font.family: root.iconFontFamily
            font.pixelSize: Math.round(18 * root.uiScale)
            font.weight: Font.Light
            verticalAlignment: Text.AlignVCenter
          }

          Text {
            textFormat: Text.PlainText
            height: statusFooter.height
            text: root.networkLabel
            color: root.foreground
            opacity: 0.88
            font.family: root.textFontFamily
            font.pixelSize: Math.round(15 * root.uiScale)
            font.weight: Font.Normal
            verticalAlignment: Text.AlignVCenter
          }
        }
      }

      Item {
        id: batteryPill
        width: batteryStatusContent.implicitWidth + Math.round(24 * root.uiScale)
        height: parent.height
        visible: root.hasBattery


        Row {
          id: batteryStatusContent
          anchors.centerIn: parent
          spacing: Math.round(7 * root.uiScale)

          Text {
            textFormat: Text.PlainText
            height: statusFooter.height
            anchors.verticalCenter: parent.verticalCenter
            text: root.batteryIcon(root.batteryPercentage)
            color: root.foreground
            opacity: 0.76
            font.family: root.iconFontFamily
            font.pixelSize: Math.round(18 * root.uiScale)
            font.weight: Font.Light
            verticalAlignment: Text.AlignVCenter
          }

          Text {
            textFormat: Text.PlainText
            height: statusFooter.height
            text: root.batteryPercentage + "%"
            color: root.foreground
            opacity: 0.88
            font.family: root.textFontFamily
            font.pixelSize: Math.round(15 * root.uiScale)
            font.weight: Font.Normal
            verticalAlignment: Text.AlignVCenter
          }
        }
      }
    }
  }
}
