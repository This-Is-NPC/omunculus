pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Team.js" as Team
import "kit/ui"

// TeamNode is one row of the TEAM page's tree (a row of Team.rows): the
// agent that talks with you at the root, a work, or a fold of several. The
// lines on its left draw the tree: a rail for each level above that goes on
// down, an elbow from its parent to its mark, and a stem from its mark to the
// rows under it. A work's mark is a chevron while it handed works down, else
// a dot in its agent's tone; then its agent in that tone (the agents of its
// stages where there is room, the one at work lit and those to come faint), its title and its state
// at the right — what it does and a clock while it works, whom it waits on,
// "Needs you" in the warning tone — and under them its stages, its time,
// steps and cost, what it handed down while folded, and a badge per request
// between it and others. Narrow, the title goes under the agent.
Item {
  id: branch

  // A row of Team.rows.
  required property var row
  // The width of one level.
  property real unit: Theme.size.gutter
  // The row picked, at one end of the request picked, the keyboard's.
  property bool picked: false
  property bool highlighted: false
  property bool focused: false

  // Picked; its chevron, or a fold, opened or closed; a request's badge.
  signal chosen()
  signal toggled()
  signal requestPicked(string id)

  readonly property var node: row.kind === "work" ? row.node : null
  // Who it is: the agent at work on it, or once it is closed, the one it is
  // known by.
  readonly property string agent: front ? front.agent : !node ? "" : Progress.closed(node.state) ? Team.holder(node) : node.agent
  readonly property var front: row.kind === "front" ? row.front : null
  readonly property real now: Omunculus.tick

  // Where the lines meet: the column of its parent, its own mark, its words.
  readonly property real elbowX: (row.depth - 1) * unit + unit / 2
  readonly property real markX: row.depth * unit + unit / 2
  readonly property real markY: Theme.space.tight + head.height / 2
  readonly property real textX: (row.depth + 1) * unit
  // Short of room, the title goes under the agent.
  readonly property bool stacked: width - textX < 520

  // A work that waits on works at work below it reads as them at work.
  readonly property var underway: node && node.state === "waiting" ? Progress.underway(node) : []
  readonly property string shownState: front ? front.state : !node ? "" : underway.length > 0 ? "working" : node.state
  readonly property string saying: front ? (front.state === "working" || front.state === "waiting" ? front.doing : front.state === "idle" ? "Idle" : "")
    : !node ? ""
    : underway.length > 0 ? Array.from(new Set(underway.map(each => each.agent))).join(", ") + " working"
    : node.state === "working" ? Progress.lively(node.doing, node.since, now)
    : node.state === "waiting" || node.state === "stopped" || node.state === "failed" ? node.doing : ""
  readonly property var since: front ? (front.state === "working" ? front.since : null) : node && node.state === "working" ? node.since : null
  readonly property string clock: since !== null && since !== undefined ? Progress.clock(Math.max(0, Math.round(now - since))) : ""

  // The agents of its stages, first first, each with where it is.
  readonly property var agents: node ? Team.stages(node) : []

  // A tally's money when the provider priced it, else its tokens, worded as
  // the cost page does.
  function spent(usage) {
    if (usage.calls === 0)
      return ""
    return usage.priced > 0 ? Omunculus.money(usage.cost) : Omunculus.tokens(usage.input) + " read" + Theme.type.meta.separator + Omunculus.tokens(usage.output) + " written"
  }

  // What it handed down while folded, its time, its own steps and its
  // branch's cost, as parts that give way whole, last first.
  readonly property var totals: {
    if (!node)
      return []
    const parts = row.kids > 0 && !row.open ? [Progress.below(Progress.kidsOf(node))] : []
    parts.push(node.finishedIn !== null ? "took " + Progress.span(node.finishedIn)
      : Progress.span(Progress.closed(node.state) ? node.branch.seconds : Math.max(0, now - node.created)))
    if (node.calls > 0)
      parts.push(node.calls + (node.calls === 1 ? " step" : " steps"))
    const money = spent(node.branch.usage)
    if (money !== "")
      parts.push(money)
    return parts
  }

  // Incoming requests, one badge per agent asking.
  readonly property var askedBy: {
    if (!node)
      return []
    const by = {}
    for (const request of node.asked)
      (by[request.from] = by[request.from] || []).push(request)
    return Object.keys(by).map(from => ({ from: from, requests: by[from], asks: by[from].reduce((sum, request) => sum + request.asks, 0) }))
  }

  implicitHeight: body.implicitHeight + Theme.space.tight * 2
  Accessible.role: Accessible.TreeItem
  Accessible.name: node ? node.agent + ", " + node.word + (node.title ? ", " + node.title : "") : front ? front.agent : row.text || ""

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

  // The picked row's wash and frame, from its mark to the right edge.
  Rectangle {
    id: wash
    x: branch.markX - branch.unit / 2
    width: branch.width - x
    height: branch.height
    color: branch.picked ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
    border.color: branch.highlighted ? Theme.warning : branch.picked ? Theme.primary : "transparent"
    Behavior on color { ColorAnimation { duration: 120 } }
    FocusRing { shown: branch.focused }
  }

  MouseArea {
    id: pointer
    anchors.fill: wash
    enabled: branch.row.kind !== "front"
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: branch.row.kind === "fold" ? branch.toggled() : branch.chosen()
  }

  // Its mark: a chevron over the rows it opens, else its agent's dot.
  Item {
    x: branch.markX - width / 2
    y: branch.markY - height / 2
    width: branch.unit
    height: branch.unit
    readonly property bool folds: branch.row.kind === "fold" || (branch.row.kind === "work" && branch.row.kids > 0)
    Icon {
      visible: parent.folds
      anchors.centerIn: parent
      name: (branch.row.kind === "fold" ? branch.row.folded : !branch.row.open) ? "chevron-right" : "chevron-down"
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

  ColumnLayout {
    id: body
    x: branch.textX
    y: Theme.space.tight
    width: branch.width - x - Theme.space.cell
    spacing: Theme.space.row

    // Its agent, its title, its state.
    RowLayout {
      id: head
      Layout.fillWidth: true
      spacing: Theme.space.gap

      // A fold: what it holds.
      Label {
        visible: branch.row.kind === "fold"
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: (branch.row.fold === "next" ? "○ " : "✓ ") + (branch.row.text || "")
        color: Theme.dim
        font.pixelSize: Theme.type.tab.size
        elide: Text.ElideRight
      }

      // Its agent, or the agents of its stages with the current one lit.
      Row {
        id: names
        visible: branch.row.kind !== "fold"
        readonly property bool chain: branch.agents.length > 1 && chainWidth.advanceWidth(branch.agents.map(each => each.agent).join(" › ")) <= (branch.stacked ? body.width * 0.6 : body.width * 0.4)
        Layout.maximumWidth: branch.stacked ? body.width * 0.6 : body.width * 0.4
        clip: true
        spacing: 0
        Repeater {
          model: names.chain ? branch.agents : [{ agent: branch.agent, status: "current" }]
          delegate: Label {
            required property var modelData
            required property int index
            text: (index > 0 ? " › " : "") + modelData.agent
            color: Omunculus.toneOf(modelData.agent)
            // The one at work lit, those to come faint.
            opacity: modelData.status === "next" ? 0.45 : 1
            font.pixelSize: Theme.type.body.size
            font.bold: modelData.status === "current"
          }
        }
        FontMetrics { id: chainWidth; font.family: Theme.fontFamily; font.pixelSize: Theme.type.body.size; font.bold: true }
      }

      // The front: whom it talks with, how many agents.
      Label {
        visible: !!branch.front
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: branch.front ? "talks with you" + Theme.type.meta.separator + branch.front.agents + (branch.front.agents === 1 ? " agent" : " agents") : ""
        color: Theme.dim
        font.pixelSize: Theme.type.tab.size
        elide: Text.ElideRight
      }

      // Its title, beside the agent where there is room.
      Label {
        visible: !!branch.node && !branch.stacked
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: branch.node ? branch.node.title : ""
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        elide: Text.ElideRight
      }
      Item { visible: !!branch.node && branch.stacked; Layout.fillWidth: true }

      // Its words, or the state's own word when they do not fit, so the
      // clock stays.
      StateMark {
        id: mark
        readonly property real room: body.width * (branch.stacked ? 0.4 : 0.45)
        visible: branch.row.kind !== "fold" && branch.shownState !== ""
        Layout.fillWidth: false
        Layout.maximumWidth: room
        state: branch.shownState
        text: markFont.advanceWidth(branch.saying + " " + branch.clock) <= room - Theme.space.cell ? branch.saying : ""
        clock: branch.clock
        FontMetrics { id: markFont; font: mark.font }
      }
    }

    // Narrow: the title under the agent.
    Label {
      visible: !!branch.node && branch.stacked && text !== ""
      Layout.fillWidth: true
      text: branch.node ? branch.node.title : ""
      color: Theme.foreground
      font.pixelSize: Theme.type.body.size
      elide: Text.ElideRight
    }

    // Its stages, then its totals, which give way first, a part at a time.
    RowLayout {
      id: meta
      visible: !!branch.node
      Layout.fillWidth: true
      spacing: 0
      // As wide as the form of the stages that fits, the totals right after.
      Item {
        visible: stepper.visible
        Layout.preferredWidth: stepper.implicitWidth
        Layout.preferredHeight: stepper.implicitHeight
        Stepper {
          id: stepper
          width: Math.min(natural, body.width * 0.6)
          steps: branch.node ? branch.node.steps : []
          round: branch.node ? branch.node.round : 0
          size: Theme.type.meta.size
        }
      }
      Label {
        id: totalsLabel
        readonly property real room: Math.max(0, body.width - (stepper.visible ? stepper.implicitWidth : 0))
        readonly property string lead: stepper.visible ? Theme.type.meta.separator : ""
        // The longest run of the parts, from the first, that fits.
        text: {
          for (let count = branch.totals.length; count > 0; count--) {
            const shown = lead + branch.totals.slice(0, count).join(Theme.type.meta.separator)
            if (metrics.advanceWidth(shown) <= room)
              return shown
          }
          return ""
        }
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
      }
      FontMetrics { id: metrics; font: totalsLabel.font }
      Item { Layout.fillWidth: true }
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
          text: "⇡ " + modelData.chain.join(" › ")
          accent: modelData.human ? Theme.warning : Theme.primary
          alert: modelData.human
          tip: modelData.question.split("\n")[0]
          onClicked: branch.requestPicked(modelData.id)
        }
      }
      Repeater {
        model: branch.askedBy
        delegate: Chip {
          required property var modelData
          text: "⇣ " + modelData.asks + (modelData.asks === 1 ? " question" : " questions") + " from " + modelData.from
          tip: modelData.requests[0].question.split("\n")[0]
          onClicked: branch.requestPicked(modelData.requests[0].id)
        }
      }
      Chip {
        visible: !!branch.front && branch.front.asking !== ""
        text: branch.front ? "⇡ " + branch.front.asker + " asks you " + branch.front.asking : ""
        accent: Theme.warning
        alert: true
        onClicked: branch.requestPicked(branch.front.ask)
      }
    }
  }
}
