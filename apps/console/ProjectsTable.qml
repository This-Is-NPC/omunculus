pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Projects.js" as Projects
import "kit/client/Time.js" as Time
import "kit/ui"

// ProjectsTable lists the projects of the registry in the DataTable under
// their state — NEEDS YOU, WORKING, IDLE, NOT REACHABLE, READING — each
// one's id, the one the window is on marked OPEN, its conversations and
// open works, said as long as their room allows, its last activity and its
// state, toned while something waits for you, agents work in it or its
// socket does not answer. Stacked, the id is over a line of the rest. Its
// cells decode into view.
DataTable {
  id: table

  decode: true
  property var projects: []

  // The groups, in the order listed, by a row's state.
  readonly property var groups: [
    { state: "waiting", title: "NEEDS YOU" },
    { state: "working", title: "WORKING" },
    { state: "idle", title: "IDLE" },
    { state: "unreachable", title: "NOT REACHABLE" },
    { state: "reading", title: "READING" }
  ]

  // The characters of a cell's font in `room` pixels.
  function budget(room) { return Math.floor(Math.max(0, room) / cellFont.advanceWidth("0")) }
  FontMetrics { id: cellFont; font.family: Theme.fontFamily; font.pixelSize: Theme.type.meta.size }
  FontMetrics { id: stateFont; font.family: Theme.fontFamily; font.pixelSize: Theme.type.header.size; font.letterSpacing: Theme.type.header.tracking }

  // Wide, the conversations fit their column, short of the cell's padding.
  // Stacked, they share the second line with the last activity, beside the
  // state; the activity goes before they would shorten past "15
  // conversations".
  function conversations(row, last) {
    if (!table.compact)
      return [Projects.conversationsText(row.conversations, row.openWorks, budget(table.columnWidth(1) - Theme.space.cell)), last]
    const line = budget(table.width - 2 * Theme.space.cell - Theme.space.gap - stateFont.advanceWidth(stateOf(row)))
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

  // The rows in the order given within each group, the groups in theirs.
  rows: [].concat(...groups.map(group => projects.filter(row => row.state === group.state)
    .map(row => Object.assign({ group: group.title }, row))))
  section: "group"
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
