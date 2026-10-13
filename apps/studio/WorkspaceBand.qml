pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkspaceBand is one place of a project crossing its depth lanes: a strip
// with the workspace, its folder, whether it is the default, its own ceiling
// lists and what it overlays; under it, each depth as it runs there — its
// workflow's stages with their agents, or the agents a work goes to. Folded, it
// keeps the strip and says what each depth runs.
Item {
  id: band

  required property var place
  // The depths of the whole project, one lane each.
  required property var depths
  required property string projectRoot
  property bool folded: false
  signal toggled()
  signal agentPicked(string name)

  readonly property string name: place.workspace || ""
  readonly property real lane: depths.length ? width / depths.length : width
  readonly property string folder: place.outside ? place.root
    : place.root.startsWith(projectRoot + "/") ? place.root.slice(projectRoot.length + 1) + "/"
    : place.root
  readonly property string runs: Studio.runsAt(place, "  ·  ")

  implicitHeight: strip.implicitHeight + (folded ? 0 : cells.implicitHeight)

  // The box behind the strip and every cell of the place.
  Rectangle {
    anchors.fill: parent
    color: Qt.alpha(Theme.success, 0.07)
    border.color: Qt.alpha(Theme.success, 0.45)
    Rectangle { width: 3; height: parent.height; color: Theme.success }
  }

  Rectangle {
    id: strip
    width: parent.width
    implicitHeight: stripRow.implicitHeight + 14
    color: Qt.alpha(Theme.success, 0.2)

    Flow {
      id: stripRow
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 14 }
      spacing: 10

      Label {
        text: band.folded ? "▸" : "▾"
        color: Theme.secondary
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: band.toggled() }
      }
      Label {
        text: band.name || "project root"
        color: Theme.foreground
        font.pixelSize: 13
        font.letterSpacing: 2
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: band.toggled() }
      }
      Label {
        text: band.folder + (band.place.outside ? "  ·  outside the project" : "")
        color: band.place.outside ? Theme.warning : Theme.dim
        font.pixelSize: 10
      }
      Rectangle {
        visible: band.place.default
        implicitWidth: tag.implicitWidth + 10
        implicitHeight: 15
        color: "transparent"
        border.color: Theme.success
        Label { id: tag; anchors.centerIn: parent; text: "DEFAULT"; color: Theme.success; font.pixelSize: 9; font.letterSpacing: 2 }
      }
      Repeater {
        model: band.place.layer ? [].concat(
          band.place.layer.mode ? [{ name: band.place.layer.mode, state: "askable" }] : [],
          band.place.layer.has.map(name => ({ name: name, state: "have" })),
          band.place.layer.negotiable.map(name => ({ name: name, state: "askable" })),
          band.place.layer.human.map(name => ({ name: name, state: "sealed" })),
          band.place.layer.deny.map(name => ({ name: name, state: "blocked" }))) : []
        delegate: ToolChip {
          required property var modelData
          tool: modelData
        }
      }
      ChangeMark {
        visible: band.place.changes.length > 0
        text: "changes " + band.place.changes.join(", ")
      }
      Label {
        visible: band.folded
        text: band.runs || "depth 0 only"
        color: Theme.dim
        font.pixelSize: 10
      }
    }
  }

  Row {
    id: cells
    anchors.top: strip.bottom
    width: parent.width
    visible: !band.folded

    Repeater {
      model: band.depths
      delegate: ColumnLayout {
        id: cell
        required property int modelData
        readonly property var entry: band.place.depths.find(item => item.depth === modelData) || null
        width: band.lane
        spacing: 10

        Item { implicitHeight: 2 }

        // Each workflow a work here may go through: its stages in order, each
        // with what it never has and its agent.
        Repeater {
          model: cell.entry ? cell.entry.workflows : []
          delegate: Rectangle {
            id: flow
            required property var modelData
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            implicitHeight: pipe.implicitHeight + 20
            color: Qt.alpha(Theme.background, 0.5)
            border.color: Theme.line

            ColumnLayout {
              id: pipe
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
              spacing: 8
              Flow {
                Layout.fillWidth: true
                spacing: 8
                Caption { text: "WORKFLOW " + flow.modelData.name.toUpperCase() }
                Label { visible: flow.modelData.required; text: "required"; color: Theme.warning; font.pixelSize: 10 }
                ChangeMark { visible: !!cell.entry && cell.entry.changed && band.name !== ""; text: band.name }
                Label { text: flow.modelData.stages.length + " stages"; color: Theme.dim; font.pixelSize: 10 }
              }
              Repeater {
                model: flow.modelData.stages
                delegate: ColumnLayout {
                  id: stage
                  required property var modelData
                  required property int index
                  readonly property bool last: index === flow.modelData.stages.length - 1
                  Layout.fillWidth: true
                  spacing: 5
                  Label {
                    visible: stage.index > 0
                    text: "↓"
                    color: Theme.primary
                  }
                  Label {
                    Layout.fillWidth: true
                    text: String(stage.index + 1).padStart(2, "0") + "  " + stage.modelData.name.toUpperCase()
                      + (stage.last ? "   → done, back to the depth above" : "")
                    color: Theme.secondary
                    font.pixelSize: 10
                    font.letterSpacing: 1.5
                    elide: Text.ElideRight
                  }
                  Flow {
                    Layout.fillWidth: true
                    visible: stage.modelData.deny.length > 0
                    spacing: 3
                    Label { text: "never here:"; color: Theme.dim; font.pixelSize: 10 }
                    Repeater {
                      model: stage.modelData.deny
                      delegate: ToolChip {
                        required property string modelData
                        tool: ({ name: modelData, state: "blocked" })
                      }
                    }
                  }
                  AgentCard {
                    Layout.fillWidth: true
                    agent: stage.modelData.agent
                    place: band.name
                    onPicked: band.agentPicked(agent.name)
                  }
                }
              }
            }
          }
        }

        Label {
          Layout.fillWidth: true
          Layout.leftMargin: 14
          Layout.rightMargin: 14
          visible: cell.entry !== null && cell.entry.depth > 0 && cell.entry.agents.length > 0
            && !cell.entry.workflows.some(workflow => workflow.required)
          text: (cell.entry && cell.entry.workflows.length > 0 ? "or no workflow" : "no workflow") + (cell.entry && cell.entry.changed && band.name !== "" ? " here" : "") + " — a work goes to the agent it names, or the first:"
          color: Theme.dim
          font.pixelSize: 10
          wrapMode: Text.Wrap
        }

        Repeater {
          model: cell.entry ? cell.entry.agents : []
          delegate: AgentCard {
            required property var modelData
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 14
            agent: modelData
            place: band.name
            onPicked: band.agentPicked(agent.name)
          }
        }

        Item { implicitHeight: 6 }
      }
    }
  }
}
