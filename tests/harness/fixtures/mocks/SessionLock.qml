import QtQuick

Item {
  property bool locked: false
  property bool secure: false
  signal lockStateChanged
  signal secureStateChanged
  onLockedChanged: {
    secure = locked
    lockStateChanged()
    secureStateChanged()
  }
}
