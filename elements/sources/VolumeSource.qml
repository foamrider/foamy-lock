import QtQuick
import Quickshell.Services.Pipewire

// The default sink's volume and mute, for the status element's volume item.
// LockView loads it only while that item shows (and only with liveSources);
// it never changes the volume. The sink is tracked, as Omarchy's audio panel
// does, so its audio properties stay live.
Item {
  id: volume
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property bool available: sink !== null && sink.ready === true && sink.audio !== null
  readonly property int percent: available ? Math.max(0, Math.round(Number(sink.audio.volume || 0) * 100)) : 0
  readonly property bool muted: available && sink.audio.muted === true

  PwObjectTracker { objects: volume.sink ? [volume.sink] : [] }
}
