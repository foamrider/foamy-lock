// Render shell: the real LockView with synthetic data, stepped through wide,
// narrow, failure, busy, fallback and right-to-left states; each state is
// captured to capture-N.png. Written into a temporary app by the harness.
import QtQuick
import Quickshell
import "fixtures" as Fixture
ShellRoot {
  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 1920; implicitHeight: 1080
    color: "#182638"
    LockView {
      id: view
      width: 1920; height: 1080
      userName: "foamy"
      userDisplayName: "Foamy User"
      avatarPath: ""
      backgroundPath: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
      activePlayer: player
      artworkPath: Qt.resolvedUrl("artwork.png").toString().replace("file://", "")
      fingerprintConfigured: true
      onPasswordTextEdited: function(value) { passwordText = value }
      onClearFailureRequested: failureMessage = ""
    }
    QtObject {
      id: player
      property string trackTitle: "Evening Light"
      property string trackArtist: "Sample Artist"
      property string trackArtUrl: "https://must-not-be-fetched.invalid/original.png"
      property bool isPlaying: true
      property bool canGoPrevious: true
      property bool canGoNext: true
      property bool canTogglePlaying: true
      property bool canPlay: true
      property bool canPause: true
      property int actions: 0
      function previous() { actions++ }
      function next() { actions++ }
      function togglePlaying() { actions++ }
    }
    Timer {
      id: step
      property int index: 0
      interval: 700
      repeat: false
      running: true
      onTriggered: {
        var input = view.children[0] // Locate the editor by objectName below.
        function findNamed(item, name) {
          if (item.objectName === name) return item
          for (var i = 0; i < item.children.length; i++) {
            var found = findNamed(item.children[i], name)
            if (found) return found
          }
          return null
        }
        input = findNamed(view, "passwordInput")
        if (index === 0) {
          var dropped = [Qt.Key_A, Qt.Key_0, Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter, Qt.Key_Escape]
          for (var k = 0; k < dropped.length; k++)
            if (!view.dropsAutoRepeat(dropped[k])) throw new Error("Unsafe auto-repeat key")
          if (view.dropsAutoRepeat(Qt.Key_Backspace) || view.dropsAutoRepeat(Qt.Key_Delete))
            throw new Error("Repeated deletion must remain available")
        }
        var artImage = findNamed(view, "artworkImage")
        var fallback = findNamed(view, "artworkFallback")
        if (index === 7 && String(findNamed(view, "lockWallpaper").source) !== "")
          throw new Error("Plain wallpaper fallback was not displayed")
        if (index < 2 && (artImage.status !== Image.Ready || fallback.visible))
          throw new Error("Validated artwork was not displayed")
        if (index >= 4 && index < 8 && (!fallback.visible || artImage.visible))
          throw new Error("Artwork icon fallback was not displayed")
        if (String(artImage.source).indexOf("https:") === 0)
          throw new Error("Original artwork URL reached the view")
        if (!input || (!view.authenticatingPassword && !input.activeFocus)) throw new Error("Password input lost focus")
        if (index >= 6 && index < 8 && !findNamed(view, "fingerprintNotice").visible)
          throw new Error("Fingerprint unavailable notice is missing")
        if (index === 1 && input.text !== "example") throw new Error("Password binding did not update")
        // A translated unlock hint may be wider than the pill, never cut off.
        var hint = findNamed(view, "unlockHint")
        var hintText = findNamed(view, "unlockHintText")
        if (hint.visible) {
          var hintStart = hint.mapToItem(view, 0, 0).x
          if (hintText.truncated || hintStart < 0 || hintStart + hint.width > view.width || hint.width > view.contentWidth)
            throw new Error("Unlock hint does not fit: " + hintText.text + " (" + hint.width + " of " + view.contentWidth + ")")
          for (var clipper = hint.parent; clipper && clipper !== view; clipper = clipper.parent) {
            var inside = hint.mapToItem(clipper, 0, 0)
            if (clipper.clip && (inside.x < 0 || inside.y < 0 || inside.x + hint.width > clipper.width || inside.y + hint.height > clipper.height))
              throw new Error("Unlock hint is clipped by " + clipper + ": " + hintText.text)
          }
        }
        if (!view.grabToImage(function(result) {
          if (!result.saveToFile(Qt.resolvedUrl("capture-" + step.index + ".png").toString().replace("file://", "")))
            throw new Error("Screenshot save failed")
          step.index++
          if (step.index === 1) {
            view.width = 800; view.height = 1000
            view.passwordText = "example"
            view.runMediaAction("next")
            if (player.actions !== 1) throw new Error("Media transport did not reach player")
          } else if (step.index === 2) {
            view.width = 1280; view.height = 720
            view.timeFormat = "12h"
            view.passwordText = ""
            view.failureMessage = "Authentication failed (1)"
            view.fingerprintConfigured = false
            view.activePlayer = null
            Fixture.Networking.connectivity = Fixture.Networking.None
          } else if (step.index === 3) {
            view.showUserInfo = false
            view.failureMessage = ""
            view.authenticatingPassword = true
            Fixture.Power.displayDevice = null
          } else if (step.index === 4) {
            view.width = 1920; view.height = 1080
            view.activePlayer = player
            view.showUserInfo = true
            view.authenticatingPassword = false
            view.artworkPath = ""
          } else if (step.index === 5) {
            view.width = 800; view.height = 1000
            view.artworkPath = Qt.resolvedUrl("missing-thumbnail.png").toString().replace("file://", "")
          } else if (step.index === 6) {
            view.width = 1920; view.height = 1080
            view.artworkPath = ""
            view.passwordText = ""
            view.fingerprintConfigured = true
            view.fingerprintUnavailable = true
          } else if (step.index === 7) {
            view.width = 800; view.height = 1000
            view.passwordText = "example"
            view.backgroundPath = ""
          } else if (step.index === 8) {
            // Right-to-left: the layout mirrors, transport controls do not.
            view.width = 1920; view.height = 1080
            view.rightToLeft = true
            view.passwordText = "example"
            view.fingerprintUnavailable = false
            view.backgroundPath = Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
            view.artworkPath = Qt.resolvedUrl("artwork.png").toString().replace("file://", "")
          } else {
            var media = findNamed(view, "mediaRow")
            var footer = findNamed(view, "statusFooter")
            var controls = findNamed(view, "mediaControls")
            if (media.x < view.width / 2 || footer.x > view.width / 2)
              throw new Error("Right-to-left layout was not mirrored")
            if (controls.children[0].x > controls.children[2].x)
              throw new Error("Media transport order must not mirror")
            // The submit arrow mirrors around its own centre and stays inside the field.
            var field = findNamed(view, "inputField")
            var arrow = findNamed(view, "submitArrow")
            var start = arrow.mapToItem(field, 0, arrow.height / 2)
            var end = arrow.mapToItem(field, arrow.width, arrow.height / 2)
            if (!(start.x > end.x)) throw new Error("Submit arrow is not mirrored in right-to-left")
            if (end.x < 0 || start.x > field.width || start.y < 0 || start.y > field.height)
              throw new Error("Submit arrow left the password field: " + end.x + ".." + start.x + " of " + field.width)
            if (end.x > field.width / 2) throw new Error("Submit arrow should sit at the leading (left) edge in right-to-left")
            console.log("PASS: right-to-left mirroring with fixed transport order")
            console.log("PASS: wide/narrow artwork, empty/error icon fallback, media action, password focus/binding, failure, busy, hidden identity, no media/battery")
            Qt.quit()
            return
          }
          step.restart()
        })) throw new Error("Screenshot capture failed")
      }
    }
  }
}
