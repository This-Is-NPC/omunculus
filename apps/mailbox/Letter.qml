import QtQuick
import QtQuick.Layouts

// Letter is one part of a mail as you read it: what you wrote, an answer the
// agents sent back once they had finished, or a decision you made on the way.
ColumnLayout {
  id: letter

  required property var modelData
  readonly property var item: modelData
  readonly property bool mine: item.kind === "you"

  spacing: 8

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    Label {
      text: letter.mine ? "YOU" : letter.item.kind === "decided" ? "YOU DECIDED" : String(letter.item.who || "").toUpperCase()
      color: letter.mine || letter.item.kind === "decided" ? Theme.dim : Theme.primary
      font.pixelSize: 10
      font.letterSpacing: 3
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }
    Label { text: Mail.when(letter.item.at); color: Theme.dim; font.pixelSize: 10 }
  }

  Label {
    Layout.fillWidth: true
    visible: letter.item.kind !== "decided"
    text: letter.item.kind === "answer" && letter.item.text === "" ? "The agents finished without a word."
      : Mail.markdown(letter.item.text)
    textFormat: letter.mine ? Text.PlainText : Text.MarkdownText
    linkColor: Theme.primary
    onLinkActivated: link => Qt.openUrlExternally(link)
    color: letter.mine ? Theme.dim : Theme.foreground
    font.pixelSize: 13
    lineHeight: 1.25
    wrapMode: Text.Wrap
  }

  Label {
    Layout.fillWidth: true
    visible: letter.item.kind === "decided"
    text: String(letter.item.text || "").replace(/\s+/g, " ") + "  →  "
      + (!letter.item.answer ? "closed" : [letter.item.answer.option, letter.item.answer.body !== letter.item.answer.option ? letter.item.answer.body : ""].filter(part => part).join(": "))
    color: Theme.dim
    font.pixelSize: 11
    wrapMode: Text.Wrap
  }
}
