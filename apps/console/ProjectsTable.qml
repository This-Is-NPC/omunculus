pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Time.js" as Time
import "kit/ui"

// ProjectsTable lists the projects of the registry in the DataTable: each
// one's id, the one the window is on marked OPEN, its conversations and
// open works, its last activity and its state, toned while something waits
// for you, agents work in it or its socket does not answer. Its cells
// decode into view.
DataTable {
  id: table

  decode: true
  property alias projects: table.rows

  function plural(count, word) { return count + " " + word + (count === 1 ? "" : "s") }

  function stateOf(row) {
    return ({
      waiting: "WAITING FOR YOU  " + row.waiting,
      working: "WORKING  " + row.working,
      unreachable: "NOT REACHABLE",
      reading: "READING…"
    })[row.state] || "IDLE"
  }

  columns: [
    { title: "project", weight: 0.3 },
    { title: "conversations", weight: 0.22 },
    { title: "last activity", weight: 0.22 },
    { title: "state", weight: 0.26 }
  ]
  cells: row => [
    row.id + (row.current ? "  ·  OPEN" : ""),
    plural(row.conversations, "conversation") + (row.openWorks > 0 ? "  ·  " + plural(row.openWorks, "open work") : ""),
    row.last ? Time.began(row.last, Date.now()) : "—",
    stateOf(row)
  ]
  tone: (row, column) => column === 3
    ? ({ waiting: Theme.warning, unreachable: Theme.warning, working: Theme.primary })[row.state] || Theme.dim
    : ""
  stacked: [[0], [1, 2]]
  status: 3
  emptyText: "no project in this server's registry"
}
