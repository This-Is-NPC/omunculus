pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Events.js" as Events
import "kit/client/Questions.js" as Questions
import "kit/ui"
import "kit/ui/Markdown.js" as Markdown

// AnswerBubble is what you answered a question: your words in a bubble on the
// right, left aligned with their line breaks kept, under a heading of your
// tone dot, YOU ANSWERED (YOU CHOSE and the option, when you chose one) and
// the time; a choice made without words has no bubble. Over them the question is one dim
// line, who asked in their tone and its first words, that opens in place to
// its full text.
Item {
  id: bubble

  // Who asked, what they asked and what you said.
  property string asker
  // Who passed the question on toward you, the asker first.
  property var route: []
  property string question
  // The heading when an option was chosen, as YOU CHOSE APPROVE.
  property string choice
  property string body
  property string stamp
  property bool open: false

  readonly property real widest: Math.min(620, bubble.width < Theme.size.measureFrom ? bubble.width : bubble.width * Theme.size.measure)
  readonly property color tone: Omunculus.toneOf("you")
  readonly property var form: Questions.parse(question)
  // The first line with words, with no ids, its whitespace collapsed and cut
  // at 120 characters.
  readonly property string first: {
    const line = Events.readable(Markdown.plain(question.split("\n").find(each => each.trim() !== "") || "")).replace(/\s+/g, " ").trim()
    return line.length > 120 ? line.slice(0, 119) + "…" : line
  }
  readonly property string via: route.length > 1 ? " · via " + route.slice(1).join(" › ") : ""
  readonly property string summary: asker + " asked" + via + (form ? " · " + form.items.length + " questions" : "") + ": " + first

  implicitHeight: column.y + column.height + Theme.space.row + Theme.space.gap

  Column {
    id: column
    y: Theme.space.tight
    width: bubble.width
    spacing: Theme.space.line

    Rectangle {
      id: ask
      readonly property color dim: Theme.readableOn(color)
      visible: bubble.question !== ""
      width: bubble.open ? Math.min(620, parent.width) : parent.width
      height: (bubble.open ? full.implicitHeight + Theme.space.tight * 2 : line.implicitHeight) + Theme.space.row
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
        x: bubble.open ? Theme.space.tight : 0
        y: bubble.open ? Theme.space.gap : Theme.space.row
        name: bubble.open ? "chevron-down" : "chevron-right"
        size: 10
        color: bubble.open ? ask.dim : pointer.containsMouse ? Theme.foreground : Theme.dim
      }
      // Who asked in their tone, between the dim words.
      Row {
        id: line
        visible: !bubble.open
        x: Theme.space.block
        width: parent.width - x
        readonly property color ink: pointer.containsMouse ? Theme.foreground : Theme.dim
        Label { id: who; text: bubble.asker; color: Omunculus.toneOf(bubble.asker); font.pixelSize: 11 }
        Label { id: by; text: " asked" + bubble.via + (bubble.form ? " · " + bubble.form.items.length + " questions" : ""); color: line.ink; font.pixelSize: 11 }
        Label {
          width: Math.max(0, line.width - by.width - who.width)
          text: ": " + bubble.first
          color: line.ink
          font.pixelSize: 11
          maximumLineCount: 1
          elide: Text.ElideRight
        }
      }
      Prose {
        id: full
        visible: bubble.open
        x: Theme.size.gutter
        y: Theme.space.tight
        width: parent.width - x - Theme.space.tight
        source: bubble.question
        color: ask.dim
        font.pixelSize: Theme.type.body.size
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

    Row {
      x: bubble.width - width
      spacing: Theme.space.tight
      Dot { anchors.verticalCenter: parent.verticalCenter; tone: bubble.tone }
      Label { text: bubble.choice !== "" ? bubble.choice : "YOU ANSWERED"; color: bubble.tone; font.pixelSize: Theme.type.name.size; font.letterSpacing: Theme.type.name.tracking }
      Label {
        anchors.verticalCenter: parent.verticalCenter
        text: bubble.stamp
        color: Qt.alpha(bubble.tone, Theme.type.stamp.opacity)
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
      }
    }

    Rectangle {
      visible: bubble.body !== ""
      x: bubble.width - width
      width: Math.min(bubble.widest, said.contentWidth + 2 * Theme.size.bubbleInset)
      height: said.implicitHeight + Theme.space.inset
      color: Theme.highlight
      Prose {
        id: said
        anchors.verticalCenter: parent.verticalCenter
        x: Theme.size.bubbleInset
        width: bubble.widest - 2 * Theme.size.bubbleInset
        horizontalAlignment: Text.AlignLeft
        plain: true
        source: bubble.body
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        wrapMode: Text.Wrap
      }
    }
  }
}
