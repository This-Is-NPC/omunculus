pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Projects.js" as Projects
import "kit/client/Time.js" as Time
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// ConversationsTable lists conversations in the DataTable, those needing you
// first under NEEDS YOU, the one waiting longest first, then the others under
// the day each began, newest first as given. Each row, at every width: its
// title — its first work's, else what was first said in it — with its state
// at the top right, toned only while something waits for you or agents work
// in it, saying what waits: questions, a decision, a permission; under it,
// dim, whom it is with, "with sales › seller · qualify 1/6" when another
// agent holds its first work, at which stage of how many, and since when it
// waits, else when it began; then what the newest request asks, or, under a work's title, what
// was first said. Each row's menu opens it at its team or its log. Its cells
// decode into view.
DataTable {
  id: table

  decode: true
  compact: true
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

  // "not-started", "needs-you", "working", "done", "idle", or "" unread.
  function stateOf(conversation) { return Projects.state(summary(conversation)) }

  function stateText(conversation) {
    const state = stateOf(conversation)
    return state === "needs-you" ? Projects.waitsFor(summary(conversation).asks)
      : ({ "not-started": "NOT STARTED", working: "WORKING", done: "DONE", idle: "IDLE" })[state] || ""
  }

  // Whom it is with, the agent its first work is with when another, and the
  // stage of the workflow while the work goes on: "with sales › seller ·
  // design 2/6".
  function whoOf(conversation, root) {
    const known = summary(conversation)
    const partner = known ? known.agent : ""
    const holder = root ? Omunculus.agentOf(root) : ""
    const lane = root && root.state !== "done" && root.state !== "cancelled" ? Omunculus.laneOf(root) : null
    const at = lane ? lane.steps[lane.at].name + " " + (lane.at + 1) + "/" + lane.steps.length : ""
    const names = holder === "" || holder === partner ? partner : partner + " › " + holder
    return [names !== "" ? "with " + names : "", at].filter(text => text !== "").join(table.separator)
  }

  // Needing you first, the longest waiting first, under NEEDS YOU; the others
  // under their day, in the order given.
  rows: {
    const now = Date.now()
    const needing = conversations.filter(conversation => stateOf(conversation) === "needs-you")
      .sort((a, b) => summary(a).since.localeCompare(summary(b).since))
      .map(conversation => Object.assign({ group: "NEEDS YOU" }, conversation))
    const others = conversations.filter(conversation => stateOf(conversation) !== "needs-you")
      .map(conversation => Object.assign({ group: Time.day(conversation.created_at, now) }, conversation))
    return needing.concat(others)
  }
  section: "group"
  cells: conversation => {
    const now = Date.now()
    const known = summary(conversation)
    const works = worksOf(conversation)
    const root = rootOf(works)
    const needing = stateOf(conversation) === "needs-you"
    const said = needing ? known.question : root && root.title && known && known.title !== root.title ? known.title : ""
    return [
      titleOf(conversation),
      [
        whoOf(conversation, root),
        needing ? "waiting since " + Time.clock(known.since, now) : "began " + Time.began(conversation.created_at, now)
      ].filter(text => text !== "").join(table.separator),
      stateText(conversation),
      said ? "“" + said + "”" : ""
    ]
  }
  tone: (conversation, column) => column === 2
    ? ({ "needs-you": Theme.warning, working: Theme.primary })[stateOf(conversation)] || Theme.dim
    : ""
  dotted: conversation => stateOf(conversation) === "working"
  stacked: [[0], [1], [3]]
  status: 2
  emptyText: "no conversation yet"
  // Every row's menu reads alike, in reach of the pointer and of Tab.
  toolsLive: true
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
