import QtQuick
import "gui"

// ThreadState says what a thread waits for: your decision, or its agents,
// who breathe while a run is open. A thread waiting for neither says nothing.
Label {
  id: state
  required property var thread
  readonly property bool deciding: thread.waiting.length > 0
  visible: deciding || thread.working
  text: deciding ? "WAITING FOR YOU" : "WORKING"
  color: deciding ? Theme.warning : Theme.primary
  font.pixelSize: 9
  font.letterSpacing: 2
  SequentialAnimation on opacity {
    running: !state.deciding && state.thread.working
    loops: Animation.Infinite
    onRunningChanged: if (!running) state.opacity = 1
    NumberAnimation { to: 0.4; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
  }
}
