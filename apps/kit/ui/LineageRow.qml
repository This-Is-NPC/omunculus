pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Breakpoints.js" as Breakpoints

// LineageRow is a work, or several finished ones folded into one line, as a
// level of the hierarchy: the one row grammar of chat, tree, log, cost and
// artifacts. Left to right: the lifeline of its depth (Lifeline), its mark
// (the agent's dot), a chevron when it folds works, the agent's name in
// its tone (AgentName), its title and a dim `meta` after it ("7 entries"), at
// the right the open arrow (a scope of its own) and its state as icon and
// word (StateMark). Narrow, the state goes under the title.
// Geometry as Lifeline: depth, rails, last, stem; `origin` is where column 0
// starts. A fold shows several agents' names in `agent` and
// "N folded  ·  last title" in `title`.
// Signals: toggled() the chevron, opened() the arrow, chosen() the row.
Item {
  id: row

  property int depth: 0
  property var rails: []
  property bool last: false
  property bool stem: false
  property real unit: Theme.size.gutter
  property real origin: 0

  property string agent: ""
  property color tone: Theme.dim
  property string title: ""
  property string meta: ""
  property string state: ""
  property string stateText: ""
  property bool folds: false
  property bool open: false
  property bool linked: true
  property bool picked: false
  readonly property bool narrow: width < 560

  signal toggled()
  signal opened()
  signal chosen()

  readonly property real textX: origin + (depth + 1) * unit
  readonly property real markY: Theme.space.tight + head.implicitHeight / 2

  implicitHeight: body.implicitHeight + Theme.space.tight * 2
  Accessible.role: Accessible.TreeItem
  Accessible.name: agent + ", " + title + ", " + stateText.toLowerCase()

  Lifeline {
    depth: row.depth
    rails: row.rails
    line: row.depth > 0 ? "elbow" : "none"
    last: row.last
    stem: row.stem
    unit: row.unit
    origin: row.origin
    markY: row.markY
  }

  MouseArea {
    anchors.fill: parent
    anchors.leftMargin: row.textX - row.unit
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.chosen()
  }

  // The mark: the agent's dot, where the lifeline reaches the row.
  Dot {
    x: row.origin + row.depth * row.unit + row.unit / 2 - width / 2
    y: row.markY - height / 2
    size: Theme.space.tight
    tone: row.tone
  }

  ColumnLayout {
    id: body
    x: row.textX
    y: Theme.space.tight
    width: row.width - x - Theme.space.cell
    spacing: Theme.space.row

    RowLayout {
      id: head
      Layout.fillWidth: true
      spacing: Theme.space.gap

      // The chevron that folds the works under it, before its agent.
      Item {
        visible: row.folds
        Layout.preferredWidth: Theme.type.log.size + 1
        Layout.preferredHeight: Theme.type.log.size + 1
        Layout.alignment: Qt.AlignVCenter
        Icon {
          anchors.centerIn: parent
          name: row.open ? "chevron-down" : "chevron-right"
          size: Theme.type.log.size + 1
          color: fold.containsMouse ? Theme.primary : Theme.dim
        }
        MouseArea {
          id: fold
          anchors.fill: parent
          anchors.margins: -Theme.space.tight
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: row.toggled()
        }
      }
      AgentName {
        dot: false
        name: row.agent
        tone: row.tone
        limit: body.width * (row.narrow ? 0.6 : 0.4)
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.title + (row.meta !== "" ? Theme.type.meta.separator + row.meta : "")
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        elide: Text.ElideRight
      }
      IconButton {
        visible: row.linked
        quiet: true
        name: "open"
        tip: "open this work on its own"
        Layout.preferredWidth: Breakpoints.target(Window.width)
        Layout.preferredHeight: Breakpoints.target(Window.width)
        onClicked: row.opened()
      }
      StateMark {
        visible: !row.narrow && row.state !== ""
        Layout.minimumWidth: Theme.size.gutter * 7
        Layout.maximumWidth: Theme.size.gutter * 7
        state: row.state
        text: row.stateText
      }
    }
    StateMark {
      visible: row.narrow && row.state !== ""
      Layout.fillWidth: true
      state: row.state
      text: row.stateText
    }
  }
}
