pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// HistoryView filters the project's conversations — those agents work in,
// those waiting for you, those not started, and what was first said in them —
// and opens a selected row. Conversations not started stay out of ALL. `/`
// goes to the search; ↓ or Enter back to the rows; Esc on them leaves.
ColumnLayout {
  id: history
  spacing: 14

  property bool active: false
  // "", or a state of the table: "WORKING", "WAITING FOR YOU" or "NOT STARTED".
  property string filter: ""
  property string search: ""
  signal opened(string id)
  signal leave()

  function focusEntry() { table.focusRows() }

  function known(conversation) { return Omunculus.summaries[conversation.id] || null }
  function count(state) { return Omunculus.conversations.filter(item => table.stateOf(item) === state).length }
  readonly property int working: count("WORKING")
  readonly property int waiting: count("WAITING FOR YOU")
  readonly property int fresh: count("NOT STARTED")
  readonly property var shown: Omunculus.conversations.filter(item => {
    const s = known(item)
    const state = table.stateOf(item)
    const words = history.search.toLowerCase().split(/\s+/).filter(word => word)
    return (history.filter === "" ? state !== "NOT STARTED" || words.length > 0 : state === history.filter)
      && words.every(word => s && s.title.toLowerCase().includes(word))
  })

  Keys.onPressed: event => {
    if (event.text !== "/")
      return
    searchBox.forceActiveFocus()
    event.accepted = true
  }
  Keys.onEscapePressed: leave()

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    FilterBox {
      id: searchBox
      Layout.fillWidth: true
      placeholderText: "search what was said first"
      onApplied: value => history.search = value
      onLeave: table.focusRows()
    }
    Label {
      text: history.shown.length + (history.shown.length === 1 ? " conversation" : " conversations")
      color: Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 1
    }
  }

  Flow {
    Layout.fillWidth: true
    visible: history.working > 0 || history.waiting > 0 || history.fresh > 0
    spacing: 6
    Chip {
      text: "ALL"
      checked: history.filter === ""
      dim: history.filter !== ""
      onClicked: history.filter = ""
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
      visible: history.waiting > 0
      text: "WAITING FOR YOU  " + history.waiting
      icon: "warning"
      accent: Theme.warning
      checked: history.filter === "WAITING FOR YOU"
      dim: history.filter !== "WAITING FOR YOU"
      onClicked: history.filter = "WAITING FOR YOU"
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
    emptyText: history.search ? "nothing first said matches “" + history.search + "”" : "no conversation yet"
    onOpened: conversation => history.opened(conversation.id)
    onBackRequested: history.leave()
  }
}
