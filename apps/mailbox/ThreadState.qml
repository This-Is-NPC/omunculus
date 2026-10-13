import QtQuick
import "kit/ui"

// ThreadState names what a thread is doing, in the tone of its state: a trace
// that runs while an agent works, a dot otherwise — the warning's when it
// waits on you or stalled, the error's when it failed, the success's when it
// is done. An idle thread says nothing.
Row {
  id: state

  required property var thread
  readonly property var status: thread.status
  readonly property color tone: ({ working: Theme.primary, waiting: Theme.warning, awaited: Theme.warning, stalled: Theme.warning,
    failed: Theme.error, done: Theme.success })[status.state] || Theme.dim

  visible: status.label !== ""
  spacing: 6

  Dot { anchors.verticalCenter: parent.verticalCenter; visible: state.status.state !== "working"; tone: state.tone }
  LoadingTrace {
    anchors.verticalCenter: parent.verticalCenter
    visible: state.status.state === "working"
    width: 36
    height: 10
    running: visible
  }
  Label {
    anchors.verticalCenter: parent.verticalCenter
    text: state.status.label
    color: state.tone
    font.pixelSize: 9
    font.letterSpacing: 2
  }
}
