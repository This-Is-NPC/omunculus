pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// CostView is what the conversation open has used. A header strip sums it
// up — the model replies, the tokens read by the model (with those from
// cache) and written by it — with its cost at the right; then a row per
// agent, the busiest first, its name in its colour and the same figures in
// columns, or, under 700 px, on lines of their own, never cut; its cost at the
// top right, "-" for an agent none priced. When no provider reported a price
// there is no cost anywhere, only one kicker, NO PRICE REPORTED. Esc leaves.
FocusScope {
  id: view

  signal leave()

  readonly property var all: Omunculus.usage.all
  readonly property var agents: Object.keys(Omunculus.usage.agents).sort((a, b) => {
    const used = name => Omunculus.usage.agents[name].input + Omunculus.usage.agents[name].output
    return used(b) - used(a) || a.localeCompare(b)
  }).map(name => Object.assign({ name: name }, Omunculus.usage.agents[name]))
  readonly property bool unpriced: all.calls > 0 && all.priced === 0

  // A tally's replies, tokens read and tokens written.
  function replies(tally) { return tally.calls + (tally.calls === 1 ? " reply" : " replies") }
  function read(tally) { return Omunculus.tokens(tally.input) + " read" + (tally.cached > 0 ? " (" + Omunculus.tokens(tally.cached) + " from cache)" : "") }
  function written(tally) { return Omunculus.tokens(tally.output) + " written" }
  // The three as one line.
  function used(tally) { return [replies(tally), read(tally), written(tally)].join(Theme.type.meta.separator) }
  // A tally's cost, "-" when none of its replies was priced.
  function spent(tally) {
    if (tally.priced === 0)
      return "-"
    return Omunculus.money(tally.cost) + (tally.priced < tally.calls ? "  ·  " + tally.priced + " of " + tally.calls + " priced" : "")
  }

  Keys.onEscapePressed: leave()
  onActiveFocusChanged: if (activeFocus) table.focusRows()

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    // In all; its figures wrap rather than cut on a narrow window.
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: Math.max(Theme.size.strip, inAll.implicitHeight + Theme.space.gap * 2)
      color: "transparent"
      border.color: Theme.line

      RowLayout {
        anchors { fill: parent; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
        spacing: Theme.space.gap
        Label {
          id: inAll
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: ("in all" + Theme.type.meta.separator + view.used(view.all)).toUpperCase()
          color: Theme.dim
          font.pixelSize: Theme.type.meta.size
          font.letterSpacing: Theme.type.meta.tracking
          wrapMode: Text.Wrap
        }
        Label {
          visible: !view.unpriced
          text: view.spent(view.all)
          color: Theme.primary
          font.pixelSize: Theme.type.input.size
        }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: view.unpriced
      text: "NO PRICE REPORTED"
      color: Theme.dim
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: Theme.type.meta.tracking
      wrapMode: Text.Wrap
    }

    // By agent.
    DataTable {
      id: table
      Layout.fillWidth: true
      Layout.fillHeight: true
      active: view.activeFocus
      rows: view.agents
      idOf: entry => entry.name
      columns: view.unpriced
        ? [{ title: "Agent", weight: 0.25 }, { title: "Replies", weight: 0.15 }, { title: "Read", weight: 0.4 }, { title: "Written", weight: 0.2 }]
        : [{ title: "Agent", weight: 0.2 }, { title: "Replies", weight: 0.12 }, { title: "Read", weight: 0.33 }, { title: "Written", weight: 0.15 }, { title: "Cost", weight: 0.2 }]
      cells: entry => [entry.name, view.replies(entry), view.read(entry), view.written(entry)].concat(view.unpriced ? [] : [view.spent(entry)])
      tone: (entry, column) => column === 0 ? Omunculus.toneOf(entry.name) : column === 4 && entry.priced === 0 ? Theme.dim : ""
      stacked: [[0], [1, 2], [3]]
      status: view.unpriced ? -1 : 4
      emptyText: "Nothing used yet."
      onBackRequested: view.leave()
    }
  }
}
