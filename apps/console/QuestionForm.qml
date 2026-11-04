pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/ui/focus.js" as Focus
import "kit/ui"

// QuestionForm answers a numbered list of questions item by item. Each item
// is its number, its question wrapped in sentence case at a readable measure,
// a box as wide as the card's text that grows with its text, and under it the
// toggle "I DON'T KNOW YET", which fills the box and, off, restores what was
// typed. Enter moves to the next box, Enter in the last and Ctrl+Enter in any
// send; the item taking the keyboard scrolls into view in the views around
// the form. The closing paragraph of the message, if any, shows after the
// last box and is not sent. The form's actions, SEND, which joins the answers
// into one text reply, and "I can't answer this", end the form; while that
// end is below what the views show, they float on the bottom edge of the
// view with how many questions start under them, which leads to the next;
// what passes under them fades out above.
// How many are answered is `answered`, for the card's heading. What was typed
// stays after a failure.
ColumnLayout {
  id: form

  // The parsed questions, as {intro, items:[{n, text}], outro}.
  required property var parsed
  property bool sending: false
  // What the person wrote and where the keyboard was is kept under this key in
  // Omunculus.drafts, so a form rebuilt takes both back.
  property string draftKey: ""
  // The card's fill, and how far past the form's sides the card's inside
  // reaches, so the floating actions cover the card's width.
  property color fill: "transparent"
  property real bleed: 0
  // The answers joined as one text reply.
  signal submitted(string text)
  // The person says they cannot answer.
  signal declined()

  readonly property var items: parsed.items
  // Bumped on each edit so `answered` re-reads the boxes.
  property int edits: 0
  readonly property int answered: edits >= 0 ? answers().filter(text => text.trim() !== "").length : 0
  readonly property bool ready: answered > 0
  readonly property bool narrow: width < Theme.size.measureFrom

  // The views around the form that scroll, nearest first.
  property var views: []
  // How far above their place the actions float, and how many items start
  // under them there.
  property real lift: 0
  property int below: 0
  readonly property bool floating: lift > 0

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

  // Brings the first item under the floating actions into view, with the
  // keyboard in its box when it can take it.
  function next() {
    for (let at = 0; at < boxes.count; at++) {
      const row = boxes.itemAt(at)
      if (row.y + Theme.size.stackedLine <= bar.y + dock.y)
        continue
      if (row.canFocus)
        row.focusBox()
      else
        reveal(row)
      return
    }
  }

  function collect() {
    const found = []
    for (let at = form.parent; at; at = at.parent) {
      if (typeof at.contentY === "number" && at.contentItem)
        found.push(at)
    }
    views = found
    place()
  }

  // Floats the actions on the bottom edge of the views while the form's end
  // is below it, and counts the items that start under them.
  function place() {
    let bottom = Infinity
    for (const view of views)
      bottom = Math.min(bottom, view.height - form.mapToItem(view, 0, 0).y)
    const natural = dock.y
    // The bar never covers the first question.
    const first = boxes.itemAt(0)
    const floor = first ? first.y + first.height : 0
    const top = Math.min(natural, Math.max(floor, bottom - dock.height))
    // The bar's top, with the room the count takes over the actions when
    // narrow, once anything starts under them.
    const shown = top - Theme.space.tight - (narrow ? hint.height + Theme.space.tight : 0)
    let hidden = 0
    for (let at = 0; top < natural && at < boxes.count; at++) {
      const row = boxes.itemAt(at)
      if (row && row.y + Theme.size.stackedLine > shown)
        hidden++
    }
    below = hidden
    lift = natural - top
  }

  // Scrolls the nearest view that scrolls just enough to show `item` above
  // the floating actions, or its top when it is taller; whether the view
  // follows its end is not touched, as the keyboard is here.
  function reveal(item) {
    const view = views.find(each => each.contentHeight > each.height)
    if (!view)
      return
    const top = item.mapToItem(view.contentItem, 0, 0).y
    const margin = Theme.space.cell
    const room = view.height - bar.height - margin
    if (top - margin < view.contentY || item.height + margin > room)
      view.contentY = top - margin
    else if (top + item.height > view.contentY + room)
      view.contentY = top + item.height - room
  }

  spacing: Theme.space.gap

  // Set as the form is torn down, so the keyboard it held is remembered.
  property bool dying: false
  Component.onDestruction: dying = true
  Component.onCompleted: Qt.callLater(collect)
  onHeightChanged: place()

  Instantiator {
    model: form.views
    delegate: Connections {
      required property var modelData
      target: modelData
      function onContentYChanged() { form.place() }
      function onHeightChanged() { form.place() }
      function onContentHeightChanged() { form.place() }
    }
  }

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
      onYChanged: form.place()
      // A form rebuilt takes back the words and the keyboard.
      Component.onCompleted: {
        const draft = Omunculus.draftOf(form.draftKey)
        if (draft.answers[row.index])
          field.text = draft.answers[row.index]
        if (draft.at === row.index)
          Qt.callLater(row.focusBox)
      }
      Layout.fillWidth: true
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
          Layout.maximumWidth: 620
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
              Qt.callLater(form.reveal, row)
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

  // The actions' place at the form's end; they float from it on the view's
  // bottom edge, over a fill and a hairline, with the count of the items
  // under them at the right, or over them when narrow.
  Item {
    id: dock
    Layout.fillWidth: true
    implicitHeight: actions.implicitHeight
    onYChanged: form.place()

    Rectangle {
      id: bar
      readonly property real over: form.narrow && hint.visible ? hint.height + Theme.space.tight : 0
      x: -form.bleed
      y: -form.lift - over - Theme.space.tight
      width: form.width + 2 * form.bleed
      height: dock.height + over + Theme.space.tight + Theme.space.tight
      color: form.floating ? Qt.tint(Theme.background, form.fill) : "transparent"
      Rectangle {
        visible: form.floating
        width: parent.width
        height: 1
        color: Theme.line
      }
      // What passes under the floating actions fades out above them.
      Rectangle {
        visible: form.floating
        anchors.bottom: parent.top
        width: parent.width
        height: Theme.space.section
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.alpha(bar.color, 0) }
          GradientStop { position: 1; color: bar.color }
        }
      }
      // What lies under the floating actions takes no clicks through them.
      MouseArea {
        anchors.fill: parent
        enabled: form.floating
      }
    }

    Flow {
      id: actions
      y: -form.lift
      width: dock.width - (form.narrow || !hint.visible ? 0 : hint.width + Theme.space.gap)
      spacing: Theme.space.tight
      // The main action: solid once there is an answer to send.
      TraceButton {
        dense: true
        role: "primary"
        icon: "enter"
        text: "SEND"
        tip: "send your answers  Ctrl+Enter"
        busy: form.sending
        reason: form.sending ? "" : form.ready ? "" : "answer at least one question first"
        filled: form.ready && !form.sending
        enabled: !form.sending
        onClicked: form.send()
      }
      Label {
        visible: !form.ready && !form.sending
        height: Theme.size.controlDense
        verticalAlignment: Text.AlignVCenter
        text: "answer at least one to send"
        color: Theme.dim
        font.pixelSize: Theme.type.tab.size
      }
      // Giving up is quiet; it takes the accent only under the pointer.
      TraceButton {
        id: decline
        dense: true
        role: "action"
        tone: decline.hovered ? Theme.primary : Theme.dim
        text: "I CAN'T ANSWER THIS"
        tip: "tell the team you can't answer, so they sort it out"
        enabled: !form.sending
        onClicked: form.declined()
      }
    }

    Chip {
      id: hint
      visible: form.below > 0
      x: dock.width - width
      y: form.narrow ? -form.lift - height - Theme.space.tight : -form.lift
      icon: "chevron-down"
      text: form.below + (form.below === 1 ? " MORE QUESTION BELOW" : " MORE QUESTIONS BELOW")
      tip: "go to the next question"
      onClicked: form.next()
    }
  }
}
