pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Tree.js" as Tree
import "kit/ui"

// BoardView is the works of every project the window reaches, those of
// every conversation you may read there, on a board: a column per state —
// open, waiting on a child, a request or your next message, broken and
// waiting on its parent to decide, done, cancelled — each headed by a rule,
// the latest changed first, each card a work. By agent or by project, the
// columns are crossed by a lane of each; with several projects, chips keep
// one. Under 700 px the board is one list instead, its rows under a rule of
// each state, and of each lane. Its readout counts the works shown, for the
// bar. A work opened opens its conversation's map with the work picked, on
// its project. `/` goes to the filter, which keeps the works whose title,
// project, conversation, workflow, stage or agent holds it; the arrows move
// between the cards, across the columns and down them, or along the list;
// Esc on the filter empties it, then goes back to the works, and on a work
// leaves.
Item {
  id: board

  // "", "agent" or "project": what lanes cross the columns.
  property string group: ""
  // The project whose works alone are shown, or "" for all of them.
  property string project: ""
  property string filter: ""
  // The time now, which the works' ages follow.
  property real now: Date.now()
  Timer { interval: 30000; repeat: true; running: board.visible; onTriggered: board.now = Date.now() }
  signal opened(var work)
  signal leave()

  readonly property string readout: shown.length + (shown.length === 1 ? " WORK" : " WORKS")

  readonly property var stateColumns: [
    { key: "open", tip: "an agent has it" },
    { key: "waiting", tip: "on a child, a request or your next message" },
    { key: "broken", tip: "it broke; its parent decides" },
    { key: "done", tip: "" },
    { key: "cancelled", tip: "" }
  ]
  readonly property int narrowest: 200

  // A work that broke waits on its parent without waiting on anything named.
  function stateOf(work) { return work.state === "waiting" && !work.waiting ? "broken" : work.state }

  // The work above a work, within its project.
  function above(work) {
    return work.parent_id ? Omunculus.board.find(item => item.project === work.project && item.id === work.parent_id) || null : null
  }
  // Its level: the works above it, and the front desk at 0.
  function levelOf(work) { return Tree.levelOf(work, above) }
  // Where it hangs: its level and the work above it, "level 2, under Sale".
  function lineageOf(work) {
    const parent = above(work)
    return "level " + levelOf(work) + (parent ? ", under " + parent.title : "")
  }
  // What else the board says of a work: its project, its stage of how many.
  function metaOf(work) {
    const lane = Omunculus.laneOf(work)
    return [
      work.project,
      lane ? "stage " + lane.steps[lane.at].name + " " + (lane.at + 1) + "/" + lane.steps.length : ""
    ].filter(part => part !== "").join(Theme.type.meta.separator)
  }
  function originOf(work) { return "in " + Omunculus.conversationLabel(work.conversation_id) }
  // Its state as the one status grammar has it.
  function markOf(work) {
    const state = stateOf(work)
    if (runs(work)) return { state: "working", text: "WORKING" }
    if (state === "waiting") return { state: "waiting", text: "WAITING ON A " + String(work.waiting).toUpperCase() }
    if (state === "broken") return { state: "stopped", text: "BROKEN" }
    return { state: state === "open" ? "up-next" : state, text: "" }
  }
  function ageOf(work) { return Omunculus.ago(work.updated_at || work.created_at, now) }
  function runs(work) { return Omunculus.boardBusy.includes(work.project + "/" + work.id) }

  readonly property var shown: {
    const words = filter.toLowerCase().split(/\s+/).filter(word => word)
    return Omunculus.board
      .filter(work => {
        const text = [work.title, work.project, Omunculus.agentOf(work), Omunculus.conversationLabel(work.conversation_id), work.workflow || "", work.stage || ""].join(" ").toLowerCase()
        return (project === "" || work.project === project) && words.every(word => text.includes(word))
      })
      .sort((a, b) => (b.updated_at || b.created_at).localeCompare(a.updated_at || a.created_at))
  }
  readonly property string emptyText: Omunculus.board.length === 0 ? "no work yet" : "no work matches “" + board.filter + "”"
  // Whether the board is one list rather than columns side by side.
  readonly property bool stacked: width < 700
  // Every state where there is room for them all, else those with a work.
  readonly property var columns: {
    const used = stateColumns.filter(state => shown.some(work => stateOf(work) === state.key))
    return width >= stateColumns.length * (narrowest + Theme.space.gap) || used.length === 0 ? stateColumns : used
  }
  readonly property real columnWidth: Math.floor((width - (columns.length - 1) * Theme.space.gap) / columns.length)
  // The lane of a work: its agent's, or its project's.
  function laneOf(work) { return group === "agent" ? Omunculus.agentOf(work) : work.project }
  // The lanes: one for every work, or one per agent or project with a work
  // shown, in their names' order.
  readonly property var lanes: group === "" ? [null] : Array.from(new Set(shown.map(work => laneOf(work)))).sort()
  function cell(lane, state) {
    return shown.filter(work => stateOf(work) === state && (lane === null || laneOf(work) === lane))
  }
  // The work ids of each column, top to bottom across the lanes, as the
  // arrows go.
  readonly property var grid: columns.map(column => [].concat(...lanes.map(lane => cell(lane, column.key).map(work => work.id))))
  readonly property var first: grid.reduce((found, ids) => found || ids[0] || "", "")
  // The list's rows: each lane's works by state, under the rule of both.
  readonly property var listed: [].concat(...lanes.map(lane => [].concat(...stateColumns.map(column => {
    const works = cell(lane, column.key)
    const title = (lane === null ? "" : lane + Theme.type.meta.separator) + column.key + "  " + works.length
    return works.map(work => Object.assign({ group: title }, work))
  }))))

  // Work id -> its card, and the one the keyboard was on last.
  property var cards: ({})
  property string current: ""

  function focusEntry() {
    if (stacked)
      return list.focusRows()
    const item = cards[current] || cards[first]
    if (item)
      item.forceActiveFocus()
    else
      board.forceActiveFocus()
  }

  function focusFilter() { filterBox.forceActiveFocus() }

  // An arrow from the card of `id`: up and down its column, left and right
  // to the nearest column with a card, at the same height where it can.
  function move(id, key) {
    const column = grid.findIndex(ids => ids.includes(id))
    if (column < 0)
      return false
    const row = grid[column].indexOf(id)
    let target = ""
    if (key === Qt.Key_Up && row === 0) {
      focusFilter()
      return true
    }
    if (key === Qt.Key_Up)
      target = grid[column][row - 1]
    else if (key === Qt.Key_Down)
      target = grid[column][row + 1] || ""
    else if (key === Qt.Key_Left || key === Qt.Key_Right) {
      const step = key === Qt.Key_Left ? -1 : 1
      for (let at = column + step; at >= 0 && at < grid.length && !target; at += step)
        if (grid[at].length > 0)
          target = grid[at][Math.min(row, grid[at].length - 1)]
    } else {
      return false
    }
    if (target && cards[target])
      cards[target].forceActiveFocus()
    return true
  }

  Keys.onEscapePressed: leave()
  Keys.onPressed: event => {
    if (event.text === "/")
      focusFilter()
    else if ([Qt.Key_Up, Qt.Key_Down, Qt.Key_Left, Qt.Key_Right].includes(event.key) && (stacked || cards[first]))
      focusEntry()
    else
      return
    event.accepted = true
  }

  // A state's rule over its column, with how many works are in it, and
  // what it means on hover.
  component StateHead: Item {
    id: head
    required property var column
    required property int count
    width: board.columnWidth
    height: Theme.size.rule
    Kicker {
      anchors.fill: parent
      text: head.column.key + "  " + head.count
      tone: head.count > 0 ? Omunculus.stateTone(head.column.key) : Theme.dim
    }
    HoverHandler { id: hover }
    Hint { active: hover.hovered; text: head.column.tip }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    FilterBox {
      id: filterBox
      Layout.fillWidth: true
      placeholderText: "Filter by title, project, conversation, workflow, stage or agent…  /"
      onApplied: value => board.filter = value
      onLeave: board.focusEntry()
    }

    // With several projects, one may be kept alone.
    ChipStrip {
      Layout.fillWidth: true
      visible: Omunculus.boardProjects.length > 1
      Chip {
        text: "ALL PROJECTS"
        checked: board.project === ""
        dim: board.project !== ""
        onClicked: board.project = ""
      }
      Repeater {
        model: Omunculus.boardProjects
        delegate: TagChip {
          required property var modelData
          tag: modelData.id
          text: "#" + modelData.id + "  " + (Omunculus.boardWorks[modelData.id] || []).length
          checked: board.project === modelData.id
          dim: board.project !== modelData.id
          onClicked: board.project = board.project === modelData.id ? "" : modelData.id
        }
      }
    }

    // Narrow: one list, under a rule of each state and lane.
    DataTable {
      id: list
      visible: board.stacked
      Layout.fillWidth: true
      Layout.fillHeight: true
      rows: board.stacked ? board.listed : []
      idOf: work => work.project + "/" + work.id
      section: "group"
      columns: [
        { title: "work", weight: 0.3 },
        { title: "about", weight: 0.3 },
        { title: "from", weight: 0.25 },
        { title: "changed", weight: 0.15 }
      ]
      cells: work => [work.title, [Omunculus.agentOf(work), board.lineageOf(work), board.metaOf(work)].filter(part => part !== "").join(Theme.type.meta.separator), board.originOf(work), board.runs(work) ? "RUNNING" : board.ageOf(work)]
      tone: (work, column) => column === 3 && !board.runs(work) ? Theme.dim : ""
      statusIcon: work => board.runs(work) ? "spark" : ""
      dimmed: work => work.state === "done" || work.state === "cancelled"
      stacked: [[0], [1], [2]]
      status: 3
      emptyText: board.emptyText
      onOpened: work => board.opened(work)
      onTopLeft: board.focusFilter()
      onBackRequested: board.leave()
    }

    // Wide: the columns' rules, each state with how many works are in it.
    Row {
      Layout.fillWidth: true
      visible: !board.stacked
      spacing: Theme.space.gap
      Repeater {
        model: board.stacked ? [] : board.columns
        delegate: StateHead {
          required property var modelData
          column: modelData
          count: board.shown.filter(work => board.stateOf(work) === modelData.key).length
        }
      }
    }

    ScrollPage {
      id: scroll
      visible: !board.stacked
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentHeight: lanesColumn.implicitHeight

      Column {
        id: lanesColumn
        width: scroll.width
        spacing: Theme.space.section

        Repeater {
          model: board.stacked ? [] : board.lanes
          delegate: Column {
            id: lane
            required property var modelData
            width: lanesColumn.width
            spacing: Theme.space.tight

            // A lane opens with a rule of its name, an agent's in its
            // colour, and how many works it holds.
            Kicker {
              visible: lane.modelData !== null
              width: parent.width
              height: Theme.size.rule
              text: (lane.modelData || "") + "  " + board.shown.filter(work => board.laneOf(work) === lane.modelData).length
              tone: board.group === "agent" ? Omunculus.toneOf(lane.modelData || "") : Theme.foreground
            }

            Row {
              spacing: Theme.space.gap
              Repeater {
                model: board.columns
                delegate: Column {
                  id: stateColumn
                  required property var modelData
                  readonly property var works: board.cell(lane.modelData, modelData.key)
                  width: board.columnWidth
                  // Never empty to the Row, which places only what has a size.
                  height: Math.max(1, implicitHeight)
                  spacing: Theme.space.tight
                  Repeater {
                    model: stateColumn.works
                    delegate: BoardCard {
                      id: card
                      required property var modelData
                      work: modelData
                      meta: board.metaOf(modelData)
                      lineage: board.lineageOf(modelData)
                      mark: board.markOf(modelData)
                      origin: board.originOf(modelData)
                      age: board.ageOf(modelData)
                      running: board.runs(modelData)
                      width: stateColumn.width
                      Keys.onPressed: event => event.accepted = board.move(work.id, event.key)
                      Keys.onEscapePressed: board.leave()
                      onActiveFocusChanged: if (activeFocus) board.current = work.id
                      onOpened: board.opened(work)
                      Component.onCompleted: board.cards[work.id] = card
                      Component.onDestruction: if (board.cards[work.id] === card) delete board.cards[work.id]
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Label {
    anchors.centerIn: parent
    visible: !board.stacked && board.shown.length === 0
    text: board.emptyText
    color: Theme.dim
    font.pixelSize: 11
    font.letterSpacing: 2
  }
}
