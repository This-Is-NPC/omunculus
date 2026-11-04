pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Questions.js" as Questions
import "kit/ui"

// AnswerBubble is what you answered a question: your words in a bubble on the
// right, left aligned with their line breaks kept, under a caption saying
// when. Over them the question is one dim line, who asked and its first
// words, that opens in place to its full text.
Item {
  id: bubble

  // Who asked, what they asked and what you said.
  property string asker
  property string question
  property string body
  property string stamp
  property bool open: false

  readonly property real widest: Math.min(620, bubble.width < 520 ? bubble.width : bubble.width * 0.78)
  readonly property var form: Questions.parse(question)
  // The first line with words, its whitespace collapsed and cut at 120 characters.
  readonly property string first: {
    const line = (question.split("\n").find(each => each.trim() !== "") || "").replace(/\s+/g, " ").trim()
    return line.length > 120 ? line.slice(0, 119) + "…" : line
  }
  readonly property string summary: "Asked by " + asker.toUpperCase() + ": " + first + (form ? " (" + form.items.length + " questions)" : "")

  implicitHeight: column.y + column.height + 2

  Column {
    id: column
    y: 6
    width: bubble.width
    spacing: 4

    Rectangle {
      id: ask
      readonly property color dim: Theme.readableOn(color)
      visible: bubble.question !== ""
      width: bubble.open ? Math.min(620, parent.width) : parent.width
      height: (bubble.open ? full.implicitHeight + 16 : line.implicitHeight) + 2
      color: bubble.open ? Qt.alpha(Theme.foreground, 0.06) : "transparent"
      activeFocusOnTab: true
      Accessible.role: Accessible.Button
      Accessible.name: bubble.summary
      Accessible.onPressAction: bubble.open = !bubble.open
      Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
          bubble.open = !bubble.open
          event.accepted = true
        }
      }

      FocusRing { anchors.margins: 0 }

      Icon {
        x: bubble.open ? 8 : 0
        y: bubble.open ? 10 : 2
        name: bubble.open ? "chevron-down" : "chevron-right"
        size: 10
        color: bubble.open ? ask.dim : pointer.containsMouse ? Theme.foreground : Theme.dim
      }
      Label {
        id: line
        visible: !bubble.open
        x: 16
        width: parent.width - 16
        text: bubble.summary
        color: pointer.containsMouse ? Theme.foreground : Theme.dim
        font.pixelSize: 11
        maximumLineCount: 1
        elide: Text.ElideRight
      }
      Prose {
        id: full
        visible: bubble.open
        x: 24
        y: 8
        width: parent.width - 32
        source: bubble.question
        color: ask.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          ask.forceActiveFocus()
          bubble.open = !bubble.open
        }
      }
    }

    Rectangle {
      x: bubble.width - width
      width: Math.min(bubble.widest, said.contentWidth + 20)
      height: said.implicitHeight + 14
      color: Theme.highlight
      Prose {
        id: said
        anchors.verticalCenter: parent.verticalCenter
        x: 10
        width: bubble.widest - 20
        horizontalAlignment: Text.AlignLeft
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
