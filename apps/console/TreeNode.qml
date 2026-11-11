pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Tree.js" as Tree
import "kit/ui"

// TreeNode is one row of the TREE page (a row of Tree.rows): the agent that
// talks with you at the root, or a work. The lines on its left draw the tree:
// a rail for each level above that goes on down, an elbow from its parent to
// its mark, and a stem from its mark to the rows under it. A work's mark is a
// chevron while it handed works down, else a dot in its agent's tone; then its
// agent in that tone and its title, under them its steps, its cost and what
// it handed down while folded, and a badge per request between it and others.
// At the right, in columns, its stages as a track (`StageTrack`), its state
// in words (WORKING, WAITING FOR <child or who>, WAITING FOR YOU, DONE) and
// how long it has run; narrow, the track and the state go under the title and
// the time ends the agent's line. Under the title go what it does now, its
// steps and, priced, its cost; its tokens are the cost page's. Opened, its runs, one line each, show
// inside it, with the ways on to its detail and its log; the rail of its
// mark ends at the mark unless rows hang under it.
Item {
  id: branch

  // A row of Tree.rows.
  required property var row
  // The width of one level.
  property real unit: Theme.size.gutter
  // The row picked, at one end of the request picked, the keyboard's.
  property bool picked: false
  property bool highlighted: false
  property bool focused: false
  // Whether its runs and steps show inside it.
  property bool expanded: false

  // Picked; its chevron; a request's badge; the ways on from its runs.
  signal chosen()
  signal toggled()
  signal requestPicked(string id)
  signal detailWanted()
  signal logWanted()

  readonly property var node: row.kind === "work" ? row.node : null
  readonly property var front: row.kind === "front" ? row.front : null
  readonly property string agent: front ? front.agent : node ? node.agent : ""
  readonly property real now: Omunculus.tick

  // Where the lines meet: the column of its parent, its own mark, its words.
  readonly property real elbowX: (row.depth - 1) * unit + unit / 2
  readonly property real markX: row.depth * unit + unit / 2
  readonly property real markY: Theme.space.tight + head.height / 2
  readonly property real textX: (row.depth + 1) * unit
  // The columns at the right, where there is room for them.
  readonly property bool columns: width - textX >= 640
  readonly property real stageWidth: 130
  readonly property real stateWidth: 240
  readonly property real timeWidth: 60

  readonly property var said: front ? Tree.frontState(front) : node ? Tree.stateOf(node) : null
  readonly property real seconds: front ? Tree.frontElapsed(Omunculus.progress, now) : node ? Tree.elapsed(node, now) : 0

  // A tally's money when the provider priced it; tokens are the cost page's.
  function spent(usage) {
    return usage.calls > 0 && usage.priced > 0 ? Omunculus.money(usage.cost) : ""
  }

  // What it does now while it works, what it handed down while folded, its own
  // steps and its branch's cost, as parts that give way whole, last first.
  readonly property var totals: {
    if (!node)
      return front ? [front.agents + (front.agents === 1 ? " agent" : " agents")] : []
    const parts = node.state === "working" && node.doing ? [node.doing] : []
    if (row.kids > 0 && !row.open)
      parts.push(Progress.below(Progress.kidsOf(node)))
    if (node.calls > 0)
      parts.push(node.calls + (node.calls === 1 ? " step" : " steps"))
    const money = spent(node.branch.usage)
    if (money !== "")
      parts.push(money)
    return parts
  }

  // Incoming requests, one badge per agent asking and kind of request.
  readonly property var askedBy: {
    if (!node)
      return []
    const by = {}
    for (const request of node.asked) {
      const key = request.from + "\n" + request.mark.text
      by[key] = by[key] || { from: request.from, mark: request.mark, requests: [] }
      by[key].requests.push(request)
    }
    return Object.values(by).map(group => Object.assign(group, { asks: group.requests.reduce((sum, request) => sum + request.asks, 0) }))
  }

  implicitHeight: body.implicitHeight + Theme.space.tight * 2
  Accessible.role: Accessible.TreeItem
  Accessible.name: said ? agent + ", " + said.text.toLowerCase() + (node && node.title ? ", " + node.title : "") : agent

  // The lines of the tree, in the line's ink.
  Repeater {
    model: branch.row.rails
    delegate: Rectangle {
      required property bool modelData
      required property int index
      visible: modelData
      x: index * branch.unit + branch.unit / 2
      width: 1
      height: branch.height
      color: Theme.faint
    }
  }
  Rectangle {
    visible: branch.row.depth > 0
    x: branch.elbowX
    width: 1
    height: branch.row.last ? branch.markY : branch.height
    color: Theme.faint
  }
  Rectangle {
    visible: branch.row.depth > 0
    x: branch.elbowX
    y: branch.markY
    width: branch.markX - branch.elbowX - Theme.space.tight
    height: 1
    color: Theme.faint
  }
  Rectangle {
    visible: branch.row.stem
    x: branch.markX
    y: branch.markY + Theme.space.tight
    width: 1
    height: branch.height - y
    color: Theme.faint
  }

  // The picked row's wash, from its mark to the right edge; the keyboard's
  // ring is the only frame; a row that a request picked is washed in amber.
  Rectangle {
    id: wash
    x: branch.markX - branch.unit / 2
    width: branch.width - x
    height: branch.height
    color: branch.picked ? Theme.highlight : branch.highlighted ? Qt.alpha(Theme.warning, 0.12) : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
    Behavior on color { ColorAnimation { duration: 120 } }
    FocusRing { shown: branch.focused }
  }

  MouseArea {
    id: pointer
    anchors.fill: wash
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: branch.chosen()
  }

  // Its mark: a chevron over the rows it opens, else its agent's dot.
  Item {
    x: branch.markX - width / 2
    y: branch.markY - height / 2
    width: branch.unit
    height: branch.unit
    readonly property bool folds: branch.row.kind === "work" && branch.row.kids > 0
    Icon {
      visible: parent.folds
      anchors.centerIn: parent
      name: !branch.row.open ? "chevron-right" : "chevron-down"
      size: 12
      color: chevronHover.hovered ? Theme.primary : Theme.dim
    }
    Dot {
      visible: !parent.folds
      anchors.centerIn: parent
      size: branch.row.kind === "front" ? Theme.space.tight + 1 : Theme.space.line + 1
      tone: Omunculus.toneOf(branch.agent)
    }
    // Over the row's own pointer: the chevron folds, it does not pick.
    MouseArea {
      id: chevronHover
      readonly property bool hovered: containsMouse
      anchors.fill: parent
      enabled: parent.folds
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: branch.toggled()
    }
  }

  // Its stages, its state and its time, as the columns hold them and as they
  // go under the title.
  component StageCell: Item {
    Layout.alignment: Qt.AlignTop
    implicitWidth: cell.implicitWidth
    implicitHeight: cell.implicitHeight
    StageTrack { id: cell; width: parent.width; node: branch.node }
  }
  component StateCell: StateMark {
    Layout.alignment: Qt.AlignTop
    state: branch.said ? branch.said.state : ""
    text: branch.said ? branch.said.text : ""
  }
  component ElapsedCell: Label {
    Layout.alignment: Qt.AlignTop
    text: branch.seconds > 0 ? Progress.span(branch.seconds) : ""
    color: Theme.dim
    font.pixelSize: Theme.type.meta.size
    horizontalAlignment: Text.AlignRight
  }

  ColumnLayout {
    id: body
    x: branch.textX
    y: Theme.space.tight
    width: branch.width - x - Theme.space.cell
    spacing: Theme.space.row

    // Its agent, its title, and in columns its stages, state and time.
    RowLayout {
      id: head
      Layout.fillWidth: true
      spacing: Theme.space.gap

      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: Theme.space.row

        RowLayout {
          Layout.fillWidth: true
          spacing: Theme.space.gap
          Label {
            text: branch.agent
            color: Omunculus.toneOf(branch.agent)
            font.pixelSize: Theme.type.body.size
            font.bold: true
            elide: Text.ElideRight
            Layout.maximumWidth: body.width * 0.5
          }
          Label {
            visible: branch.columns || branch.front
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: branch.node ? branch.node.title : "Conversation with you"
            color: branch.front ? Theme.dim : Theme.foreground
            font.pixelSize: Theme.type.body.size
            elide: Text.ElideRight
          }
          Item { visible: !branch.columns && !branch.front; Layout.fillWidth: true }
          ElapsedCell { visible: !branch.columns }
        }
        Label {
          visible: !branch.columns && !!branch.node
          Layout.fillWidth: true
          text: branch.node ? branch.node.title : ""
          color: Theme.foreground
          font.pixelSize: Theme.type.body.size
          elide: Text.ElideRight
        }
      }

      StageCell { visible: branch.columns; Layout.minimumWidth: branch.stageWidth; Layout.maximumWidth: branch.stageWidth }
      StateCell { visible: branch.columns; Layout.minimumWidth: branch.stateWidth; Layout.maximumWidth: branch.stateWidth }
      ElapsedCell { visible: branch.columns; Layout.minimumWidth: branch.timeWidth; Layout.maximumWidth: branch.timeWidth }
    }

    // Narrow: its stages and its state under the title.
    Flow {
      visible: !branch.columns
      Layout.fillWidth: true
      spacing: Theme.space.gap
      StageCell { visible: !!branch.node && Progress.track(branch.node) !== null; width: branch.stageWidth }
      StateCell {}
    }

    // What it did and cost, which gives way first, a part at a time.
    Label {
      id: totalsLabel
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      visible: text !== ""
      text: {
        for (let count = branch.totals.length; count > 0; count--) {
          const shown = branch.totals.slice(0, count).join(Theme.type.meta.separator)
          if (metrics.advanceWidth(shown) <= body.width)
            return shown
        }
        return ""
      }
      color: Theme.dim
      font.pixelSize: Theme.type.meta.size
      FontMetrics { id: metrics; font: totalsLabel.font }
    }

    // What waits between it and others: what it asks, and the way it
    // climbed; what it is asked; what the front asks you.
    Flow {
      Layout.fillWidth: true
      Layout.topMargin: Theme.space.line
      visible: (branch.node && (branch.node.asks.length > 0 || branch.askedBy.length > 0)) || (branch.front && branch.front.asking !== "")
      spacing: Theme.space.tight
      Repeater {
        model: branch.node ? branch.node.asks : []
        delegate: Chip {
          required property var modelData
          icon: modelData.mark.icon
          text: modelData.mark.text + "  ·  " + modelData.chain.join(" › ")
          accent: modelData.forYou ? Theme.warning : Theme.primary
          alert: modelData.forYou
          tip: modelData.question.split("\n")[0]
          onClicked: branch.requestPicked(modelData.id)
        }
      }
      Repeater {
        model: branch.askedBy
        delegate: Chip {
          required property var modelData
          icon: modelData.mark.icon
          text: modelData.asks + " " + (modelData.asks === 1 ? modelData.mark.one : modelData.mark.many) + " from " + modelData.from
          tip: modelData.requests[0].question.split("\n")[0]
          onClicked: branch.requestPicked(modelData.requests[0].id)
        }
      }
      Chip {
        visible: !!branch.front && branch.front.asking !== ""
        icon: branch.front && branch.front.mark ? branch.front.mark.icon : ""
        text: branch.front ? (branch.front.mark ? branch.front.mark.text + "  ·  " : "") + branch.front.asker + " asks you " + branch.front.asking : ""
        accent: Theme.warning
        alert: true
        onClicked: branch.requestPicked(branch.front.ask)
      }
    }

    // Opened: its runs, call by call, and the ways on.
    ColumnLayout {
      Layout.fillWidth: true
      Layout.topMargin: Theme.space.tight
      visible: branch.expanded && !!branch.node
      spacing: Theme.space.tight
      Loader {
        Layout.fillWidth: true
        Layout.preferredHeight: active && item ? Math.min(260, item.implicitHeight) : 0
        active: branch.expanded && !!branch.node
        sourceComponent: WorkRuns { key: branch.node ? branch.node.work : "" }
      }
      RowLayout {
        spacing: Theme.space.tight
        TraceButton { role: "action"; dense: true; text: "DETAIL"; icon: "open"; tip: "the work in full"; onClicked: branch.detailWanted() }
        TraceButton { role: "action"; dense: true; text: "LOG"; icon: "list"; tip: "the log kept to this work"; onClicked: branch.logWanted() }
      }
    }
  }
}
