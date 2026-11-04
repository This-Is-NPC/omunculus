pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/ui"

// QuestionForm answers a numbered list of questions item by item: the intro,
// then a box for each item with a chip that fills "I don't know yet". SEND
// joins the answers into one text reply. What was typed stays after a
// failure.
ColumnLayout {
  id: form

  // The parsed questions, as {intro, items:[{n, text}]}.
  required property var parsed
  property bool sending: false
  // The answers joined as one text reply.
  signal submitted(string text)

  readonly property var items: parsed.items
  // Bumped on each edit so `ready` re-reads the boxes.
  property int edits: 0
  readonly property bool ready: edits >= 0 && answers().some(text => text.trim() !== "")

  function answers() {
    return items.map((item, at) => boxes.itemAt(at) ? boxes.itemAt(at).text : "")
  }

  function send() {
    if (ready && !sending)
      submitted(Questions.join(items, answers()))
  }

  function focusBox() {
    if (boxes.count > 0)
      boxes.itemAt(0).focusBox()
  }

  spacing: 10

  Prose {
    Layout.fillWidth: true
    Layout.maximumWidth: 620
    visible: form.parsed.intro !== ""
    source: Omunculus.inline(form.parsed.intro)
    color: Theme.foreground
    font.pixelSize: 13
    wrapMode: Text.Wrap
  }

  Repeater {
    id: boxes
    model: form.items
    delegate: ColumnLayout {
      id: row
      required property var modelData
      required property int index
      readonly property alias text: field.text
      function focusBox() { field.focusBox() }
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      spacing: 6

      TextArea {
        id: field
        Layout.fillWidth: true
        dense: true
        sending: form.sending
        label: row.modelData.n + ". " + row.modelData.text
        placeholderText: "your answer"
        onTextChanged: form.edits++
        onSubmitted: row.index < boxes.count - 1 ? boxes.itemAt(row.index + 1).focusBox() : form.send()
      }
      Chip {
        text: "I don't know yet"
        enabled: !form.sending
        onClicked: field.text = "I don't know yet"
      }
    }
  }

  TraceButton {
    dense: true
    role: "primary"
    icon: "enter"
    text: "SEND"
    enabled: form.ready && !form.sending
    onClicked: form.send()
  }
}
