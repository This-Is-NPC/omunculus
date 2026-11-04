pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// Composer is where you write: in the main thread, to the root agent; in a
// work, to that work's agent, or a note its agents read without a new run,
// which Enter leaves while the box is noting. Over the box, the quick chips
// it is given, numbered as Alt and the number choose them, then the files
// the message carries; the clip in the box picks more, and a note carries
// none. In the main thread, the words not sent are kept for the conversation
// they were written in, and come back when it is open again.
// SEND keeps its caption over the trace while the agent you write to is
// working, says so on hover, and still sends; the agents below it never
// hold it. It is dim while the box is empty. While a form waits, the
// keyboard goes to the form, and the box offers to say something else. The words stay in the box,
// dimmed, until the server took the message, and come back to be sent again
// if it did not. Under 420 px of its own width its buttons show their icons
// only.
ColumnLayout {
  id: composer

  property bool compact: Breakpoints.tight(width)
  // The work written to, or "" for the main thread.
  property string work: ""
  // The quick chips over the box, [{text, tip, run}]; the chords that choose
  // them are the window's. `chipsShown` false keeps their room, not their keys.
  property var quick: []
  property bool chipsShown: true
  // Whether the agent written to has a run open: the root agent's, at depth 0,
  // in the main thread; the work's own in a work.
  readonly property bool busy: work === "" ? Omunculus.running.some(run => String(run.depth) === "0") : Omunculus.busy(work)
  // The agent written to, "" when none is known yet.
  readonly property string addressee: work === "" ? Omunculus.agent : (Omunculus.work(work) || {}).assignee || ""
  // Whether a numbered form waits on you in the main thread: its answers go
  // in its card, so the box does not invite them.
  readonly property bool formWaits: work === "" && Omunculus.waiting.some(request => Questions.parse(request.reason) !== null)

  // Whether the box holds nothing to send.
  readonly property bool empty: entry.text.trim() === ""

  // Whether Enter leaves a note rather than sends; once a note is left, or
  // on Esc, the box writes to the agent again.
  property bool noting: false

  spacing: Theme.space.tight

  // A message on its way keeps its words in the box, whatever opens.
  Connections {
    target: Omunculus
    enabled: composer.work === ""
    function onConversationIdChanged() {
      if (!entry.sending)
        entry.text = Omunculus.composerDrafts[Omunculus.conversationId] || ""
    }
  }

  // Put the keyboard in the box; in a work, `note` makes Enter leave a note.
  function focusEntry(note) {
    noting = !!note && work !== ""
    entry.forceActiveFocus()
  }

  // The text typed, trimmed; the box is emptied once there is any.
  function take() {
    const value = entry.text.trim()
    if (value)
      entry.clear()
    return value
  }

  function submit() {
    const value = entry.text.trim()
    if (!value || entry.sending)
      return
    const picked = files.take()
    entry.sending = true
    Omunculus.send(value, composer.work, picked, () => {
      entry.clear()
      entry.sending = false
      entry.focusBox()
    }, () => {
      files.paths = picked
      entry.sending = false
      entry.focusBox()
    })
  }

  function note() {
    const value = take()
    if (!value)
      return
    Omunculus.note(value, composer.work)
    noting = false
  }

  Flow {
    Layout.fillWidth: true
    visible: composer.chipsShown && composer.quick.length > 0
    spacing: Theme.space.tight
    Repeater {
      model: composer.quick
      delegate: Chip {
        required property var modelData
        required property int index
        readonly property var keys: Shortcuts.keys("quick")
        text: (index < keys.length ? (index + 1) + "  " : "") + modelData.text
        tip: modelData.tip + (index < keys.length ? "  " + keys[index] : "")
        onClicked: modelData.run()
      }
    }
  }

  FilePicker {
    id: files
    Layout.fillWidth: true
    visible: paths.length > 0 && !composer.noting
  }

  InputFrame {
    Layout.fillWidth: true
    implicitHeight: row.implicitHeight
    color: Theme.highlight
    focused: entry.focused

    // The chevron sits by the first line and the buttons by the last, each
    // centred on a box of one line.
    RowLayout {
      id: row
      anchors { left: parent.left; right: parent.right; leftMargin: Theme.space.inset; rightMargin: Theme.space.trail }
      spacing: Theme.space.gap
      Icon {
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: (Theme.size.control - Theme.type.input.chevron) / 2
        name: "chevron-right"
        size: Theme.type.input.chevron
        color: entry.focused ? Theme.primary : Theme.dim
      }
      TextArea {
        id: entry
        Layout.fillWidth: true
        framed: false
        placeholderText: composer.noting ? "a note for its agents, without a run" : composer.work === "" ? composer.formWaits ? "or say something else" + (composer.addressee ? " to " + composer.addressee : "") : composer.addressee ? "say to " + composer.addressee + " what you need" : "say what you need" : "write to " + (composer.addressee || "this work")
        onSubmitted: composer.noting ? composer.note() : composer.submit()
        onTextChanged: if (composer.work === "" && Omunculus.conversationId !== "") Omunculus.composerDrafts[Omunculus.conversationId] = text
        Keys.onEscapePressed: event => {
          if (composer.noting)
            composer.noting = false
          else
            event.accepted = false
        }
      }
      IconButton {
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: (Theme.size.control - height) / 2
        visible: !composer.noting
        name: "attach"
        size: Theme.type.input.chevron
        tip: "files to send with the message"
        onClicked: files.pick()
      }
      TraceButton {
        dense: true
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: (Theme.size.control - height) / 2
        role: composer.noting ? "primary" : "progress"
        implicitWidth: composer.compact ? Breakpoints.target(Window.width) : 110
        visible: composer.work !== ""
        icon: "plus"
        text: composer.compact ? "" : "NOTE"
        tip: "context for the work's agents, without a run"
        onClicked: composer.note()
      }
      TraceButton {
        dense: true
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: (Theme.size.control - height) / 2
        role: "progress"
        implicitWidth: composer.compact ? Breakpoints.target(Window.width) : 86
        busy: composer.busy
        allowClickWhileBusy: true
        reason: composer.empty ? "write something first" : ""
        icon: "enter"
        text: composer.compact ? "" : "SEND"
        tip: composer.busy ? (composer.addressee || "the agent") + " is working; SEND still sends" : "SEND"
        onClicked: composer.submit()
      }
    }
  }
}
