import QtQuick
import "kit/ui"

// FlowNode is one box of the flowchart: you, an agent a work goes to, or a
// stage of a workflow with the agent that runs it. Its name decodes when it
// comes into view; picked, it is outlined in the accent. An agent no stage
// and no depth runs shows hollow.
Item {
  id: node

  // {kind: "person" | "agent" | "stage", agent, stage, index, last, pack, ...}
  required property var spec
  property bool picked: false
  // Its place in the order the flow draws, so the nodes arrive one by one.
  property int order: 0

  signal chosen()

  // The keyboard reaches each agent's box; Enter or Space picks it.
  activeFocusOnTab: !person
  Keys.onReturnPressed: chosen()
  Keys.onSpacePressed: chosen()

  readonly property var agent: spec.agent || null
  readonly property bool person: spec.kind === "person"
  readonly property color tone: person ? Theme.primary : agent ? Studio.toneOf(agent.name) : Theme.dim
  readonly property color edge: picked ? Theme.primary : pointer.containsMouse ? Qt.alpha(tone, 0.9) : Qt.alpha(tone, 0.45)
  readonly property int tools: agent ? agent.tools.filter(tool => tool.state === "have").length : 0
  readonly property int asks: agent ? agent.tools.filter(tool => tool.state === "askable" || tool.state === "sealed").length : 0

  opacity: 0
  transform: Translate { id: rise; y: 14 }
  Component.onCompleted: arrive.start()
  SequentialAnimation {
    id: arrive
    PauseAnimation { duration: Math.min(900, node.order * 45) }
    ParallelAnimation {
      NumberAnimation { target: node; property: "opacity"; to: node.agent && node.agent.idle ? 0.55 : 1; duration: 260; easing.type: Easing.OutCubic }
      NumberAnimation { target: rise; property: "y"; to: 0; duration: 320; easing.type: Easing.OutCubic }
    }
  }

  // The glow under a picked node.
  Rectangle {
    anchors { fill: parent; margins: -6 }
    radius: 4
    color: "transparent"
    border.color: Qt.alpha(Theme.primary, 0.35)
    border.width: 6
    opacity: node.picked ? 0.6 : 0
    Behavior on opacity { NumberAnimation { duration: 200 } }
  }

  Rectangle {
    id: body
    anchors.fill: parent
    color: Qt.tint(Theme.background, Qt.alpha(node.tone, node.picked ? 0.12 : pointer.containsMouse ? 0.08 : 0.04))
    border.color: node.agent && node.agent.idle ? Theme.line : node.edge
    Behavior on border.color { ColorAnimation { duration: 160 } }

    Column {
      anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 14; topMargin: 12 }
      spacing: 6

      // What the node is: a stage's place in its workflow, an agent, or you.
      Row {
        spacing: 8
        Label {
          renderType: Text.CurveRendering
          text: node.person ? "ORIGIN"
            : node.spec.kind === "stage" ? String(node.spec.index + 1).padStart(2, "0") + " · " + node.spec.stage.toUpperCase()
            : "AGENT"
          color: node.spec.kind === "stage" ? Theme.secondary : Theme.dim
          font.pixelSize: 12
          font.letterSpacing: 2.5
        }
        Label {
          renderType: Text.CurveRendering
          visible: !!node.spec.pack
          text: "◆ " + (node.spec.pack || "").toUpperCase()
          color: Theme.magenta
          font.pixelSize: 12
          font.letterSpacing: 2
        }
      }

      DecodeLabel {
        renderType: Text.CurveRendering
        width: parent.width
        value: node.person ? "YOU" : node.agent ? node.agent.name : ""
        color: node.tone
        font.pixelSize: node.person ? 26 : 22
        font.letterSpacing: node.person ? 8 : 1.5
        elide: Text.ElideRight
      }

      Label {
        renderType: Text.CurveRendering
        width: parent.width
        visible: !node.person
        text: node.agent ? (node.agent.model.id || node.agent.model.name) : ""
        color: Theme.dim
        font.pixelSize: 14
        elide: Text.ElideMiddle
      }

      Label {
        renderType: Text.CurveRendering
        visible: node.person
        text: "talks with depth 0"
        color: Theme.dim
        font.pixelSize: 14
      }

      // What it has, what it must ask for, and its skills.
      Row {
        visible: !node.person
        spacing: 14
        Label { renderType: Text.CurveRendering; text: node.tools + " TOOLS"; color: Theme.foreground; opacity: 0.75; font.pixelSize: 12; font.letterSpacing: 1.5 }
        Label { renderType: Text.CurveRendering; visible: node.asks > 0; text: node.asks + " ASK"; color: Theme.warning; font.pixelSize: 12; font.letterSpacing: 1.5 }
        Label {
          renderType: Text.CurveRendering
          visible: !!node.agent && node.agent.skills.length > 0
          text: (node.agent ? node.agent.skills.length : 0) + " SKILLS"
          color: Theme.secondary
          font.pixelSize: 12
          font.letterSpacing: 1.5
        }
        Label { renderType: Text.CurveRendering; visible: !!node.agent && node.agent.idle; text: "IDLE"; color: Theme.warning; font.pixelSize: 12; font.letterSpacing: 1.5 }
      }
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: node.person ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!node.person) node.chosen()
    }
  }

  FocusRing { anchors.margins: -4 }
}
