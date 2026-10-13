pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// WorkflowTrack is where a work stands in its workflow: the stages in order,
// those it went through checked, the one it is at lit in the agent's colour
// (pulsing while it runs), the rest ahead of it.
Flow {
  id: track

  // The work: {workflow, stage, state}.
  required property var work
  property color tone: Theme.primary
  property bool running: false
  property bool dense: false

  readonly property var steps: {
    const flow = Omunculus.setup && work && work.workflow ? Omunculus.setup.workflows.find(each => each.name === work.workflow) : null
    return flow ? flow.steps : []
  }
  readonly property int at: steps.findIndex(step => step.name === (work ? work.stage : ""))
  readonly property bool finished: !!work && work.state === "done"

  spacing: 4
  visible: steps.length > 0

  Repeater {
    model: track.steps
    delegate: Row {
      id: stage
      required property var modelData
      required property int index
      readonly property bool passed: track.finished || index < track.at
      readonly property bool current: !track.finished && index === track.at
      spacing: 4
      Label {
        visible: stage.index > 0
        anchors.verticalCenter: parent.verticalCenter
        text: "›"
        color: Theme.dim
        font.pixelSize: track.dense ? 10 : 12
      }
      Rectangle {
        id: pill
        width: name.implicitWidth + (track.dense ? 10 : 14)
        height: track.dense ? 16 : 20
        color: stage.current ? Qt.alpha(track.tone, 0.18) : "transparent"
        border.color: stage.current ? track.tone : stage.passed ? Qt.alpha(Theme.foreground, 0.25) : Theme.line
        Label {
          id: name
          anchors.centerIn: parent
          text: (stage.passed ? "✓ " : "") + stage.modelData.name.toUpperCase()
          color: stage.current ? track.tone : stage.passed ? Theme.dim : Qt.alpha(Theme.foreground, 0.4)
          font.pixelSize: track.dense ? 8 : 9
          font.letterSpacing: 1.5
        }
        SequentialAnimation on opacity {
          running: stage.current && track.running
          loops: Animation.Infinite
          NumberAnimation { from: 1; to: 0.45; duration: 700 }
          NumberAnimation { from: 0.45; to: 1; duration: 700 }
          onRunningChanged: if (!running) pill.opacity = 1
        }
      }
    }
  }
}
