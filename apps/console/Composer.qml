import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Composer is where you write: in the main thread, to the root agent; in a
// work, to that work's agent, or a note its agents read without a new run.
// Sending shows the trace while the agent you write to is working; the agents
// below it never hold it. In the box, while anything waits on you, how much
// does, and the way to the agents map where it is answered.
ColumnLayout {
  id: composer

  property bool compact: false
  // The work written to, or "" for the main thread.
  property string work: ""
  // Whether it leads to what waits on you; not where that is answered.
  property bool pendingShown: true

  // Whether the agent written to has a run open: the root agent's, at depth 0,
  // in the main thread; the work's own in a work.
  readonly property bool busy: work === "" ? Omunculus.running.some(run => String(run.depth) === "0") : Omunculus.busy(work)

  signal pendingChosen()

  spacing: 10

  // Put the keyboard in the box.
  function focusEntry() { entry.forceActiveFocus() }

  // The text typed, trimmed; the box is emptied once there is any.
  function take() {
    const value = entry.text.trim()
    if (value)
      entry.text = ""
    return value
  }

  function submit() {
    const value = take()
    if (!value)
      return
    if (composer.busy)
      sendButton.restartTrace()
    Omunculus.send(value, composer.work)
  }

  function note() {
    const value = take()
    if (value)
      Omunculus.note(value, composer.work)
  }

  Rectangle {
    Layout.fillWidth: true
    implicitHeight: 42
    color: Theme.highlight
    border.color: entry.activeFocus ? Theme.primary : Theme.line
    border.width: entry.activeFocus ? 2 : 1
    Behavior on border.color { ColorAnimation { duration: 140 } }

    RowLayout {
      anchors { fill: parent; leftMargin: 14; rightMargin: 8 }
      spacing: 10
      Icon { name: "chevron-right"; size: 14; color: entry.activeFocus ? Theme.primary : Theme.dim }
      TextBox {
        id: entry
        Layout.fillWidth: true
        placeholderText: composer.work === "" ? "say what you need" : "write to " + ((Omunculus.work(composer.work) || {}).assignee || "this work")
        background: Item {}
        onAccepted: composer.submit()
      }
      TraceButton {
        id: pendingButton
        dense: true
        role: "navigation"
        visible: composer.pendingShown && Omunculus.pending > 0
        tone: Theme.warning
        armed: true
        icon: "warning"
        text: composer.compact ? String(Omunculus.pending) : Omunculus.pending + " PENDING"
        tip: "what waits on you, on the map"
        onClicked: composer.pendingChosen()
        // It breathes while something waits.
        SequentialAnimation on opacity {
          running: pendingButton.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0.6; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
        }
      }
      TraceButton {
        dense: true
        role: "progress"
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
        role: "progress"
        implicitWidth: composer.compact ? 32 : 86
        busy: composer.busy
        allowClickWhileBusy: true
        icon: "enter"
        text: composer.compact ? "" : "SEND"
        tip: "SEND"
        onClicked: composer.submit()
      }
    }
  }
}
