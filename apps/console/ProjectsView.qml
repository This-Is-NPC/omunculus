pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Projects.js" as Projects
import "kit/ui"

// ProjectsView filters the projects of the server's registry — those
// needing you, those agents work in, and their ids — and opens a
// selected row at its conversations. Its readout counts what it lists, for
// the bar. `/` goes to the search; ↓ or Enter back to the rows, ↑ on the
// first row back to the search; Esc on them leaves.
ColumnLayout {
  id: list
  spacing: Theme.space.block

  property bool active: false
  // "", or the state kept: "waiting" or "working".
  property string filter: ""
  property string search: ""
  // The id of the row picked, as a project just registered is.
  property string selected: ""
  signal opened(var place)
  signal leave()

  readonly property string readout: shown.length + (shown.length === 1 ? " PROJECT" : " PROJECTS")

  function focusEntry() { table.focusRows() }
  function focusFilter() { searchBox.forceActiveFocus() }

  function clearFilters() {
    filter = ""
    search = ""
    searchBox.clear()
  }

  readonly property int waiting: Projects.filter(Omunculus.projectRows, "", "waiting").length
  readonly property int working: Projects.filter(Omunculus.projectRows, "", "working").length
  readonly property var shown: Projects.filter(Omunculus.projectRows, search, filter)

  Keys.onPressed: event => {
    if (event.text !== "/")
      return
    focusFilter()
    event.accepted = true
  }
  Keys.onEscapePressed: leave()

  FilterBox {
    id: searchBox
    Layout.fillWidth: true
    placeholderText: "Search projects…  /"
    onApplied: value => list.search = value
    onLeave: table.focusRows()
  }

  ChipStrip {
    Layout.fillWidth: true
    visible: list.waiting > 0 || list.working > 0 || list.filter !== ""
    Chip {
      text: "ALL"
      checked: list.filter === ""
      dim: list.filter !== ""
      onClicked: list.filter = ""
    }
    Chip {
      visible: list.waiting > 0 || list.filter === "waiting"
      text: "NEEDS YOU  " + list.waiting
      icon: "warning"
      accent: Theme.warning
      alert: list.waiting > 0
      tip: "the projects where a conversation needs you"
      checked: list.filter === "waiting"
      dim: list.filter !== "waiting"
      onClicked: list.filter = "waiting"
    }
    Chip {
      visible: list.working > 0 || list.filter === "working"
      text: "WORKING  " + list.working
      icon: "play"
      tip: "the projects where agents work and nothing needs you"
      checked: list.filter === "working"
      dim: list.filter !== "working"
      onClicked: list.filter = "working"
    }
  }

  ProjectsTable {
    id: table
    Layout.fillWidth: true
    Layout.fillHeight: true
    projects: list.shown
    active: list.active
    selectedId: list.selected
    loading: !Omunculus.watching
    emptyText: !Omunculus.watching ? "reading the projects"
      : list.search ? "no project matches “" + list.search + "”"
      : list.filter !== "" ? "no project in this state" : "no project in this server's registry"
    emptyAction: Omunculus.watching && (list.search || list.filter !== "") ? "CLEAR FILTERS" : ""
    onEmptyActed: {
      list.clearFilters()
      table.focusRows()
    }
    onTopLeft: list.focusFilter()
    onOpened: row => list.opened({ id: row.id, socket: row.socket })
    onBackRequested: list.leave()
  }
}
