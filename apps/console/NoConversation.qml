import QtQuick
import "kit/ui"

// NoConversation stands for a page that shows a conversation while none is
// open: it says so and leads to the conversations, or to a new one. The
// keyboard starts on the first way; Tab moves to the other, Esc leaves.
FocusScope {
  id: missing

  // The page it stands for.
  property string what: ""
  signal listWanted()
  signal newWanted()
  signal leave()

  Keys.onEscapePressed: leave()

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - 40, 420)
    spacing: 14

    DecodeLabel {
      width: parent.width
      value: "NO CONVERSATION IS OPEN"
      color: Theme.dim
      horizontalAlignment: Text.AlignHCenter
      font.pixelSize: 11
      font.letterSpacing: 4
    }
    Label {
      width: parent.width
      text: "The " + missing.what + " shows the conversation open. Open one of the project's, or start one."
      color: Theme.dim
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      font.pixelSize: 11
    }
    Item { width: 1; height: 4 }
    TraceButton {
      anchors.horizontalCenter: parent.horizontalCenter
      implicitWidth: 260
      role: "navigation"
      icon: "list"
      text: "CONVERSATIONS"
      focus: true
      onClicked: missing.listWanted()
    }
    TraceButton {
      anchors.horizontalCenter: parent.horizontalCenter
      implicitWidth: 260
      role: "navigation"
      icon: "plus"
      text: "NEW CONVERSATION"
      onClicked: missing.newWanted()
    }
  }
}
