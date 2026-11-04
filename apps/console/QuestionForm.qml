pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/ui/focus.js" as Focus
import "kit/ui"

// QuestionForm answers a numbered list of questions item by item. Its top
// row says how many are answered, with SEND and "I can't answer this", so
// they never sit below the fold. Each item is its number, its question
// wrapped in sentence case, and a full-width box that grows with its text,
// with a toggle on the box's row that fills "I don't know yet" and, off,
// restores what was typed. Enter moves to the next box, Enter in the last
// and Ctrl+Enter in any send; a box taking the keyboard scrolls into view
// in the view around the form. SEND joins the answers into one text reply.
// The closing paragraph of the message, if any, shows after the last box and
// is not sent.
// What was typed stays after a failure.
ColumnLayout {
  id: form

  // The parsed questions, as {intro, items:[{n, text}], outro}.
  required property var parsed
  property bool sending: false
  // The answers joined as one text reply.
  signal submitted(string text)
  // The person says they cannot answer.
  signal declined()

  readonly property var items: parsed.items
  // Bumped on each edit so `answered` re-reads the boxes.
  property int edits: 0
  readonly property int answered: edits >= 0 ? answers().filter(text => text.trim() !== "").length : 0
  readonly property bool ready: answered > 0

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

  // Scrolls the nearest scrolling view above `item` just enough to show it.
  function reveal(item) {
    let view = item.parent
    while (view && typeof view.contentY !== "number")
      view = view.parent
    if (!view)
      return
    // The view stops following its end once the person works in the form.
    if (view.following !== undefined)
      view.following = false
    const top = item.mapToItem(view.contentItem, 0, 0).y
    const margin = 12
    if (top - margin < view.contentY)
      view.contentY = top - margin
    else if (top + item.height + margin > view.contentY + view.height)
      view.contentY = top + item.height + margin - view.height
  }

  spacing: 10

  Shortcut {
    sequences: ["Ctrl+Return", "Ctrl+Enter"]
    enabled: Focus.within(Window.activeFocusItem, form)
    onActivated: form.send()
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    Label {
      Layout.alignment: Qt.AlignVCenter
      text: form.answered + " of " + form.items.length + " answered"
      color: Theme.dim
      font.pixelSize: 11
      font.letterSpacing: 1
    }
    TraceButton {
      dense: true
      role: "primary"
      icon: "enter"
      text: "SEND"
      enabled: form.ready && !form.sending
      onClicked: form.send()
    }
    TraceButton {
      dense: true
      role: "progress"
      text: "I CAN'T ANSWER THIS"
      enabled: !form.sending
      onClicked: form.declined()
    }
  }

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
    delegate: RowLayout {
      id: row
      required property var modelData
      required property int index
      readonly property alias text: field.text
      // Whether "I don't know yet" stands in the box, and what it replaced.
      property bool unknown: false
      property string kept: ""
      function focusBox() { field.focusBox() }
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      spacing: 8

      Label {
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: 22
        text: row.modelData.n + "."
        color: Theme.dim
        font.pixelSize: 12
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        spacing: 6

        Label {
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          text: row.modelData.text
          color: Theme.foreground
          font.pixelSize: 13
          wrapMode: Text.Wrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          TextArea {
            id: field
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            Layout.alignment: Qt.AlignTop
            dense: true
            sending: form.sending || row.unknown
            placeholderText: "your answer"
            onTextChanged: form.edits++
            onFocusedChanged: if (focused) Qt.callLater(form.reveal, field)
            onSubmitted: row.index < boxes.count - 1 ? boxes.itemAt(row.index + 1).focusBox() : form.send()
          }
          Chip {
            Layout.alignment: Qt.AlignTop
            text: "I DON'T KNOW YET"
            checked: row.unknown
            enabled: !form.sending
            onClicked: {
              if (row.unknown) {
                row.unknown = false
                field.text = row.kept
              } else {
                row.kept = field.text
                row.unknown = true
                field.text = "I don't know yet"
              }
            }
          }
        }
      }
    }
  }

  Prose {
    Layout.fillWidth: true
    Layout.maximumWidth: 620
    visible: form.parsed.outro !== ""
    source: Omunculus.inline(form.parsed.outro)
    color: Theme.foreground
    font.pixelSize: 13
    wrapMode: Text.Wrap
  }
}
