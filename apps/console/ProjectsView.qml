pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Projects.js" as Projects
import "kit/ui"

// ProjectsView filters the projects of the server's registry — those
// waiting for you, those agents work in, and their ids — and opens a
// selected row at its conversations. `/` goes to the search; ↓ or Enter
// back to the rows; Esc on them leaves.
ColumnLayout {
  id: list
  spacing: 14

  property bool active: false
  // "", or the state kept: "waiting" or "working".
  property string filter: ""
  property string search: ""
  // The id of the row picked, as a project just registered is.
  property string selected: ""
  signal opened(var place)
  signal leave()

  function focusEntry() { table.focusRows() }
  function focusFilter() { searchBox.forceActiveFocus() }

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

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    FilterBox {
      id: searchBox
      Layout.fillWidth: true
      placeholderText: "search projects"
      onApplied: value => list.search = value
      onLeave: table.focusRows()
    }
    Label {
      Layout.maximumWidth: Math.max(48, list.width / 4)
      text: list.shown.length + (list.shown.length === 1 ? " project" : " projects")
      color: Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
  }

  Flow {
    Layout.fillWidth: true
    visible: list.waiting > 0 || list.working > 0 || list.filter !== ""
    spacing: 6
    Chip {
      text: "ALL"
      checked: list.filter === ""
      dim: list.filter !== ""
      onClicked: list.filter = ""
    }
    Chip {
      visible: list.waiting > 0 || list.filter === "waiting"
      text: "WAITING FOR YOU  " + list.waiting
      icon: "warning"
      accent: Theme.warning
      checked: list.filter === "waiting"
      dim: list.filter !== "waiting"
      onClicked: list.filter = "waiting"
    }
    Chip {
      visible: list.working > 0 || list.filter === "working"
      text: "WORKING  " + list.working
      icon: "play"
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
      : list.search ? "no project matches “" + list.search + "”" : "no project in this server's registry"
    onOpened: row => list.opened({ id: row.id, socket: row.socket })
    onBackRequested: list.leave()
  }
}
