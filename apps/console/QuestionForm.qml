pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/ui/focus.js" as Focus
import "kit/ui"

// QuestionForm answers a numbered list of questions item by item. Each item
// is its number, its question wrapped in sentence case, a full-width box that
// grows with its text, and under it the toggle "I DON'T KNOW YET", which
// fills the box and, off, restores what was typed. Enter moves to the next
// box, Enter in the last and Ctrl+Enter in any send; a box taking the
// keyboard scrolls into view in the view around the form. After the last
// item, the card's actions: SEND, which joins the answers into one text
// reply, and "I can't answer this". The closing paragraph of the message, if
// any, shows after the last box and is not sent. How many are answered is
// `answered`, for the card's heading. What was typed stays after a failure.
ColumnLayout {
  id: form

  // The parsed questions, as {intro, items:[{n, text}], outro}.
  required property var parsed
  property bool sending: false
  // What the person wrote and where the keyboard was is kept under this key in
  // Omunculus.drafts, so a form rebuilt takes both back.
  property string draftKey: ""
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

  // Goes to the box after `from` that can take the keyboard; with none, the
  // keyboard stays where it is.
  function advance(from) {
    for (let at = from + 1; at < boxes.count; at++) {
      const box = boxes.itemAt(at)
      if (!box.canFocus)
        continue
      box.focusBox()
      return
    }
  }

  // Scrolls the nearest scrolling view above `item` just enough to show it;
  // whether the view follows its end is not touched, as the keyboard is here.
  function reveal(item) {
    let view = item.parent
    while (view && typeof view.contentY !== "number")
      view = view.parent
    if (!view)
      return
    const top = item.mapToItem(view.contentItem, 0, 0).y
    const margin = Theme.space.cell
    if (top - margin < view.contentY)
      view.contentY = top - margin
    else if (top + item.height + margin > view.contentY + view.height)
      view.contentY = top + item.height + margin - view.height
  }

  spacing: Theme.space.gap

  // Set as the form is torn down, so the keyboard it held is remembered.
  property bool dying: false
  Component.onDestruction: dying = true

  Shortcut {
    sequences: ["Ctrl+Return", "Ctrl+Enter"]
    enabled: Focus.within(form.Window.activeFocusItem, form)
    onActivated: form.send()
  }

  Prose {
    Layout.fillWidth: true
    Layout.maximumWidth: 620
    visible: form.parsed.intro !== ""
    source: Omunculus.inline(form.parsed.intro)
    color: Theme.foreground
    font.pixelSize: Theme.type.cardBody.size
    lineHeight: Theme.type.cardBody.lineHeight
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
      readonly property bool canFocus: !form.sending && !row.unknown
      function focusBox() { field.forceActiveFocus() }
      // A form rebuilt takes back the words and the keyboard.
      Component.onCompleted: {
        const draft = Omunculus.draftOf(form.draftKey)
        if (draft.answers[row.index])
          field.text = draft.answers[row.index]
        if (draft.at === row.index)
          Qt.callLater(row.focusBox)
      }
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      spacing: Theme.space.tight

      Label {
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: Theme.size.gutter
        text: row.modelData.n + "."
        color: Theme.dim
        font.pixelSize: Theme.type.body.size
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        spacing: Theme.space.tight

        Label {
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          text: row.modelData.text
          color: Theme.foreground
          font.pixelSize: Theme.type.body.size
          lineHeight: Theme.type.body.lineHeight
          wrapMode: Text.Wrap
        }

        TextBlock {
          id: field
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          // One line tall, growing with its text.
          implicitHeight: contentHeight + topPadding + bottomPadding
          readOnly: form.sending || row.unknown
          opacity: readOnly ? 0.5 : 1
          placeholderText: "your answer"
          Accessible.name: row.modelData.text
          Keys.onPressed: Typing.mark()
          onTextChanged: {
            form.edits++
            Omunculus.draftOf(form.draftKey).answers[row.index] = text
          }
          onActiveFocusChanged: {
            const draft = Omunculus.draftOf(form.draftKey)
            if (activeFocus) {
              draft.at = row.index
              Qt.callLater(form.reveal, field)
            } else if (!form.dying && draft.at === row.index) {
              draft.at = -1
            }
          }
          onAccepted: row.index < boxes.count - 1 ? form.advance(row.index) : form.send()
        }

        Chip {
          text: "I DON'T KNOW YET"
          checked: row.unknown
          reason: form.sending ? "your answers are being sent" : ""
          tip: row.unknown ? "write your own answer again" : "answer that you don't know yet"
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

  Prose {
    Layout.fillWidth: true
    Layout.maximumWidth: 620
    visible: form.parsed.outro !== ""
    source: Omunculus.inline(form.parsed.outro)
    color: Theme.foreground
    font.pixelSize: Theme.type.cardBody.size
    lineHeight: Theme.type.cardBody.lineHeight
    wrapMode: Text.Wrap
  }

  Flow {
    Layout.fillWidth: true
    spacing: Theme.space.tight
    TraceButton {
      dense: true
      role: "progress"
      icon: "enter"
      text: "SEND"
      tip: "send your answers  Ctrl+Enter"
      busy: form.sending
      reason: form.sending ? "" : form.ready ? "" : "answer at least one question first"
      enabled: !form.sending
      onClicked: form.send()
    }
    TraceButton {
      dense: true
      role: "progress"
      text: "I CAN'T ANSWER THIS"
      tip: "tell the team you can't answer, so they sort it out"
      enabled: !form.sending
      onClicked: form.declined()
    }
  }
}
