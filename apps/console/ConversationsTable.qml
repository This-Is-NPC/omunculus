pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Time.js" as Time
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// ConversationsTable lists conversations in the DataTable under the day each
// began: its title — its first work's, else what was first said in it — the
// agent that work is with, when it began, how many works it holds, the stage
// its first work is at, and its state, toned only while agents work in it or
// something waits for you. Stacked, the title is over a line of the rest.
// Each row's menu opens it at its team or its log. Its cells decode into view.
DataTable {
  id: table

  decode: true
  property var conversations: []
  // A row's menu chose where to open it: "map" or "log".
  signal openedAt(var conversation, string page)

  function summary(conversation) {
    return Omunculus.summaries[conversation.id] || null
  }

  // The works of a conversation of the project on screen, and the first of
  // them, the one its agent opened.
  function worksOf(conversation) {
    return (Omunculus.boardWorks[Omunculus.project] || []).filter(work => work.conversation_id === conversation.id)
  }
  function rootOf(works) { return works.find(work => !work.parent_id) || null }

  function titleOf(conversation) {
    const root = rootOf(worksOf(conversation))
    const known = summary(conversation)
    return root && root.title ? root.title : known && known.title ? known.title : "new conversation"
  }

  function stateOf(conversation) {
    const known = summary(conversation)
    if (known === null)
      return ""
    return !known.started ? "NOT STARTED" : known.waiting > 0 ? "WAITING FOR YOU" : known.running > 0 ? "WORKING" : known.finished ? "DONE" : "IDLE"
  }

  // Each conversation with the day it is listed under, newest first as given.
  rows: conversations.map(conversation => Object.assign({ day: Time.day(conversation.created_at, Date.now()) }, conversation))
  section: "day"
  columns: [
    { title: "title", weight: 0.34 },
    { title: "with", weight: 0.12 },
    { title: "began", weight: 0.14 },
    { title: "works", weight: 0.09 },
    { title: "stage", weight: 0.13 },
    { title: "state", weight: 0.18 }
  ]
  cells: conversation => {
    const works = worksOf(conversation)
    const root = rootOf(works)
    return [
      titleOf(conversation),
      root ? Omunculus.agentOf(root) : "",
      Time.began(conversation.created_at, Date.now()),
      works.length > 0 ? works.length + (works.length === 1 ? " work" : " works") : "",
      root && root.stage ? "stage " + root.stage : "",
      stateOf(conversation)
    ]
  }
  tone: (conversation, column) => column === 5
    ? ({ "WAITING FOR YOU": Theme.warning, WORKING: Theme.primary })[stateOf(conversation)] || Theme.dim
    : ""
  dotted: conversation => stateOf(conversation) === "WORKING"
  stacked: [[0], [1, 2, 3, 4]]
  status: 5
  emptyText: "no conversation yet"
  toolsWidth: Breakpoints.target(Window.width)
  tools: rowMenu

  Component {
    id: rowMenu
    ActionMenu {
      property var entry
      tip: "open it elsewhere"
      items: [
        { id: "map", icon: "people", text: "OPEN IN TEAM" },
        { id: "log", icon: "list", text: "SHOW LOG" }
      ]
      onChosen: id => table.openedAt(entry, id)
    }
  }
}
