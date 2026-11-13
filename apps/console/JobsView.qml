pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Jobs.js" as Jobs
import "kit/client/Requests.js" as Requests
import "kit/ui"

// JobsView lists the project's scheduled jobs and opens a selected row at its
// page. Its filters are the job's states, ALL being every job but the
// archived; the search reads a job's name, its schedule in words, its target,
// its owner and its origin. Its readout, for the bar, counts what it lists.
// `/` goes to the search; ↓ or Enter back to the rows, ↑ on the first row back
// to the search; Esc on them leaves. The list is read again every few seconds
// while the page is on screen.
ColumnLayout {
  id: list
  spacing: Theme.space.block

  property bool active: false
  // "" for ALL, or a state of a job.
  property string filter: ""
  property string search: ""
  signal opened(var job)
  signal newWanted()
  signal leave()

  readonly property var items: Omunculus.jobs.items
  readonly property var shown: Jobs.inState(items, filter).filter(job => {
    const said = [job.name, Jobs.when(job.schedule), Jobs.target(job), job.owner ? Requests.label(job.owner) : "", Jobs.origin(job)].join(" ").toLowerCase()
    return list.search.toLowerCase().split(/\s+/).filter(word => word).every(word => said.includes(word))
  })
  readonly property string readout: (shown.length === items.length ? "" : shown.length + " OF ") + items.length + (items.length === 1 ? " JOB" : " JOBS")

  function focusEntry() { table.focusRows() }

  function count(state) { return Jobs.inState(items, state).length }

  function clearFilters() {
    filter = ""
    search = ""
    searchBox.clear()
  }

  onActiveChanged: if (active && Omunculus.connected) Omunculus.jobs.load()
  Timer {
    interval: 10000
    repeat: true
    running: list.active && Omunculus.connected
    onTriggered: Omunculus.jobs.load()
  }

  Keys.onPressed: event => {
    if (event.text !== "/")
      return
    searchBox.forceActiveFocus()
    event.accepted = true
  }
  Keys.onEscapePressed: leave()

  FilterBox {
    id: searchBox
    Layout.fillWidth: true
    placeholderText: "Search jobs…  /"
    onApplied: value => list.search = value
    onLeave: table.focusRows()
  }

  ChipStrip {
    Layout.fillWidth: true
    visible: list.items.length > 0
    Chip {
      text: "ALL"
      checked: list.filter === ""
      onClicked: list.filter = ""
    }
    Chip {
      visible: list.count("active") > 0 || list.filter === "active"
      text: "ACTIVE  " + list.count("active")
      icon: "clock"
      tip: "the jobs that fire on their schedule"
      checked: list.filter === "active"
      onClicked: list.filter = "active"
    }
    Chip {
      visible: list.count("paused") > 0 || list.filter === "paused"
      text: "PAUSED  " + list.count("paused")
      icon: "warning"
      accent: Theme.warning
      alert: list.count("paused") > 0
      tip: "the jobs that do not fire until resumed"
      checked: list.filter === "paused"
      onClicked: list.filter = "paused"
    }
    Chip {
      visible: list.count("proposed") > 0 || list.filter === "proposed"
      text: "PROPOSED  " + list.count("proposed")
      checked: list.filter === "proposed"
      onClicked: list.filter = "proposed"
    }
    Chip {
      visible: list.count("ended") > 0 || list.filter === "ended"
      text: "ENDED  " + list.count("ended")
      checked: list.filter === "ended"
      onClicked: list.filter = "ended"
    }
    Chip {
      visible: list.count("archived") > 0 || list.filter === "archived"
      text: "ARCHIVED  " + list.count("archived")
      checked: list.filter === "archived"
      onClicked: list.filter = "archived"
    }
  }

  JobsTable {
    id: table
    Layout.fillWidth: true
    Layout.fillHeight: true
    jobs: list.shown
    active: list.active
    loading: !Omunculus.jobs.loaded
    emptyText: !Omunculus.jobs.loaded ? "reading the jobs"
      : list.search ? "no job matches “" + list.search + "”"
      : list.filter !== "" ? "no job in this state" : "no job yet: a job sends a message on a schedule"
    emptyIcon: list.search || list.filter !== "" ? "close" : "plus"
    emptyAction: Omunculus.jobs.loaded ? (list.search || list.filter !== "" ? "CLEAR FILTERS" : "NEW JOB") : ""
    onEmptyActed: {
      if (list.search || list.filter !== "") {
        list.clearFilters()
        table.focusRows()
      } else {
        list.newWanted()
      }
    }
    onTopLeft: searchBox.forceActiveFocus()
    onOpened: job => list.opened(job)
    onBackRequested: list.leave()
  }
}
