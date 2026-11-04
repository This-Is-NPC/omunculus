pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// AnswerBubble is what you answered a question: your words on the right, line
// breaks kept, under a caption saying when, and over them the question as one
// dim line that opens to its full text.
Item {
  id: bubble

  // Who asked, what they asked and what you said.
  property string asker
  property string question
  property string body
  property string stamp
  property bool open: false

  readonly property real widest: Math.min(620, bubble.width < 520 ? bubble.width : bubble.width * 0.78)

  implicitHeight: column.y + column.height + 2

  Column {
    id: column
    y: 6
    width: Math.min(bubble.widest, Math.max(ask.implicitWidth, said.implicitWidth + 20, caption.implicitWidth))
    x: bubble.width - width
    spacing: 4

    Item {
      visible: bubble.question !== ""
      width: parent.width
      height: ask.implicitHeight + 2
      Label {
        id: ask
        anchors.fill: parent
        text: "Asked by " + bubble.asker.toUpperCase() + ": " + bubble.question
        color: pointer.containsMouse ? Theme.foreground : Theme.dim
        font.pixelSize: 11
        elide: bubble.open ? Text.ElideNone : Text.ElideRight
        wrapMode: bubble.open ? Text.Wrap : Text.NoWrap
        horizontalAlignment: Text.AlignRight
      }
      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: bubble.open = !bubble.open
      }
    }

    Rectangle {
      width: parent.width
      height: said.implicitHeight + 14
      color: Theme.highlight
      Prose {
        id: said
        anchors.verticalCenter: parent.verticalCenter
        x: 10
        width: parent.width - 20
        horizontalAlignment: Text.AlignRight
        plain: true
        source: bubble.body
        color: Theme.foreground
        font.pixelSize: 12
        lineHeight: 1.2
        wrapMode: Text.Wrap
      }
    }

    Label {
      id: caption
      width: parent.width
      text: "You answered, " + bubble.stamp
      color: Theme.dim
      font.pixelSize: 11
      horizontalAlignment: Text.AlignRight
    }
  }
}
