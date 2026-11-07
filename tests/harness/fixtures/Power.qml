pragma Singleton
import QtQuick
QtObject {
  enum State { Charging, FullyCharged, PendingCharge }
  property bool onBattery: true
  property var displayDevice: ({ready: true, isPresent: true, isLaptopBattery: true, percentage: 0.82, state: 0})
}
