import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Composer is where you write: in the main thread, to the root agent; in a
// work, to that work's agent, or a note its agents read without a new run,
// which Enter leaves while the box is noting. A message carries the files
// picked under the box; a note carries none.
// Sending shows the trace while the agent you write to is working; the agents
// below it never hold it. The words stay in the box, dimmed, until the server
// took the message, and come back to be sent again if it did not.
ColumnLayout {
  id: composer

  property bool compact: false
  // The work written to, or "" for the main thread.
  property string work: ""
  // Whether the agent written to has a run open: the root agent's, at depth 0,
  // in the main thread; the work's own in a work.
  readonly property bool busy: work === "" ? Omunculus.running.some(run => String(run.depth) === "0") : Omunculus.busy(work)

  // Whether Enter leaves a note rather than sends; once a note is left, or
  // on Esc, the box writes to the agent again.
  property bool noting: false

  spacing: 10

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

  InputFrame {
    Layout.fillWidth: true
    implicitHeight: row.implicitHeight
    color: Theme.highlight
    focused: entry.focused

    RowLayout {
      id: row
      anchors { fill: parent; leftMargin: 14; rightMargin: 8 }
      spacing: 10
      Icon { Layout.alignment: Qt.AlignTop; Layout.topMargin: 15; name: "chevron-right"; size: 14; color: entry.focused ? Theme.primary : Theme.dim }
      TextArea {
        id: entry
        Layout.fillWidth: true
        framed: false
        placeholderText: composer.noting ? "a note for its agents, without a run" : composer.work === "" ? (Omunculus.agent ? "say to " + Omunculus.agent + " what you need" : "say what you need") : "write to " + ((Omunculus.work(composer.work) || {}).assignee || "this work")
        onSubmitted: composer.noting ? composer.note() : composer.submit()
        Keys.onEscapePressed: event => {
          if (composer.noting)
            composer.noting = false
          else
            event.accepted = false
        }
      }
      TraceButton {
        dense: true
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: 7
        role: composer.noting ? "primary" : "progress"
        implicitWidth: composer.compact ? 32 : 110
        visible: composer.work !== ""
        icon: "plus"
        text: composer.compact ? "" : "NOTE"
        tip: "context for the work's agents, without a run"
        onClicked: composer.note()
      }
      TraceButton {
        id: sendButton
        dense: true
        Layout.alignment: Qt.AlignBottom
        Layout.bottomMargin: 7
        role: "progress"
        implicitWidth: composer.compact ? 32 : 86
        icon: "enter"
        text: composer.compact ? "" : "SEND"
        tip: "SEND"
        onClicked: composer.submit()
      }
    }
  }

  FilePicker {
    id: files
    Layout.fillWidth: true
    visible: !composer.noting
  }
}
