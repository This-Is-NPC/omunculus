pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Time.js" as Time
import "kit/ui"

// ConversationsTable lists conversations in the DataTable: what was first
// said in each, when it began, and its state — toned only while agents work
// in it or something waits for you. Its cells decode into view.
DataTable {
  id: table

  decode: true
  property alias conversations: table.rows

  function summary(conversation) {
    return Omunculus.summaries[conversation.id] || null
  }

  function state(conversation) {
    const known = summary(conversation)
    if (known === null)
      return ""
    return !known.started ? "NOT STARTED" : known.waiting > 0 ? "WAITING FOR YOU" : known.running > 0 ? "WORKING" : known.finished ? "DONE" : "IDLE"
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
      Time.began(conversation.created_at, Date.now()),
      state(conversation)
    ]
  }
  tone: (conversation, column) => column === 2
    ? ({ "WAITING FOR YOU": Theme.warning, WORKING: Theme.primary })[state(conversation)] || Theme.dim
    : ""
  stacked: [[0], [1]]
  status: 2
  emptyText: "no conversation yet"
}
