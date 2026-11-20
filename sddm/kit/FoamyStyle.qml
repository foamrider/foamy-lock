pragma Singleton
import QtQuick

// The login screen's FoamyStyle: the members the lock's elements and
// LockLayout use. foamy-kit's FoamyStyle reads Commons.Style and Border,
// which the greeter doesn't have. The Omarchy font (`omarchy font set`)
// isn't copied, so the mono family is fontconfig's monospace.
QtObject {
  readonly property string fontFamily: "sans-serif"
  readonly property string monoFamily: "monospace"
}
