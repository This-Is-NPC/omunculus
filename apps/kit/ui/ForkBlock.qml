pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// ForkBlock is works that ran at once, as the hierarchy shows them
// everywhere: on the lifeline a numbered mark and a line "PARALLEL ×4 · 2
// DONE · 2 WORKING" (`summary`), under it one lane card per work, side by side
// while they fit and stacked when not. A card has the agent (AgentName), the
// work's title and its state (StateMark); choosing it emits opened(work).
// `lanes` is [{work, agent, tone, title, state, stateText}]. Geometry as
// Lifeline: depth, rails, last; `origin` is where column 0 starts.
Item {
  id: fork

  property int depth: 0
  property var rails: []
  property bool last: false
  property real unit: Theme.size.gutter
  property real origin: 0
  property string summary: ""
  property var lanes: []
  // The width a lane card is at least.
  property real laneWidth: Theme.size.gutter * 6

  signal opened(string work)

  readonly property real textX: origin + (depth + 1) * unit
  readonly property real room: width - textX - Theme.space.cell
  readonly property int columns: Math.max(1, Math.min(lanes.length, Math.floor((room + Theme.space.tight) / (laneWidth + Theme.space.tight))))
  readonly property real markY: Theme.space.tight + head.implicitHeight / 2

  implicitHeight: body.implicitHeight + Theme.space.tight * 2
  Accessible.role: Accessible.Grouping
  Accessible.name: summary

  Lifeline {
    depth: fork.depth
    rails: fork.rails
    line: fork.depth > 0 ? "elbow" : "none"
    last: fork.last
    stem: false
    unit: fork.unit
    origin: fork.origin
    markY: fork.markY
  }

  // The numbered mark.
  Rectangle {
    x: fork.origin + fork.depth * fork.unit + fork.unit / 2 - width / 2
    y: fork.markY - height / 2
    width: fork.unit
    height: width
    radius: width / 2
    color: Theme.primary
    Label {
      anchors.centerIn: parent
      text: fork.lanes.length
      color: Theme.background
      font.pixelSize: Theme.type.log.size
      font.bold: true
    }
  }

  ColumnLayout {
    id: body
    x: fork.textX
    y: Theme.space.tight
    width: fork.room
    spacing: Theme.space.gap

    Label {
      id: head
      Layout.fillWidth: true
      text: fork.summary
      color: Theme.dim
      font.pixelSize: Theme.type.header.size
      font.letterSpacing: Theme.type.header.tracking
      elide: Text.ElideRight
    }

    Flow {
      Layout.fillWidth: true
      spacing: Theme.space.tight
      Repeater {
        model: fork.lanes
        delegate: SurfaceFrame {
          id: lane
          required property var modelData
          width: (body.width - (fork.columns - 1) * Theme.space.tight) / fork.columns
          implicitHeight: card.implicitHeight + Theme.space.insetTop
          height: implicitHeight
          variant: "outline"
          active: pointer.containsMouse
          Accessible.role: Accessible.Button
          Accessible.name: modelData.agent + ", " + modelData.title + ", " + modelData.stateText.toLowerCase()

          ColumnLayout {
            id: card
            x: Theme.space.gap
            y: Theme.space.tight
            width: parent.width - Theme.space.gap * 2
            spacing: Theme.space.line
            AgentName { name: lane.modelData.agent; tone: lane.modelData.tone; limit: card.width }
            Label {
              Layout.fillWidth: true
              text: lane.modelData.title
              color: Theme.foreground
              font.pixelSize: Theme.type.body.size
              elide: Text.ElideRight
            }
            StateMark { Layout.fillWidth: true; state: lane.modelData.state; text: lane.modelData.stateText }
          }
          MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: fork.opened(lane.modelData.work)
          }
        }
      }
    }
  }
}
