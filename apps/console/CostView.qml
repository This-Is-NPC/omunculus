pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/client/Tree.js" as Tree
import "kit/client/Usage.js" as Usage

// CostView is what the conversation open has used and cost. At the top, BY
// WORK and BY AGENT, and its cost in dollars at the right; under them what it
// used in all — the model replies, the tokens read by the model (with those
// from cache) and written by it. BY WORK is the lineage tree of the works,
// each row with the models its calls used, the dollars it spent and those of
// everything below it, and its branch's share of all the dollars as a bar;
// the work picked has its calls listed under the tree, each with the model it
// used, its tokens and its dollars. BY AGENT is a row per agent, the busiest
// first, its name in its colour, its models and its tokens in columns, or,
// under 700 px, on lines of their own, never cut; its cost at the top right.
// The dollars are the server's (`GET /usage?conversation=`): each call's
// tokens at the price the model it used has in the project config. A call
// whose model has none has no dollars, and a line says "no price set for
// <model> in the project config" for each such model. Esc leaves.
FocusScope {
  id: view

  signal leave()

  // "work" or "agent".
  property string by: "work"

  readonly property var all: Omunculus.spend.total
  readonly property var agents: Object.keys(Omunculus.spend.agents).sort((a, b) => {
    const used = name => Omunculus.spend.agents[name].input + Omunculus.spend.agents[name].output
    return used(b) - used(a) || a.localeCompare(b)
  }).map(name => Object.assign({ name: name }, Omunculus.spend.agents[name]))
  readonly property var total: Omunculus.spend.total
  // Whether any call has a price, so there are dollars to show.
  readonly property bool priced: view.total.usd > 0 || view.agents.some(entry => entry.usd !== null)

  // The models an entry's calls used, "-" while there are none.
  function modelsOf(entry) { return entry.models.length > 0 ? entry.models.join(", ") : "-" }
  // The works, every one open, with their dollars and shares.
  readonly property var works: {
    const opened = {}
    for (const node of Omunculus.progress ? Omunculus.progress.flat : [])
      opened[node.work] = true
    return Usage.byWork(Tree.rows(Omunculus.progress, opened, null), Omunculus.spend)
  }

  // An entry's replies, tokens read and tokens written.
  function replies(tally) { return tally.replies + (tally.replies === 1 ? " reply" : " replies") }
  function read(tally) { return Omunculus.tokens(tally.input) + " read" + (tally.cached > 0 ? " (" + Omunculus.tokens(tally.cached) + " from cache)" : "") }
  function written(tally) { return Omunculus.tokens(tally.output) + " written" }
  // The three as one line.
  function used(tally) { return [replies(tally), read(tally), written(tally)].join(Theme.type.meta.separator) }
  // An entry's cost, "-" when none of its calls has a price.
  function spent(entry) { return entry.usd === null || entry.usd === undefined ? "-" : Usage.money(entry.usd) }
  // One call of a work: its model, with the provider's id when it differs, tokens and dollars.
  function callLine(call) {
    return [(call.model || "-") + (call.provider && call.provider !== call.model ? " (" + call.provider + ")" : ""), Omunculus.tokens(call.fresh + call.cache_write + call.cached) + " read", Omunculus.tokens(call.output) + " written", spent(call)].join(Theme.type.meta.separator)
  }

  Keys.onEscapePressed: leave()
  onActiveFocusChanged: if (activeFocus) { if (by === "work") workList.forceActiveFocus(); else table.focusRows() }

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      ChipStrip {
        Layout.fillWidth: true
        Chip { text: "BY WORK"; checked: view.by === "work"; tip: "the works, each with what its branch cost"; onClicked: view.by = "work" }
        Chip { text: "BY AGENT"; checked: view.by === "agent"; tip: "each agent, with its models and what it cost"; onClicked: view.by = "agent" }
      }
      Label {
        visible: view.priced
        text: "TOTAL  " + Usage.money(view.total.usd)
        color: Theme.primary
        font.pixelSize: Theme.type.input.size
      }
    }

    // In all; its figures wrap rather than cut on a narrow window.
    Label {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      text: ("in all" + Theme.type.meta.separator + view.used(view.all)).toUpperCase()
      color: Theme.dim
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: Theme.type.meta.tracking
      wrapMode: Text.Wrap
    }

    Repeater {
      model: Usage.unpriced(view.total)
      delegate: Label {
        required property string modelData
        Layout.fillWidth: true
        text: modelData
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
      }
    }

    // By work.
    ColumnLayout {
      visible: view.by === "work"
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Theme.space.tight

      // The column titles, over rows wide enough for columns.
      Item {
        id: titles
        visible: !workList.stacked
        Layout.fillWidth: true
        implicitHeight: Theme.size.rule
        readonly property real room: width - Theme.space.cell * 2
        Repeater {
          model: [["WORK", 0], ["MODEL", 0.26], ["OWN", 0.46], ["WITH THE WORKS BELOW", 0.66], ["SHARE OF COST", 0.86]]
          delegate: Label {
            required property var modelData
            x: Theme.space.cell + titles.room * modelData[1]
            anchors.verticalCenter: parent.verticalCenter
            text: modelData[0]
            color: Theme.dim
            font.pixelSize: Theme.type.header.size
            font.letterSpacing: Theme.type.header.tracking
          }
        }
      }

      ListView {
        id: workList
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: view.works
        keyNavigationEnabled: true
        activeFocusOnTab: true
        readonly property bool stacked: width < 1000
        readonly property real unit: Breakpoints.tight(width) ? Theme.size.mark : Theme.size.gutter
        Keys.onEscapePressed: view.leave()
        onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0

        delegate: Item {
          id: work
          required property var modelData
          required property int index
          readonly property var row: modelData.row
          readonly property real room: width - Theme.space.cell * 2
          readonly property real indent: (row.depth + 1) * workList.unit
          readonly property string share: Math.round(modelData.share * 100) + "%"
          readonly property color tone: Omunculus.toneOf(modelData.agent)

          width: workList.width
          height: (workList.stacked ? stack.implicitHeight : Theme.size.rule) + Theme.space.row

          Rectangle {
            anchors.fill: parent
            visible: ListView.isCurrentItem && workList.activeFocus
            color: Theme.highlight
          }
          Lifeline {
            depth: work.row.depth
            rails: work.row.rails
            line: work.row.depth > 0 ? "elbow" : "none"
            last: work.row.last
            stem: work.row.stem
            unit: workList.unit
            origin: Theme.space.cell
            markY: work.height / 2
            marked: true
            markTone: work.tone
          }

          // Wide: one line of columns.
          Item {
            visible: !workList.stacked
            anchors.fill: parent
            AgentName {
              x: Theme.space.cell + work.indent
              anchors.verticalCenter: parent.verticalCenter
              dot: false
              name: work.modelData.agent
              tone: work.tone
              limit: work.room * 0.26 - work.indent
            }
            Label {
              x: Theme.space.cell + work.room * 0.26
              width: work.room * 0.2 - Theme.space.gap
              anchors.verticalCenter: parent.verticalCenter
              text: view.modelsOf(work.modelData.own)
              color: Theme.dim
              font.pixelSize: Theme.type.meta.size
              elide: Text.ElideRight
            }
            Label {
              x: Theme.space.cell + work.room * 0.46
              width: work.room * 0.2 - Theme.space.gap
              anchors.verticalCenter: parent.verticalCenter
              text: view.spent(work.modelData.own)
              color: Theme.foreground
              font.pixelSize: Theme.type.meta.size
              elide: Text.ElideRight
            }
            Label {
              x: Theme.space.cell + work.room * 0.66
              width: work.room * 0.2 - Theme.space.gap
              anchors.verticalCenter: parent.verticalCenter
              text: view.spent(work.modelData.branch)
              color: Theme.foreground
              font.pixelSize: Theme.type.meta.size
              elide: Text.ElideRight
            }
            Rectangle {
              x: Theme.space.cell + work.room * 0.86
              width: work.room * 0.14 - Theme.space.cell * 3
              anchors.verticalCenter: parent.verticalCenter
              height: Theme.space.tight
              color: Theme.line
              Rectangle { width: parent.width * work.modelData.share; height: parent.height; color: Theme.primary }
            }
            Label {
              x: Theme.space.cell + work.room - Theme.space.cell * 2.5
              anchors.verticalCenter: parent.verticalCenter
              text: work.share
              color: Theme.dim
              font.pixelSize: Theme.type.meta.size
            }
          }

          // Narrow: the name and share, then lines of their own.
          ColumnLayout {
            id: stack
            visible: workList.stacked
            x: Theme.space.cell + work.indent
            y: Theme.space.tight
            width: work.width - x - Theme.space.cell
            spacing: Theme.space.row
            RowLayout {
              Layout.fillWidth: true
              spacing: Theme.space.gap
              AgentName {
                dot: false
                name: work.modelData.agent
                tone: work.tone
                limit: stack.width * 0.6
              }
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: view.modelsOf(work.modelData.own)
                color: Theme.dim
                font.pixelSize: Theme.type.meta.size
                elide: Text.ElideRight
              }
              Label {
                text: work.share
                color: Theme.dim
                font.pixelSize: Theme.type.meta.size
              }
            }
            Label {
              Layout.fillWidth: true
              text: "own" + Theme.type.meta.separator + view.spent(work.modelData.own)
              color: Theme.foreground
              font.pixelSize: Theme.type.meta.size
              wrapMode: Text.Wrap
            }
            Label {
              Layout.fillWidth: true
              text: "with the works below" + Theme.type.meta.separator + view.spent(work.modelData.branch)
              color: Theme.foreground
              font.pixelSize: Theme.type.meta.size
              wrapMode: Text.Wrap
            }
            Rectangle {
              Layout.fillWidth: true
              height: Theme.space.tight
              color: Theme.line
              Rectangle { width: parent.width * work.modelData.share; height: parent.height; color: Theme.primary }
            }
          }
        }

        Label {
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.space.page }
          visible: workList.count === 0
          horizontalAlignment: Text.AlignHCenter
          text: "Nothing used yet."
          color: Theme.dim
          font.pixelSize: Theme.type.tab.size
        }
      }

      // The calls of the work picked, each with the model it used.
      ListView {
        id: callList
        readonly property var picked: workList.currentIndex >= 0 && workList.currentIndex < view.works.length ? view.works[workList.currentIndex] : null
        visible: count > 0
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(contentHeight, Theme.size.rule * 6)
        clip: true
        model: picked ? picked.calls : []
        delegate: Label {
          required property var modelData
          width: callList.width
          text: view.callLine(modelData)
          color: Theme.dim
          font.pixelSize: Theme.type.meta.size
          elide: Text.ElideRight
        }
      }
    }

    // By agent.
    DataTable {
      id: table
      visible: view.by === "agent"
      Layout.fillWidth: true
      Layout.fillHeight: true
      active: view.activeFocus
      rows: view.agents
      idOf: entry => entry.name
      columns: [{ title: "Agent", weight: 0.16 }, { title: "Model", weight: 0.2 }, { title: "Replies", weight: 0.1 }, { title: "Read", weight: 0.26 }, { title: "Written", weight: 0.12 }, { title: "Cost", weight: 0.16 }]
      cells: entry => [entry.name, view.modelsOf(entry), view.replies(entry), view.read(entry), view.written(entry), view.spent(entry)]
      tone: (entry, column) => column === 0 ? Omunculus.toneOf(entry.name) : column === 1 ? Theme.dim : column === 5 && view.spent(entry) === "-" ? Theme.dim : ""
      stacked: [[0], [1], [2, 3], [4]]
      status: 5
      emptyText: "Nothing used yet."
      onBackRequested: view.leave()
    }
  }
}
