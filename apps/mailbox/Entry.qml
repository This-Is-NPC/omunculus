import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Entry is one message of a thread, as a mail shows it: who wrote to whom and
// when, then the text and the files it carries. Folded, it is one line
// with the start of the text.
// A request for you is a message too:
// its question, and, while it waits, the way to answer it.
Rectangle {
  id: card

  required property var entry
  required property string thread
  property bool expanded: true

  readonly property bool request: entry.kind === "request"
  readonly property bool mine: entry.kind === "you"
  readonly property bool deciding: request && entry.open

  implicitHeight: body.implicitHeight + 24
  color: deciding ? Qt.alpha(Theme.warning, 0.06) : mine ? "transparent" : Qt.alpha(Theme.foreground, 0.02)
  border.color: deciding ? Theme.warning : Theme.line

  ColumnLayout {
    id: body
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 16; rightMargin: 16 }
    spacing: 10

    // The head: from, to and when; folded, the start of the text beside it.
    Item {
      Layout.fillWidth: true
      implicitHeight: head.implicitHeight
      RowLayout {
        id: head
        anchors { left: parent.left; right: parent.right }
        spacing: 8
        Icon { visible: card.request; name: "warning"; size: 11; color: card.deciding ? Theme.warning : Theme.dim }
        Label {
          text: card.mine ? "You" : card.entry.from
          color: card.deciding ? Theme.warning : card.mine ? Theme.dim : Theme.primary
          font.bold: !card.mine
          font.pixelSize: 12
        }
        Label {
          visible: card.expanded
          text: "to " + (card.mine ? card.entry.to : "you")
          color: Theme.dim
          font.pixelSize: 11
        }
        Label {
          visible: card.expanded && card.request
          text: card.deciding ? "· asks you" : "· asked you"
          color: card.deciding ? Theme.warning : Theme.dim
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
        Label {
          visible: card.entry.open && card.entry.kind === "agent"
          text: "writing"
          color: Theme.primary
          font.pixelSize: 10
        }
        Label { text: Mail.when(card.entry.at); color: Theme.dim; font.pixelSize: 10 }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: card.expanded && card.entry.text !== ""
      text: card.mine ? card.entry.text : Mail.markdown(card.entry.text)
      textFormat: card.mine ? Text.PlainText : Text.MarkdownText
      linkColor: Theme.primary
      onLinkActivated: link => Qt.openUrlExternally(link)
      font.pixelSize: 13
      lineHeight: 1.2
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
          name: modelData.name
          detail: Mail.size(modelData.bytes)
          onChosen: Mail.openAttachment(card.thread, modelData)
        }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: card.expanded && card.request && !card.entry.open
      text: !card.entry.answer ? "Closed without your answer."
        : "You answered: " + [card.entry.answer.option, card.entry.answer.body !== card.entry.answer.option ? card.entry.answer.body : ""].filter(part => part).join(" — ")
      color: Theme.dim
      font.pixelSize: 12
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
