pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// BoardView is the works of every project the window reaches, those of
// every conversation you may read there, on a board: a column per state —
// open, waiting on a child, a request or your next message, broken and
// waiting on its parent to decide, done, cancelled — the latest changed
// first, each card a work. By agent or by project, the columns are crossed
// by a lane of each; with several projects, chips keep one. On a narrow board
// the columns stack: each state's heading over its cards, full width. It follows each project's stream while
// it is on screen. A card opened opens its conversation's map with the work
// picked, on its project. `/` goes to the filter, which keeps the works
// whose title, project, conversation, workflow, stage or agent holds it;
// the arrows move between the cards, across the
// columns and down them; Esc on the filter empties it, then goes back to the
// cards, and on a card leaves.
Item {
  id: board

  // "", "agent" or "project": what lanes cross the columns.
  property string group: ""
  // The project whose works alone are shown, or "" for all of them.
  property string project: ""
  property string filter: ""
  // The time now, which the cards' ages follow.
  property real now: Date.now()
  Timer { interval: 30000; repeat: true; running: board.visible; onTriggered: board.now = Date.now() }
  signal opened(var work)
  signal leave()

  readonly property var states: [
    { key: "open", tip: "an agent has it" },
    { key: "waiting", tip: "on a child, a request or your next message" },
    { key: "broken", tip: "it broke; its parent decides" },
    { key: "done", tip: "" },
    { key: "cancelled", tip: "" }
  ]
  readonly property int gap: 12
  readonly property int narrowest: 200

  // A work that broke waits on its parent without waiting on anything named.
  function stateOf(work) { return work.state === "waiting" && !work.waiting ? "broken" : work.state }

  readonly property var shown: {
    const words = filter.toLowerCase().split(/\s+/).filter(word => word)
    return Omunculus.board
      .filter(work => {
        const text = [work.title, work.project, Omunculus.agentOf(work), Omunculus.conversationLabel(work.conversation_id), work.workflow || "", work.stage || ""].join(" ").toLowerCase()
        return (project === "" || work.project === project) && words.every(word => text.includes(word))
      })
      .sort((a, b) => (b.updated_at || b.created_at).localeCompare(a.updated_at || a.created_at))
  }
  // Whether the states stack, one under the other, rather than side by side.
  readonly property bool stacked: Breakpoints.size(width) === "narrow"
  // Every state where there is room for them all, else those with a work.
  readonly property var columns: {
    const used = states.filter(state => shown.some(work => stateOf(work) === state.key))
    return !stacked && width >= states.length * (narrowest + gap) || used.length === 0 ? states : used
  }
  readonly property real columnWidth: stacked ? width : Math.floor((width - (columns.length - 1) * gap) / columns.length)
  // The lane of a work: its agent's, or its project's.
  function laneOf(work) { return group === "agent" ? Omunculus.agentOf(work) : work.project }
  // The lanes: one for every work, or one per agent or project with a work
  // shown, in their names' order.
  readonly property var lanes: group === "" ? [null] : Array.from(new Set(shown.map(work => laneOf(work)))).sort()
  function cell(lane, state) {
    return shown.filter(work => stateOf(work) === state && (lane === null || laneOf(work) === lane))
  }
  // The work ids of each column, top to bottom across the lanes, as the
  // arrows go; stacked, one column in the order shown.
  readonly property var grid: stacked
    ? [[].concat(...lanes.map(lane => [].concat(...columns.map(column => cell(lane, column.key).map(work => work.id)))))]
    : columns.map(column => [].concat(...lanes.map(lane => cell(lane, column.key).map(work => work.id))))
  readonly property var first: grid.reduce((found, ids) => found || ids[0] || "", "")

  // Work id -> its card, and the one the keyboard was on last.
  property var cards: ({})
  property string current: ""

  function focusEntry() {
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
    else if ([Qt.Key_Up, Qt.Key_Down, Qt.Key_Left, Qt.Key_Right].includes(event.key) && cards[first])
      cards[first].forceActiveFocus()
    else
      return
    event.accepted = true
  }

  // A state's head: its name, what it means where there is room, and how
  // many works are in it.
  component StateHead: Rectangle {
    id: head
    required property var column
    required property int count
    width: board.columnWidth
    height: 34
    color: "transparent"
    border.color: Theme.line
    RowLayout {
      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
      spacing: 8
      Dot { tone: Omunculus.stateTone(head.column.key); size: 7; filled: head.count > 0 }
      DecodeLabel {
        value: head.column.key.toUpperCase()
        color: head.count > 0 ? Theme.foreground : Theme.dim
        font.pixelSize: 11
        font.letterSpacing: 3
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: head.column.tip
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
        visible: board.columnWidth > 260
      }
      Label { text: head.count; color: Theme.dim; font.pixelSize: 11 }
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      FilterBox {
        id: filterBox
        Layout.fillWidth: true
        placeholderText: "filter by title, project, conversation, workflow, stage or agent"
        onApplied: value => board.filter = value
        onLeave: board.focusEntry()
      }
      Label {
        text: board.shown.length + (board.filter.trim() ? " of " + Omunculus.board.length : "") + (Omunculus.board.length === 1 ? " work" : " works")
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 1
      }
    }

    // With several projects, one may be kept alone.
    Flow {
      Layout.fillWidth: true
      visible: Omunculus.boardProjects.length > 1
      spacing: 6
      Chip {
        text: "ALL PROJECTS"
        checked: board.project === ""
        dim: board.project !== ""
        onClicked: board.project = ""
      }
      Repeater {
        model: Omunculus.boardProjects
        delegate: Chip {
          required property var modelData
          text: modelData.id.toUpperCase() + "  " + (Omunculus.boardWorks[modelData.id] || []).length
          checked: board.project === modelData.id
          dim: board.project !== modelData.id
          onClicked: board.project = board.project === modelData.id ? "" : modelData.id
        }
      }
    }

    // The columns' heads: each state, with how many works are in it.
    Row {
      Layout.fillWidth: true
      visible: !board.stacked
      spacing: board.gap
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
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentHeight: lanesColumn.implicitHeight

      Column {
        id: lanesColumn
        width: scroll.width
        spacing: 16

        Repeater {
          model: board.lanes
          delegate: Column {
            id: lane
            required property var modelData
            required property int index
            width: lanesColumn.width
            spacing: 8

            // A lane opens with a hairline, its name — an agent's with its
            // portrait — and how many works it holds.
            Rectangle {
              visible: lane.modelData !== null
              width: parent.width
              height: 1
              color: Theme.line
              opacity: lane.index > 0 ? 1 : 0
            }
            RowLayout {
              visible: lane.modelData !== null
              width: parent.width
              spacing: 10
              readonly property var works: board.shown.filter(work => board.laneOf(work) === lane.modelData)
              Portrait {
                visible: board.group === "agent"
                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                agent: lane.modelData || ""
                source: Omunculus.imageOf(lane.modelData || "", parent.works.length > 0 ? parent.works[0].project : "")
                tone: Omunculus.toneOf(lane.modelData || "")
                framed: true
                initialSize: 12
              }
              Label {
                Layout.fillWidth: true
                text: board.group === "project" ? (lane.modelData || "").toUpperCase() : lane.modelData || ""
                color: board.group === "agent" ? Omunculus.toneOf(lane.modelData || "") : Theme.foreground
                font.pixelSize: 12
                font.letterSpacing: board.group === "project" ? 3 : 1.5
                elide: Text.ElideRight
              }
              Label {
                text: parent.works.length
                color: Theme.dim
                font.pixelSize: 11
              }
            }

            // Side by side, or stacked: each state's head over its cards.
            Grid {
              columns: board.stacked ? 1 : board.columns.length
              columnSpacing: board.gap
              rowSpacing: 12
              Repeater {
                model: board.columns
                delegate: Column {
                  id: stateColumn
                  required property var modelData
                  readonly property var works: board.cell(lane.modelData, modelData.key)
                  width: board.columnWidth
                  // Never empty to the Grid, which places only what has a size.
                  height: Math.max(1, implicitHeight)
                  visible: !board.stacked || works.length > 0
                  spacing: 8
                  StateHead {
                    visible: board.stacked
                    column: stateColumn.modelData
                    count: stateColumn.works.length
                  }
                  Repeater {
                    model: stateColumn.works
                    delegate: BoardCard {
                      id: card
                      required property var modelData
                      work: modelData
                      now: board.now
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
    visible: board.shown.length === 0
    text: Omunculus.board.length === 0 ? "no work yet" : "no work matches “" + board.filter + "”"
    color: Theme.dim
    font.pixelSize: 11
    font.letterSpacing: 2
  }
}
