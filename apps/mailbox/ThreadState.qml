import QtQuick
import "kit/ui"

// ThreadState says what a thread waits for: you, behind a warning dot, or its
// agents, with a trace that runs while a run is open. A thread waiting for
// neither says nothing.
Row {
  id: state

  required property var thread
  readonly property bool deciding: thread.waiting.length > 0

  visible: deciding || thread.working
  spacing: 6

  Dot { anchors.verticalCenter: parent.verticalCenter; visible: state.deciding; tone: Theme.warning }
  LoadingTrace {
    anchors.verticalCenter: parent.verticalCenter
    visible: !state.deciding
    width: 36
    height: 10
    running: !state.deciding && state.thread.working
  }
  Label {
    anchors.verticalCenter: parent.verticalCenter
    text: state.deciding ? "WAITING FOR YOU" : "WORKING"
    color: state.deciding ? Theme.warning : Theme.primary
    font.pixelSize: 9
    font.letterSpacing: 2
  }
}
