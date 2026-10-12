pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// HistoryView filters the project's conversations — those agents work in,
// those waiting on you, and what was first said in them — and opens a selected
// row. `/` goes to the search; ↓ or Enter back to the rows.
ColumnLayout {
  id: history
  spacing: 14

  property bool active: false
  // "", "working" or "waiting".
  property string filter: ""
  property string search: ""

  function known(conversation) { return Omunculus.summaries[conversation.id] || null }
  readonly property int working: Omunculus.conversations.filter(item => { const s = known(item); return s && s.running > 0 }).length
  readonly property int waiting: Omunculus.conversations.filter(item => { const s = known(item); return s && s.waiting > 0 }).length
  readonly property var shown: Omunculus.conversations.filter(item => {
    const s = known(item)
    const words = history.search.toLowerCase().split(/\s+/).filter(word => word)
    return (history.filter === "" || (s && (history.filter === "working" ? s.running > 0 : s.waiting > 0)))
      && words.every(word => s && s.title.toLowerCase().includes(word))
  })

  Keys.onPressed: event => {
    if (event.key === Qt.Key_N)
      newButton.press()
    else if (event.text === "/")
      searchBox.forceActiveFocus()
    else
      return
    event.accepted = true
  }
  Keys.onEscapePressed: backButton.press()

  RowLayout {
    Layout.fillWidth: true
    // The buttons wrap rather than run past a narrow window.
    Flow {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      spacing: 6
      TraceButton { id: backButton; dense: true; role: "navigation"; icon: "chevron-left"; text: "BACK"; tip: "esc"; onClicked: Omunculus.view = "start" }
      TraceButton { id: newButton; dense: true; role: "navigation"; icon: "plus"; text: "NEW CONVERSATION"; tip: "n"; onClicked: Omunculus.createConversation() }
    }
    Label {
      Layout.alignment: Qt.AlignTop | Qt.AlignRight
      Layout.topMargin: 8
      text: history.shown.length + (history.shown.length === 1 ? " CONVERSATION" : " CONVERSATIONS")
      color: Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 3
    }
  }

  TextBox {
    id: searchBox
    Layout.fillWidth: true
    dense: true
    placeholderText: "search what was said first"
    onTextEdited: typing.restart()
    // The filter follows once typing pauses.
    Timer { id: typing; interval: 250; onTriggered: history.search = searchBox.text }
    Keys.onEscapePressed: {
      if (searchBox.text) {
        searchBox.clear()
        history.search = ""
      } else {
        table.focusRows()
      }
    }
    Keys.onDownPressed: table.focusRows()
    Keys.onReturnPressed: {
      typing.stop()
      history.search = searchBox.text
      table.focusRows()
    }
  }

  Flow {
    Layout.fillWidth: true
    visible: history.working > 0 || history.waiting > 0
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
      checked: history.filter === "working"
      dim: history.filter !== "working"
      onClicked: history.filter = "working"
    }
    Chip {
      visible: history.waiting > 0
      text: "WAITING ON YOU  " + history.waiting
      icon: "warning"
      accent: Theme.warning
      checked: history.filter === "waiting"
      dim: history.filter !== "waiting"
      onClicked: history.filter = "waiting"
    }
  }

  ConversationsTable {
    id: table
    Layout.fillWidth: true
    Layout.fillHeight: true
    conversations: history.shown
    active: history.active
    emptyText: history.search ? "nothing first said matches “" + history.search + "”" : "no conversation yet"
    onOpened: conversation => Omunculus.open(conversation.id)
    onBackRequested: backButton.press()
  }
}
