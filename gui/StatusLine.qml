import QtQuick

// StatusLine is the readout: the last message, and a warning while the
// server is unreachable. Information fades after a few seconds; errors stay
// until replaced.
Row {
  id: line
  property string message
  property bool error: false
  // The message shortens before anything around it does.
  property real maxWidth: 380
  spacing: 10
  // Without a message or a warning it takes no room, not even a layout's spacing.
  visible: (message.length > 0 && session.opacity > 0) || !Omunculus.connected

  // A new notice shows and starts fading; a language switch only rewrites it.
  property int count: Omunculus.noticeCount
  onCountChanged: if (message.length > 0) { session.opacity = 1; fade.restart() }
  Timer { id: fade; interval: 6000; onTriggered: if (!line.error) session.opacity = 0 }

  StatusMessage {
    id: session
    width: line.maxWidth
    visible: line.message.length > 0
    Behavior on opacity { NumberAnimation { duration: 400 } }
    message: line.message
    kind: line.error ? "error" : "info"
  }
  Row {
    visible: !Omunculus.connected
    spacing: 6
    Icon { anchors.verticalCenter: parent.verticalCenter; name: "warning"; size: 11; color: Theme.warning }
    Label { text: "DISCONNECTED"; color: Theme.warning; font.pixelSize: 10; font.letterSpacing: 3 }
  }
}
