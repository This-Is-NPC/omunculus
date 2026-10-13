pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Entry is one message of a thread, as a mail shows it: who wrote to whom and
// when, an agent's portrait before its name, then the text and the files it
// carries, each a chip that saves the file to the downloads directory and
// opens it. Folded, it is one line with the start of the text. A request for
// you is a message too: a filled card with its question and, while it waits,
// the way to answer it; your answer is a message of yours, the option it
// chose under its words. A question the harness passed on is that of whoever
// asked it, the harness's sentence under it in small print; a note the
// harness wrote that passes on none is no one's words: it reads NOTE, muted,
// where a speaker's name would be.
SurfaceFrame {
  id: card

  required property var entry
  required property string thread
  required property string project
  property bool expanded: true

  readonly property bool request: entry.kind === "request"
  readonly property bool mine: entry.kind === "you"
  readonly property bool note: !!entry.note
  readonly property bool deciding: request && entry.open
  readonly property bool agent: !mine && !note && Mail.isAgent(project, entry.from)

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
        Portrait {
          visible: card.agent
          Layout.preferredWidth: 20
          Layout.preferredHeight: 20
          agent: card.entry.from
          source: Mail.imageOf(card.project, card.entry.from)
          tone: Mail.toneOf(card.project, card.entry.from)
        }
        Label {
          text: card.mine ? "YOU" : card.entry.from.toUpperCase()
          color: card.deciding ? Theme.warning : card.mine || card.note ? Theme.dim : Theme.primary
          font.pixelSize: 10
          font.letterSpacing: 3
        }
        Label {
          visible: card.expanded
          text: (card.mine ? "to " + card.entry.to : "to you") + (card.request ? (card.deciding ? " · asks you" : " · asked you") : card.entry.answering ? " · answered" : "")
          color: Theme.dim
          font.pixelSize: 11
        }
        Label {
          Layout.fillWidth: true
          visible: !card.expanded
          text: (card.entry.option ? card.entry.option.toUpperCase() + " — " : "") + Mail.oneLine(card.entry.text) + (card.entry.files.length > 0 ? "  [" + card.entry.files.length + (card.entry.files.length === 1 ? " file]" : " files]") : "")
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
      source: card.entry.text
      color: card.mine || card.note ? Theme.dim : Theme.foreground
      font.pixelSize: 13
      lineHeight: 1.25
      wrapMode: Text.Wrap
    }

    Label {
      Layout.fillWidth: true
      visible: card.expanded && !!card.entry.fine
      text: card.entry.fine || ""
      color: Theme.dim
      font.pixelSize: 10
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
      visible: card.expanded && !!card.entry.option
      text: "CHOSE  " + (card.entry.option || "").toUpperCase()
      color: Theme.primary
      font.pixelSize: 10
      font.letterSpacing: 1.5
      wrapMode: Text.Wrap
    }

    Label {
      Layout.fillWidth: true
      visible: card.expanded && card.request && !card.entry.open && !card.entry.answered
      text: "CLOSED WITHOUT YOUR ANSWER"
      color: Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 1.5
    }

    Loader {
      Layout.fillWidth: true
      active: card.deciding
      visible: active
      sourceComponent: Decision { entry: card.entry; thread: card.thread }
    }
  }
}
