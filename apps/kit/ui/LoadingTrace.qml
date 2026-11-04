pragma ComponentBehavior: Bound
import QtQuick

// LoadingTrace is the trace drawn while something loads: it moves in from the
// left toward the end but stops short of it while the work goes on; once the
// work is done it reaches the end, and goes.
Item {
  id: loading

  property bool running: false
  property color tone: Theme.primary
  // The colour behind the trace, which its left edge fades into.
  property color backdrop: Theme.background
  property real progress: 0

  visible: running || finish.running
  clip: true

  // Start over, as when new work replaces the one in progress.
  function restart() {
    finish.stop()
    progress = 0
    fill.restart()
    if (body.item)
      (body.item as EcgTrace).seed()
  }

  onRunningChanged: {
    if (running) {
      restart()
    } else {
      fill.stop()
      finish.restart()
    }
  }

  NumberAnimation { id: fill; target: loading; property: "progress"; to: 0.92; duration: 1800; easing.type: Easing.Linear }
  NumberAnimation { id: finish; target: loading; property: "progress"; to: 1; duration: 220; easing.type: Easing.OutCubic }

  // The trace exists only while it shows: a button at rest holds none.
  Loader {
    id: body
    anchors.fill: parent
    active: loading.visible
    sourceComponent: EcgTrace {
      x: loading.width * (loading.progress - 1)
      width: loading.width
      height: loading.height
      tone: loading.tone
      backdrop: loading.backdrop
    }
  }
}
