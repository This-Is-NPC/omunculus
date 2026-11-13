.pragma library

// Every key the window answers to, in tiers.
//   0  no key of its own: anything that creates, sends, answers, grants,
//      denies, escalates, reverts, deletes or cancels is pressed or clicked.
//   1  a bare key, only for navigation without effect; it acts only while a
//      navigation item has the keyboard and no text field saw a key for a
//      second, so text that lost its field is never taken for commands.
//   2  a Ctrl or Alt chord, which a field being written leaves to it.
// `where` names the groups of the keys dialog the entry is listed in.
const table = [
  { id: "page", keys: ["1", "2", "3", "4"], tier: 1, mutates: false, label: "1 · 2 · …", where: ["everywhere"],
    what: "the page of that number: the projects and the board, a project's conversations, the board and the jobs, or, in a conversation, its chat, tree, log, cost and artifacts" },
  { id: "page-chord", keys: ["Ctrl+1", "Ctrl+2", "Ctrl+3", "Ctrl+4"], tier: 2, mutates: false, label: "Ctrl+1 · Ctrl+2 · …", where: ["everywhere"],
    what: "the same, from a field being written" },
  { id: "next-page", keys: ["Ctrl+Tab"], tier: 2, mutates: false, where: ["everywhere"], what: "the next page" },
  { id: "previous-page", keys: ["Ctrl+Shift+Tab", "Ctrl+Backtab"], tier: 2, mutates: false, label: "Ctrl+Shift+Tab", where: ["everywhere"], what: "the previous page" },
  { id: "back", keys: ["Esc"], tier: 1, mutates: false, where: ["everywhere"],
    what: "let go of what the page holds, then back to where you were, at last the start" },
  { id: "filter", keys: ["/"], tier: 1, mutates: false, where: ["projects", "conversations", "board", "jobs", "log"], what: "search or filter" },
  { id: "help", keys: ["?", "F1"], tier: 1, mutates: false, where: ["everywhere"], what: "these keys" },
  { id: "start-way", keys: ["1", "2", "3", "4", "5"], tier: 1, mutates: false, where: ["start"], what: "the way in of that number, as the cards show it", label: "1 · 2 · …" },
  { id: "projects", keys: ["Ctrl+P"], tier: 2, mutates: false, where: ["everywhere"], what: "the projects, also from a field being written" },
  { id: "new-conversation", keys: ["Ctrl+N"], tier: 2, mutates: false, where: ["conversations", "chat"], what: "new conversation" },
  { id: "reply", keys: ["Alt+R"], tier: 2, mutates: false, where: ["chat", "tree", "work"],
    what: "answer what waits on you: go to the oldest card in the chat that waits, or on the tree the request nearest the work picked, or the work's" },
  { id: "mark-read", keys: ["Alt+M"], tier: 2, mutates: true, where: ["chat"], what: "show the oldest note to you and mark it read" },
  { id: "open-tree", keys: ["Alt+O"], tier: 2, mutates: false, where: ["work", "thread"], what: "its conversation's tree, the work picked" },
  { id: "by-state", keys: ["Alt+S"], tier: 2, mutates: false, where: ["board"], what: "the works by state" },
  { id: "by-agent", keys: ["Alt+A"], tier: 2, mutates: false, where: ["board"], what: "a lane per agent" },
  { id: "by-project", keys: ["Alt+J"], tier: 2, mutates: false, where: ["board"], what: "a lane per project" },
  { id: "send", keys: [], tier: 0, mutates: true, where: [], what: "send a message" },
  { id: "answer", keys: [], tier: 0, mutates: true, where: [], what: "answer a request" },
  { id: "grant", keys: [], tier: 0, mutates: true, where: [], what: "grant a permission" },
  { id: "deny", keys: [], tier: 0, mutates: true, where: [], what: "deny a permission" },
  { id: "escalate-request", keys: [], tier: 0, mutates: true, where: [], what: "escalate a request" },
  { id: "revert", keys: [], tier: 0, mutates: true, where: [], what: "revert a change" },
  { id: "delete", keys: [], tier: 0, mutates: true, where: [], what: "delete" },
  { id: "cancel", keys: [], tier: 0, mutates: true, where: [], what: "cancel a work" }
]

function find(id) {
  return table.find(entry => entry.id === id)
}

// The key sequences of an entry.
function keys(id) {
  return find(id).keys
}

// The one chord of a command, as a Shortcut takes it.
function chord(id) {
  return find(id).keys[0]
}

// How the keys of an entry read: its label, else the keys joined.
function label(id) {
  const entry = find(id)
  return entry.label || entry.keys.join(" · ")
}

// [keys, what] for each entry with keys listed under the group `where`.
function rows(where) {
  return table.filter(entry => entry.keys.length > 0 && entry.where.includes(where))
    .map(entry => [label(entry.id), entry.what])
}
