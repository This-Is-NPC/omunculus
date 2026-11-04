.pragma library

// Every key the window answers to, in tiers.
//   0  no key of its own: anything that creates, sends, answers, grants,
//      denies, escalates, reverts, deletes or cancels is pressed or clicked,
//      or, a numbered quick chip over the composer, chosen by its chord.
//   1  a bare key, only for navigation without effect; it acts only while a
//      navigation item has the keyboard and no text field saw a key for a
//      second, so text that lost its field is never taken for commands.
//   2  a Ctrl or Alt chord, which a field being written leaves to it.
// `where` names the groups of the keys dialog the entry is listed in.
const table = [
  { id: "page", keys: ["1", "2", "3", "4"], tier: 1, mutates: false, label: "1 · 2 · …", where: ["everywhere"],
    what: "the page of that number: the projects and the board, a project's conversations and the board, or, in a conversation, its chat, team, log and cost" },
  { id: "page-chord", keys: ["Ctrl+1", "Ctrl+2", "Ctrl+3", "Ctrl+4"], tier: 2, mutates: false, label: "Ctrl+1 · Ctrl+2 · …", where: ["everywhere"],
    what: "the same, from a field being written or the picker" },
  { id: "next-page", keys: ["Ctrl+Tab"], tier: 2, mutates: false, where: ["everywhere"], what: "the next page" },
  { id: "previous-page", keys: ["Ctrl+Shift+Tab", "Ctrl+Backtab"], tier: 2, mutates: false, label: "Ctrl+Shift+Tab", where: ["everywhere"], what: "the previous page" },
  { id: "back", keys: ["Esc"], tier: 1, mutates: false, where: ["everywhere"],
    what: "let go of what the page holds, then back to where you were, at last the start" },
  { id: "filter", keys: ["/"], tier: 1, mutates: false, where: ["projects", "conversations", "board", "team", "log"], what: "search or filter" },
  { id: "tab", keys: ["[", "]"], tier: 1, mutates: false, where: ["team"], what: "the previous or next tab of the work picked" },
  { id: "help", keys: ["?", "F1"], tier: 1, mutates: false, where: ["everywhere"], what: "these keys" },
  { id: "start-new", keys: ["N"], tier: 1, mutates: false, where: ["start"], what: "a new conversation" },
  { id: "start-history", keys: ["H"], tier: 1, mutates: false, where: ["start"], what: "the conversations" },
  { id: "start-board", keys: ["B"], tier: 1, mutates: false, where: ["start"], what: "the board" },
  { id: "start-projects", keys: ["P"], tier: 1, mutates: false, where: ["start"], what: "the projects" },
  { id: "projects", keys: ["Ctrl+P"], tier: 2, mutates: false, where: ["everywhere"], what: "the projects, also from a field being written" },
  { id: "pick", keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9"], tier: 1, mutates: false, label: "1 … 9", where: ["new conversation"],
    what: "choose whom it is with, from the cards" },
  { id: "new-conversation", keys: ["Ctrl+N"], tier: 2, mutates: false, where: ["conversations", "chat"], what: "new conversation" },
  { id: "reply", keys: ["Alt+R"], tier: 2, mutates: false, where: ["chat", "team", "work"],
    what: "answer what waits on you: the newest request, the one nearest the work picked, or the work's" },
  { id: "progress", keys: ["Alt+P"], tier: 2, mutates: false, where: ["chat"], what: "open or close the progress of the works, on the chat from any page of the conversation" },
  { id: "quick", keys: ["Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5", "Alt+6", "Alt+7", "Alt+8", "Alt+9"], tier: 2, mutates: true, label: "Alt+1 … Alt+9", where: ["chat"],
    what: "the quick chip of that number over the composer: an option of the newest decision waiting on you, which decides it, then the progress" },
  { id: "mark-read", keys: ["Alt+M"], tier: 2, mutates: true, where: ["chat", "team"], what: "show the oldest note to you and mark it read, or the work's notes" },
  { id: "open-team", keys: ["Alt+O"], tier: 2, mutates: false, where: ["work", "thread"], what: "its conversation's team, the work picked" },
  { id: "write", keys: ["Alt+W"], tier: 2, mutates: false, where: ["team"], what: "write to the agent of the work picked" },
  { id: "comment", keys: ["Alt+C"], tier: 2, mutates: false, where: ["team"], what: "leave it a note, without a run" },
  { id: "escalate", keys: ["Alt+E"], tier: 2, mutates: false, where: ["team"], what: "open the decision of what it asked you, to escalate" },
  { id: "team-log", keys: ["Alt+L"], tier: 2, mutates: false, where: ["team"], what: "the log of the work picked" },
  { id: "team-changes", keys: ["Alt+G"], tier: 2, mutates: false, where: ["team"], what: "the changes of the work picked" },
  { id: "fit", keys: ["Alt+F"], tier: 2, mutates: false, where: ["team"], what: "the whole map in view" },
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
