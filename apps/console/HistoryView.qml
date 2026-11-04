pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// HistoryView filters the project's conversations — those agents work in,
// those waiting for you, those not started, and their titles and what was
// first said in them — and opens a selected row, at its chat or, from its
// menu, its team or its log. Conversations not started stay out of ALL. Its
// readout counts what it lists, for the bar. `/` goes to the search; ↓ or
// Enter back to the rows, ↑ on the first row back to the search; Esc on
// them leaves.
ColumnLayout {
  id: history
  spacing: Theme.space.block

  property bool active: false
  // "", or a state of the table: "WORKING", "WAITING FOR YOU" or "NOT STARTED".
  property string filter: ""
  property string search: ""
  // The page it opens at: "" for the chat, "map" or "log".
  signal opened(string id, string page)
  signal leave()

  readonly property string readout: shown.length + (shown.length === 1 ? " CONVERSATION" : " CONVERSATIONS")

  function focusEntry() { table.focusRows() }

  function clearFilters() {
    filter = ""
    search = ""
    searchBox.clear()
  }

  function count(state) { return Omunculus.conversations.filter(item => table.stateOf(item) === state).length }
  readonly property int working: count("WORKING")
  readonly property int waiting: count("WAITING FOR YOU")
  readonly property int fresh: count("NOT STARTED")
  readonly property var shown: Omunculus.conversations.filter(item => {
    const known = Omunculus.summaries[item.id]
    const said = [table.titleOf(item), known ? known.title : ""].join(" ").toLowerCase()
    const state = table.stateOf(item)
    const words = history.search.toLowerCase().split(/\s+/).filter(word => word)
    return (history.filter === "" ? state !== "NOT STARTED" || words.length > 0 : state === history.filter)
      && words.every(word => said.includes(word))
  })

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
    placeholderText: "Search titles and what was said first…  /"
    onApplied: value => history.search = value
    onLeave: table.focusRows()
  }

  // One line however many filters, so the rows stay in reach in a small window.
  ChipStrip {
    Layout.fillWidth: true
    visible: history.working > 0 || history.waiting > 0 || history.fresh > 0
    Chip {
      text: "ALL"
      checked: history.filter === ""
      dim: history.filter !== ""
      onClicked: history.filter = ""
    }
    Chip {
      visible: history.waiting > 0
      text: "WAITING FOR YOU  " + history.waiting
      icon: "warning"
      accent: Theme.warning
      checked: history.filter === "WAITING FOR YOU"
      dim: history.filter !== "WAITING FOR YOU"
      onClicked: history.filter = "WAITING FOR YOU"
    }
    Chip {
      visible: history.working > 0
      text: "WORKING  " + history.working
      icon: "play"
      checked: history.filter === "WORKING"
      dim: history.filter !== "WORKING"
      onClicked: history.filter = "WORKING"
    }
    Chip {
      visible: history.fresh > 0
      text: "NOT STARTED  " + history.fresh
      checked: history.filter === "NOT STARTED"
      dim: history.filter !== "NOT STARTED"
      onClicked: history.filter = "NOT STARTED"
    }
  }

  ConversationsTable {
    id: table
    Layout.fillWidth: true
    Layout.fillHeight: true
    conversations: history.shown
    active: history.active
    emptyText: history.search ? "nothing said matches “" + history.search + "”"
      : history.filter !== "" ? "no conversation in this state" : "no conversation yet"
    emptyAction: history.search || history.filter !== "" ? "CLEAR FILTERS" : ""
    onEmptyActed: {
      history.clearFilters()
      table.focusRows()
    }
    onTopLeft: searchBox.forceActiveFocus()
    onOpened: conversation => history.opened(conversation.id, "")
    onOpenedAt: (conversation, page) => history.opened(conversation.id, page)
    onBackRequested: history.leave()
  }
}
