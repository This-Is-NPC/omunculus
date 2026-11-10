pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Projects.js" as Projects
import "kit/client/Time.js" as Time
import "kit/ui"

// ProjectsTable lists the projects of the registry in the DataTable under
// their state — NEEDS YOU, WORKING, FAILED, IDLE, NOT REACHABLE, READING — each as
// two lines at every width: its id, the one the window is on marked OPEN,
// with its state at the top right, toned while something waits for you,
// agents work in it, a run failed in it or its socket does not answer; under
// it, dim, its conversations, how many need you, work in it and failed, its works
// not finished and its last activity, as many as its room allows. Its cells
// decode into view.
DataTable {
  id: table

  decode: true
  compact: true
  property var projects: []

  // The groups, in the order listed, by a row's state.
  readonly property var groups: [
    { state: "waiting", title: "NEEDS YOU" },
    { state: "working", title: "WORKING" },
    { state: "failed", title: "FAILED" },
    { state: "idle", title: "IDLE" },
    { state: "unreachable", title: "NOT REACHABLE" },
    { state: "reading", title: "READING" }
  ]

  function stateOf(row) {
    return ({ waiting: "NEEDS YOU", working: "WORKING", failed: "✕ FAILED", unreachable: "NOT REACHABLE", reading: "READING…" })[row.state] || "IDLE"
  }

  // The characters of the second line in its room, beside the state.
  FontMetrics { id: metaFont; font.family: Theme.fontFamily; font.pixelSize: Theme.type.meta.size }
  FontMetrics { id: stateFont; font.family: Theme.fontFamily; font.pixelSize: Theme.type.header.size; font.letterSpacing: Theme.type.header.tracking }
  function budget(row) {
    const room = table.width - 2 * Theme.space.cell - Theme.space.gap - stateFont.advanceWidth(stateOf(row))
    return Math.floor(Math.max(0, room) / metaFont.advanceWidth("0"))
  }

  // The rows in the order given within each group, the groups in theirs.
  rows: [].concat(...groups.map(group => projects.filter(row => row.state === group.state)
    .map(row => Object.assign({ group: group.title }, row))))
  section: "group"
  cells: row => [
    row.id + (row.current ? table.separator + "OPEN" : ""),
    Projects.meta(row, row.last ? Time.began(row.last, Date.now()) : "", budget(row), table.separator),
    stateOf(row)
  ]
  tone: (row, column) => column === 2
    ? ({ waiting: Theme.warning, unreachable: Theme.warning, working: Theme.primary, failed: Theme.error })[row.state] || Theme.dim
    : ""
  dotted: row => row.state === "working"
  stacked: [[0], [1]]
  status: 2
  emptyText: "no project in this server's registry"
}
