pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ProjectOverview is one project of the server as it runs: its depths are lanes
// down the whole project, marked by dashed lines, and each place a work can run
// in is a band across them. Its header folds it to one line: what each place
// runs at each depth, and what never runs.
Item {
  id: project

  required property string projectId
  // The overview tool's answer, {error} when the project did not give one, or
  // undefined while it is asked.
  property var overview
  property bool folded: false
  // Workspace name ("" for the root) -> folded.
  property var bandsFolded: ({})
  signal agentPicked(string name)

  readonly property bool ready: !!overview && !overview.error
  readonly property var places: ready ? overview.places : []
  readonly property var depths: [...new Set(places.reduce((all, place) => all.concat(place.depths.map(entry => entry.depth)), []))]
    .sort((a, b) => a - b)
  readonly property real lane: depths.length ? width / depths.length : width
  // Agents that run nowhere: workflow-only in every place, in no stage.
  readonly property var idle: {
    const ran = new Set()
    const idle = new Set()
    for (const place of places)
      for (const entry of place.depths) {
        Studio.staged(entry).forEach(agent => ran.add(agent.name))
        entry.agents.forEach(agent => agent.idle ? idle.add(agent.name) : ran.add(agent.name))
      }
    return [...idle].filter(name => !ran.has(name))
  }

  implicitHeight: frame.implicitHeight

  Rectangle {
    id: frame
    width: parent.width
    implicitHeight: column.implicitHeight + 2
    color: "transparent"
    border.color: Theme.line

    ColumnLayout {
      id: column
      width: parent.width
      spacing: 0

      // The header: the whole project on one line, and the way to fold it.
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: head.implicitHeight + 20
        color: headPointer.containsMouse ? Theme.highlight : "transparent"
        MouseArea { id: headPointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: project.folded = !project.folded }
        Flow {
          id: head
          anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 14 }
          spacing: 14
          Label { text: project.folded ? "▸" : "▾"; color: Theme.dim }
          Label { text: project.projectId.toUpperCase(); color: Theme.primary; font.pixelSize: 15; font.letterSpacing: 5 }
          Label { text: project.ready ? project.overview.root : ""; color: Theme.dim; font.pixelSize: 10 }
          Label {
            visible: !project.ready
            text: !project.overview ? "reading" : project.overview.error || ""
            color: project.overview && project.overview.error ? Theme.warning : Theme.dim
            font.pixelSize: 10
          }
          Repeater {
            model: project.places
            delegate: Label {
              required property var modelData
              text: (modelData.workspace || "root") + ": " + (Studio.runsAt(modelData, ", ") || "depth 0 only")
              color: Theme.dim
              font.pixelSize: 10
            }
          }
          Label {
            visible: project.idle.length > 0
            text: project.idle.join(", ") + " never runs"
            color: Theme.warning
            font.pixelSize: 10
          }
          Label {
            visible: project.ready && project.overview.unused_workflows.length > 0
            text: project.ready ? project.overview.unused_workflows.join(", ") + ": no workspace runs it" : ""
            color: Theme.warning
            font.pixelSize: 10
          }
        }
      }

      Item {
        id: lanes
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.rightMargin: 14
        Layout.bottomMargin: 14
        visible: !project.folded && project.ready
        implicitHeight: heads.implicitHeight + bands.implicitHeight

        Row {
          id: heads
          width: parent.width
          Repeater {
            model: project.depths
            delegate: Column {
              required property int modelData
              width: lanes.width / Math.max(1, project.depths.length)
              topPadding: 4
              bottomPadding: 10
              leftPadding: 14
              spacing: 2
              Caption { text: "DEPTH " + parent.modelData }
              Label {
                text: parent.modelData === 0 ? "talks with you · hands works down" : "works handed down from depth " + (parent.modelData - 1)
                color: Theme.dim
                font.pixelSize: 10
              }
            }
          }
        }

        Column {
          id: bands
          anchors.top: heads.bottom
          width: parent.width
          spacing: 12
          Repeater {
            model: project.places
            delegate: WorkspaceBand {
              required property var modelData
              width: bands.width
              place: modelData
              depths: project.depths
              projectRoot: project.overview.root
              folded: !!project.bandsFolded[modelData.workspace || ""]
              onToggled: project.bandsFolded = Object.assign({}, project.bandsFolded, { [modelData.workspace || ""]: !folded })
              onAgentPicked: name => project.agentPicked(name)
            }
          }
        }

        // The lanes: a dashed line between depths, through every band.
        Canvas {
          id: rails
          anchors { left: parent.left; right: parent.right; top: bands.top; bottom: bands.bottom }
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          Connections { target: project; function onDepthsChanged() { rails.requestPaint() } }
          onPaint: {
            const context = getContext("2d")
            context.reset()
            context.strokeStyle = String(Theme.line)
            context.lineWidth = 1
            context.setLineDash([4, 4])
            const count = project.depths.length
            for (let at = 1; at < count; at++) {
              const x = Math.round(width * at / count) + 0.5
              context.beginPath()
              context.moveTo(x, 0)
              context.lineTo(x, height)
              context.stroke()
            }
          }
        }
      }
    }
  }
}
