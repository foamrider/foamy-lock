pragma Singleton
import QtQuick

QtObject {
  enum State {
    Full,
    Portal,
    Limited,
    None,
    Wired
  }
  property int connectivity: Networking.Full
  property var devices: ({
      values: []
    })
}
