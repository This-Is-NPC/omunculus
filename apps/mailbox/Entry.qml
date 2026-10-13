pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Entry is one message of a thread, as a mail shows it: who wrote to whom and
// when, then the text and the files it carries, each a chip that saves the
// file to the downloads directory and opens it. Folded, it is one line with
// the start of the text. A request for you is a message too: a filled card
// with its question and, while it waits, the way to answer it.
SurfaceFrame {
  id: card

  required property var entry
  required property string thread
  property bool expanded: true

  readonly property bool request: entry.kind === "request"
  readonly property bool mine: entry.kind === "you"
  readonly property bool deciding: request && entry.open

  signal toggled()

  implicitHeight: body.implicitHeight + (expanded ? 28 : 20)
  variant: deciding ? "filled" : "outline"
  tone: Theme.warning
  active: deciding
  clip: true
  Behavior on implicitHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  ColumnLayout {
    id: body
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; topMargin: card.expanded ? 14 : 10 }
    spacing: 10

    // The head: from, to and when; folded, the start of the text beside it.
    Item {
      Layout.fillWidth: true
      implicitHeight: head.implicitHeight
      RowLayout {
        id: head
        anchors { left: parent.left; right: parent.right }
        spacing: 8
        Dot { visible: card.request; tone: card.deciding ? Theme.warning : Theme.dim }
        Label {
          text: card.mine ? "YOU" : card.entry.from.toUpperCase()
          color: card.deciding ? Theme.warning : card.mine ? Theme.dim : Theme.primary
          font.pixelSize: 10
          font.letterSpacing: 3
        }
        Label {
          visible: card.expanded
          text: (card.mine ? "to " + card.entry.to : "to you") + (card.request ? (card.deciding ? " · asks you" : " · asked you") : "")
          color: Theme.dim
          font.pixelSize: 11
        }
        Label {
          Layout.fillWidth: true
          visible: !card.expanded
          text: Mail.oneLine(card.entry.text) + (card.entry.files.length > 0 ? "  [" + card.entry.files.length + (card.entry.files.length === 1 ? " file]" : " files]") : "")
          color: Theme.dim
          font.pixelSize: 12
          elide: Text.ElideRight
        }
        Item { Layout.fillWidth: true; visible: card.expanded }
        LoadingTrace {
          visible: card.entry.open && card.entry.kind === "agent"
          width: 36
          height: 10
          running: visible
        }
        Label { text: Mail.when(card.entry.at); color: Theme.dim; font.pixelSize: 10 }
      }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -6
        cursorShape: Qt.PointingHandCursor
        enabled: !card.deciding
        onClicked: card.toggled()
      }
    }

    Prose {
      Layout.fillWidth: true
      visible: card.expanded && card.entry.text !== ""
      plain: card.mine
      source: card.mine ? card.entry.text : Mail.markdown(card.entry.text)
      color: card.mine ? Theme.dim : Theme.foreground
      font.pixelSize: 13
      lineHeight: 1.25
      wrapMode: Text.Wrap
    }

    Flow {
      Layout.fillWidth: true
      visible: card.expanded && card.entry.files.length > 0
      spacing: 6
      Repeater {
        model: card.entry.files
        delegate: FileChip {
          required property var modelData
          file: modelData
          onClicked: Mail.openAttachment(card.thread, modelData)
        }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: card.expanded && card.request && !card.entry.open
      text: !card.entry.answer ? "CLOSED WITHOUT YOUR ANSWER"
        : "YOU ANSWERED  " + [card.entry.answer.option.toUpperCase(), card.entry.answer.body !== card.entry.answer.option ? card.entry.answer.body : ""].filter(part => part).join(" — ")
      color: Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 1.5
      wrapMode: Text.Wrap
    }

    Loader {
      Layout.fillWidth: true
      active: card.deciding
      visible: active
      sourceComponent: Decision { entry: card.entry; thread: card.thread }
    }
  }
}
