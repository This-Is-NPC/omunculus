import QtQuick
import "gui"

// StatusNote is the masthead's readout: what the mailbox last said, fading
// after a while unless it is a failure, or that the server does not answer.
Label {
  id: note

  property real maxWidth: 360
  readonly property string said: !Mail.connected ? "THE SERVER DOES NOT ANSWER" : Mail.message.toUpperCase()

  width: Math.min(implicitWidth, maxWidth)
  text: said
  elide: Text.ElideRight
  color: Mail.messageIsError || !Mail.connected ? Theme.warning : Theme.dim
  font.pixelSize: 10
  font.letterSpacing: 2
  opacity: said === "" ? 0 : 1
  Behavior on opacity { NumberAnimation { duration: 400 } }

  // An answer fades after six seconds; a failure stays.
  Timer {
    interval: 6000
    running: Mail.message !== "" && !Mail.messageIsError
    onTriggered: Mail.message = ""
  }
}
