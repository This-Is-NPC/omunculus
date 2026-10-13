import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// PagesView is the window's pages, one on screen at a time: the
// conversations of the project; the conversation open, yours with the root
// agent, where every request shows where it was made, or, with none open,
// whom a new one is with; the map of its agents at work, where the node
// picked opens beside it; the log, every event a row; and the board, the
// works of every project the window reaches, where a card opens its
// conversation's map with the work picked. The map and the log, with no
// conversation open, say so and lead to one. Each page gives the commands of
// its bar: on the conversation, to answer what waits on you there and read
// its notes; on the map, with a node picked, what you can do to it — answer
// or escalate what it asked, leave it a note, mark its notes read, write to
// it. A request is answered in its decision, opened over the page. Every
// move to another page, conversation or project is remembered, so BACK, and
// Esc once the page has let go of what it holds, return to exactly where it
// was: the page, its project, its conversation and the node picked; back
// from the first page entered is back to the start.
Item {
  id: view

  property bool active: false
  property bool compact: false
  property bool short: false
  signal costWanted()
  // Back from the first page entered.
  signal startWanted()

  // The pages, in their order, and the one on screen.
  readonly property var pages: ["conversations", "conversation", "map", "log", "board"]
  property string page: "conversations"
  readonly property bool open: Omunculus.conversationId !== ""
  // What the masthead names: the page, or the project and the conversation
  // open on it.
  readonly property string heading: page === "board" ? page
    : Omunculus.project + "  ·  " + (page === "conversations" ? page
      : open ? Omunculus.title
      : page === "conversation" ? "new conversation" : "no conversation")
  // Whether the page takes the digits alone, as the picker of a new
  // conversation does; Ctrl with them still chooses a page.
  readonly property bool digitsTaken: page === "conversation" && !open

  // Where the window was before each move, the last last, as {page,
  // project, socket, conversation, picked}.
  property var history: []

  function here() {
    return { page: page, project: Omunculus.project, socket: Omunculus.socket, conversation: Omunculus.conversationId, picked: agents.picked }
  }
  function remember() { history = history.concat([here()]).slice(-50) }

  // Goes to a page, remembering where it was.
  function go(name) {
    if (name === page)
      return
    remember()
    page = name
  }

  // Enters the pages from the start, at a page, with nothing behind it.
  function enter(name) {
    history = []
    page = name
  }

  // Back to where the window was before its last move, or to the start.
  function back() {
    if (history.length === 0) {
      startWanted()
      return
    }
    const at = history[history.length - 1]
    history = history.slice(0, -1)
    if (at.project !== Omunculus.project)
      Omunculus.switchProject({ id: at.project, socket: at.socket })
    if (at.conversation !== Omunculus.conversationId) {
      if (at.conversation === "")
        Omunculus.close()
      else
        Omunculus.open(at.conversation)
    }
    page = at.page
    agents.picked = at.picked
  }

  function openConversation(id) {
    remember()
    if (id !== Omunculus.conversationId)
      Omunculus.open(id)
    page = "conversation"
  }

  // The conversation page with none open: whom a new one is with.
  function newConversation() {
    remember()
    Omunculus.close()
    page = "conversation"
  }

  // Opens a work's conversation on its map, the work picked; a work of
  // another project first turns the window to that project.
  function openWork(work) {
    remember()
    const place = Omunculus.boardProjects.find(item => item.id === work.project)
    if (place)
      Omunculus.switchProject(place)
    if (Omunculus.conversationId !== work.conversation_id)
      Omunculus.open(work.conversation_id)
    page = "map"
    agents.pick(work.id)
  }

  // Opens the map on what waits on you.
  function showPending() {
    go("map")
    agents.pickPending()
  }

  // The node picked on the map: a work, "" for the root agent's own
  // conversation, or null for none; its requests still waiting, those on you
  // first, those on you alone, and its notes to you unread.
  readonly property var node: agents.picked
  readonly property var asked: node === null ? [] : Omunculus.asked(node).slice().sort((a, b) => Requests.human(b.arbiter) - Requests.human(a.arbiter))
  readonly property var askedOfYou: asked.filter(request => Requests.human(request.arbiter))
  readonly property var notesHere: node === null ? [] : Omunculus.unreadFrom(node)

  // The commands of the page on screen, as the PageBar takes them; those with
  // a `key` answer to it too.
  readonly property var commands: {
    const last = history.length > 0 ? history[history.length - 1] : null
    const back = { text: "BACK", icon: "chevron-left", role: "navigation", tip: "back to the " + (last ? last.page : "start") + "  esc",
      run: () => view.back() }
    const fresh = { text: "NEW CONVERSATION", short: "NEW", icon: "plus", key: "N", tip: "start another conversation  n", run: () => view.newConversation() }
    const cost = { text: "COST", icon: "cost", tip: "what this conversation cost", run: () => view.costWanted() }
    if (page === "conversations")
      return [back, fresh]
    if (!open && page !== "board")
      return [back]
    if (page === "map" && node !== null)
      return [
        back,
        { text: "REPLY", icon: "enter", tone: askedOfYou.length > 0 ? Theme.warning : Theme.primary, key: "R",
          tip: (askedOfYou.length > 0 ? "answer what it asked you" : "answer what it asked, instead of whoever decides") + "  r",
          shown: asked.length > 0, run: () => decision.show(asked[0].id, false) },
        { text: "ESCALATE", icon: "chevron-up", key: "E", tip: "raise what it asked you to whoever decides above you  e",
          shown: askedOfYou.length > 0, run: () => decision.show(askedOfYou[0].id, true) },
        { text: "COMMENT", icon: "plus", key: "C", tip: "a note for its agents, without a run  c",
          shown: node !== "", run: () => agents.write(true) },
        { text: "MARK READ", icon: "check", key: "M", tip: (notesHere.length > 1 ? "mark its " + notesHere.length + " notes read" : "mark its note read") + "  m",
          shown: notesHere.length > 0, run: () => notesHere.forEach(note => Omunculus.markRead(note.id)) },
        { text: "WRITE", icon: "edit", key: "W", tip: "write to its agent  w", run: () => agents.write(false) },
        cost
      ]
    if (page === "map")
      return [
        back,
        { text: "FIT", icon: "map", tip: "the whole map in view  f", run: () => agents.fit() },
        { text: Omunculus.pending + " PENDING", short: String(Omunculus.pending), icon: "warning", tone: Theme.warning, tip: "pick what waits on you",
          shown: Omunculus.pending > 0, run: () => agents.pickPending() },
        cost
      ]
    if (page === "board")
      return [
        back,
        { text: "BY STATE", short: "STATE", icon: "board", key: "S", tone: board.group === "" ? Theme.primary : Theme.dim,
          tip: "the works by state alone  s", run: () => board.group = "" },
        { text: "BY AGENT", short: "AGENT", icon: "people", key: "A", tone: board.group === "agent" ? Theme.primary : Theme.dim,
          tip: "a lane per agent  a", run: () => board.group = "agent" },
        { text: "BY PROJECT", short: "PROJECT", icon: "folder", key: "P", tone: board.group === "project" ? Theme.primary : Theme.dim,
          tip: "a lane per project  p", run: () => board.group = "project" },
        { text: "FILTER", tip: "filter the works  /", run: () => board.focusFilter() }
      ]
    if (page === "log")
      return [
        back,
        { text: "FILTER", tip: "filter the events  /", run: () => log.focusFilter() },
        { text: log.picked ? "COPY EVENT" : "COPY LOG", short: "COPY", icon: "copy", tip: log.picked ? "copy the event picked" : "copy the events shown",
          enabled: log.picked !== null || log.rows.length > 0, run: () => log.copy() }
      ]
    return [
      back,
      { text: "REPLY", icon: "enter", tone: Theme.warning, key: "R",
        tip: "answer the oldest request waiting on you" + (Omunculus.waiting.length > 1 ? ", of " + Omunculus.waiting.length : "") + "  r",
        shown: Omunculus.waiting.length > 0, run: () => {
          timeline.reveal(Omunculus.waiting[0].id)
          decision.show(Omunculus.waiting[0].id, false)
        } },
      { text: "MARK READ", icon: "check", tone: Theme.warning, key: "M",
        tip: "show the oldest note to you and mark it read" + (Omunculus.unread.length > 1 ? ", of " + Omunculus.unread.length : "") + "  m",
        shown: Omunculus.unread.length > 0, run: () => {
          timeline.reveal(Omunculus.unread[0].id)
          Omunculus.markRead(Omunculus.unread[0].id)
        } },
      fresh,
      cost
    ]
  }

  // Whether the decision of a request is open over the page.
  readonly property bool dialogOpen: decision.visible

  function focusEntry() {
    if (page === "conversations")
      conversations.focusEntry()
    else if (page === "board")
      board.focusEntry()
    else if (!open)
      (page === "conversation" ? picker : missing).forceActiveFocus()
    else if (page === "map")
      agents.forceActiveFocus()
    else if (page === "log")
      log.forceActiveFocus()
    else
      mainComposer.focusEntry()
  }

  focus: active
  onActiveChanged: if (active) focusEntry()
  Keys.onEscapePressed: back()
  onPageChanged: Qt.callLater(focusEntry)
  Connections {
    target: Omunculus
    function onConversationIdChanged() {
      agents.picked = null
      log.picked = null
      Qt.callLater(view.focusEntry)
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "conversations"

    HistoryView {
      id: conversations
      anchors.fill: parent
      active: parent.shown && view.active
      focus: view.page === "conversations"
      onOpened: id => view.openConversation(id)
      onLeave: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "conversation" && view.open

    ColumnLayout {
      anchors.fill: parent
      spacing: view.short ? 10 : 14

      TimelineView {
        id: timeline
        Layout.fillWidth: true
        Layout.fillHeight: true
        thread: ""
      }

      Composer {
        id: mainComposer
        Layout.fillWidth: true
        compact: view.compact
        onPendingChosen: view.showPending()
      }
    }
  }

  // With no conversation open: whom a new one is with.
  Stage {
    anchors.fill: parent
    shown: view.page === "conversation" && !view.open

    AgentPicker {
      id: picker
      anchors.fill: parent
      focus: parent.shown
      onPicked: name => Omunculus.createConversation(name)
      onBack: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "map" && view.open

    AgentsView {
      id: agents
      anchors.fill: parent
      focus: view.page === "map"
      onLeave: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "log" && view.open

    LogView {
      id: log
      anchors.fill: parent
      focus: view.page === "log"
      onLeave: view.back()
    }
  }

  // The map and the log with no conversation open.
  Stage {
    anchors.fill: parent
    shown: (view.page === "map" || view.page === "log") && !view.open

    NoConversation {
      id: missing
      anchors.fill: parent
      focus: parent.shown
      what: view.page
      onListWanted: view.go("conversations")
      onNewWanted: view.newConversation()
      onLeave: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "board"

    BoardView {
      id: board
      anchors.fill: parent
      focus: view.page === "board"
      onLeave: view.back()
      onOpened: work => view.openWork(work)
    }
  }

  // The projects' streams are read while the board is on screen.
  readonly property bool watching: active && page === "board"
  onWatchingChanged: Omunculus.watchBoard(watching)

  RequestDialog { id: decision }
}
