pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "kit/ui"

// WorkflowLane is a work that goes through a workflow, on the conversation's
// map: a frame named after the workflow holding its stages in order, each
// the card of the agent that runs it, a stage leading to the next. The stage
// the work is at is the work's own card, live; the stages it went through
// are hollow and checked, those ahead hollow, showing who will take it.
Item {
  id: lane

  // The work's node: {key, agent, title, lane: {name, steps, at}}.
  required property var node
  property bool selected: false
  required property int cardWidth
  required property int cardHeight
  required property int gap
  required property int pad
  required property int head
  signal chosen()

  readonly property var steps: node.lane.steps
  readonly property int at: node.lane.at

  width: steps.length * cardWidth + (steps.length - 1) * gap + 2 * pad
  height: head + cardHeight + pad

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.color: Qt.alpha(Theme.secondary, 0.35)
  }
  Row {
    x: 14
    y: 12
    spacing: 12
    Label { text: "WORKFLOW"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 2.5 }
    DecodeLabel { value: lane.node.lane.name.toUpperCase(); color: Theme.secondary; font.pixelSize: 12; font.letterSpacing: 2.5 }
  }

  // A stage to the next: a solid arrow between their cards.
  Repeater {
    model: lane.steps.length - 1
    delegate: Shape {
      id: link
      required property int index
      readonly property real x1: lane.pad + (index + 1) * lane.cardWidth + index * lane.gap
      readonly property real x2: x1 + lane.gap
      readonly property real y1: lane.head + lane.cardHeight / 2
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeColor: Qt.alpha(Theme.secondary, 0.8)
        strokeWidth: 1.5
        fillColor: "transparent"
        startX: link.x1
        startY: link.y1
        PathLine { x: link.x2 - 1; y: link.y1 }
      }
      ShapePath {
        strokeColor: "transparent"
        fillColor: Qt.alpha(Theme.secondary, 0.8)
        startX: link.x2
        startY: link.y1
        PathLine { x: link.x2 - 7; y: link.y1 - 4 }
        PathLine { x: link.x2 - 7; y: link.y1 + 4 }
      }
    }
  }

  Repeater {
    model: lane.steps
    delegate: AgentNode {
      required property var modelData
      required property int index
      readonly property bool current: index === lane.at
      x: lane.pad + index * (lane.cardWidth + lane.gap)
      y: lane.head
      key: current ? lane.node.key : ""
      agent: current ? lane.node.agent : modelData.agent
      title: current ? lane.node.title : index < lane.at ? "went through it" : index === lane.at + 1 ? "takes it next" : "takes it later"
      idle: !current
      stage: modelData.name
      stageIndex: index
      passed: index < lane.at
      selected: current && lane.selected
      onChosen: lane.chosen()
    }
  }
}
