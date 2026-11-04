pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Projects.js" as Projects
import "kit/client/Time.js" as Time
import "kit/ui"

// ProjectsTable lists the projects of the registry in the DataTable: each
// one's id, the one the window is on marked OPEN, its conversations and
// open works, said as long as their room allows, its last activity and its
// state, toned while something waits for you, agents work in it or its
// socket does not answer. Its cells decode into view.
DataTable {
  id: table

  decode: true
  property alias projects: table.rows

  // The characters of a cell's font in `room` pixels.
  function budget(room) { return Math.floor(Math.max(0, room) / cellFont.advanceWidth("0")) }
  FontMetrics { id: cellFont; font.family: Theme.fontFamily; font.pixelSize: 10 }
  FontMetrics { id: stateFont; font.family: Theme.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }

  // Wide, the conversations fit their column, short of the cell's padding.
  // Stacked, they share the second line with the last activity, beside the
  // state; the activity goes before they would shorten past "15
  // conversations".
  function conversations(row, last) {
    if (!table.compact)
      return [Projects.conversationsText(row.conversations, row.openWorks, budget(table.columnWidth(1) - 12)), last]
    const line = budget(table.width - 34 - stateFont.advanceWidth(stateOf(row)))
    const rest = line - table.separator.length - last.length
    const keep = rest >= Projects.conversationsText(row.conversations, 0, Infinity).length
    return [Projects.conversationsText(row.conversations, row.openWorks, keep ? rest : line), keep ? last : ""]
  }

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
  cells: row => [row.id + (row.current ? "  ·  OPEN" : "")]
    .concat(conversations(row, row.last ? Time.began(row.last, Date.now()) : "—"), [stateOf(row)])
  tone: (row, column) => column === 3
    ? ({ waiting: Theme.warning, unreachable: Theme.warning, working: Theme.primary })[row.state] || Theme.dim
    : ""
  stacked: [[0], [1, 2]]
  status: 3
  emptyText: "no project in this server's registry"
}
