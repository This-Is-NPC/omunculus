import QtQuick
import "gui"

// StateMark is a mail's state in a word: working (it breathes), your decision,
// or answered.
Label {
  id: mark
  property string state
  readonly property color tone: state === "decide" ? Theme.warning : state === "done" ? Theme.success : Theme.dim
  text: state === "decide" ? "YOUR DECISION" : state === "done" ? "ANSWERED" : "WORKING"
  color: tone
  font.pixelSize: 9
  font.letterSpacing: 2
  SequentialAnimation on opacity {
    running: mark.state === "working"
    loops: Animation.Infinite
    onRunningChanged: if (!running) mark.opacity = 1
    NumberAnimation { to: 0.4; duration: 900; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
  }
}
