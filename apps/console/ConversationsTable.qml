pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// ConversationsTable lists conversations in the DataTable: what was first
// said in each, when it began, and its state — toned only while agents work
// in it or something waits on you.
DataTable {
  id: table

  property alias conversations: table.rows

  function summary(conversation) {
    return Omunculus.summaries[conversation.id] || null
  }

  function state(conversation) {
    const known = summary(conversation)
    if (known === null)
      return ""
    return known.waiting > 0 ? "WAITING ON YOU" : known.running > 0 ? "WORKING" : "IDLE"
  }

  columns: [
    { title: "first message", weight: 0.56 },
    { title: "began", weight: 0.24 },
    { title: "state", weight: 0.2 }
  ]
  cells: conversation => {
    const known = summary(conversation)
    return [
      known && known.title ? known.title : "new conversation",
      Qt.formatDateTime(new Date(conversation.created_at), "dd MMM yyyy  hh:mm"),
      state(conversation)
    ]
  }
  tone: (conversation, column) => column === 2
    ? ({ "WAITING ON YOU": Theme.warning, WORKING: Theme.primary })[state(conversation)] || Theme.dim
    : ""
  stacked: [[0], [1]]
  status: 2
  emptyText: "no conversation yet"
}
