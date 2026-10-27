import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// PagesView is the window's pages, one on screen at a time, in two levels.
// The project's: its conversations, and the board, the works of every
// project the window reaches, where a card opens its work on a page of its
// own, from where its conversation's map opens; whom a new conversation is with is chosen on a screen of
// the conversations. A conversation's, once one is open, in place of the
// project's: its chat, yours with the root agent, where every request shows
// where it was made; the map of its agents at work, where the node picked
// opens beside it; the log, every event a row; and what it cost. Each page
// gives the commands of its bar: on
// the chat, to answer what waits on you there and read its notes; on the map, with a node picked, what you can do to it — answer
// or escalate what it asked, leave it a note, mark its notes read, write to
// it. A request is answered in its decision, opened over the page. Every
// move into another level, conversation or project is remembered, so BACK, and
// Esc once the page has let go of what it holds, return to exactly where it
// was: the page, its project, its conversation and the node picked; back
// from the first page entered is back to the start.
Item {
  id: view

  property bool active: false
  property bool compact: false
  property bool short: false
  // Back from the first page entered.
  signal startWanted()

  readonly property bool open: Omunculus.conversationId !== ""
  // The pages of the level on screen, in their order: the project's, or the
  // conversation's open.
  readonly property var inConversation: ["chat", "map", "log", "cost"]
  readonly property var pages: inConversation.includes(page) ? inConversation : ["conversations", "board"]
  // The one on screen: a page, or "new", whom a new conversation is with,
  // a screen of the conversations.
  property string page: "conversations"
  readonly property int tabIndex: pages.indexOf(page === "new" ? "conversations" : page === "work" ? "board" : page)
  readonly property string title: page === "new" ? "new conversation" : page
  // What the masthead names: the board, or the project, then the
  // conversation open and its page, or the page.
  readonly property string heading: page === "board" ? page
    : Omunculus.project + "  ·  " + (inConversation.includes(page) ? Omunculus.title + "  ·  " + page : title)
  // Whether the page takes the digits alone, as the picker of a new
  // conversation does; Ctrl with them still chooses a page.
  readonly property bool digitsTaken: page === "new"

  // Where the window was before each move, the last last, as {page,
  // project, socket, conversation, picked}.
  property var history: []

  function here() {
    return { page: page, project: Omunculus.project, socket: Omunculus.socket, conversation: Omunculus.conversationId, picked: agents.picked, work: workKey }
  }
  function remember() { history = history.concat([here()]).slice(-50) }

  // Goes to a page: one of the level on screen in place of the one there,
  // another level remembering where it was.
  function go(name) {
    if (name === page)
      return
    if (!pages.includes(name))
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
    workKey = at.work
  }

  function openConversation(id) {
    remember()
    if (id !== Omunculus.conversationId)
      Omunculus.open(id)
    page = "chat"
  }

  // Whom a new conversation is with.
  function newConversation() {
    remember()
    Omunculus.close()
    page = "new"
  }

  // The work on the work page.
  property string workKey: ""

  // Reads a work's conversation, of its project, turning the window to that
  // project first when it is another one.
  function reach(work) {
    const place = Omunculus.boardProjects.find(item => item.id === work.project)
    if (place && place.id !== Omunculus.project)
      Omunculus.switchProject(place)
    if (Omunculus.conversationId !== work.conversation_id)
      Omunculus.open(work.conversation_id)
  }

  // Shows a work on its page.
  function showWork(work) {
    remember()
    reach(work)
    workKey = work.id
    page = "work"
  }

  // Shows another work of the conversation open on the work page.
  function showOther(key) {
    remember()
    workKey = key
  }

  // Opens a work's conversation on its map, the work picked.
  function openWork(work) {
    remember()
    reach(work)
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
    const back = { text: "BACK", role: "back", tip: "back to the " + (last ? last.page : "start") + "  esc", run: () => view.back() }
    // A new conversation: the main action of the conversations, another on the chat.
    const fresh = role => ({ text: "NEW CONVERSATION", short: "NEW", icon: "plus", role: role, key: "N", tip: "start another conversation  n",
      run: () => view.newConversation() })
    if (page === "conversations")
      return [back, fresh("primary")]
    if (page === "new" || page === "cost")
      return [back]
    if (page === "work") {
      const waiting = Omunculus.asked(workKey).filter(request => Requests.human(request.arbiter))
      return [
        back,
        { text: "REPLY", icon: "enter", role: "primary", tone: Theme.warning, key: "R", tip: "answer what it asked you  r",
          shown: waiting.length > 0, run: () => decision.show(waiting[0].id, false) },
        { text: "OPEN IN MAP", short: "MAP", icon: "map", key: "O", tip: "its conversation's map, the work picked  o",
          run: () => view.openWork({ id: workKey, project: Omunculus.project, conversation_id: Omunculus.conversationId }) }
      ]
    }
    if (page === "map" && node !== null)
      return [
        back,
        { text: "REPLY", icon: "enter", role: "primary", tone: askedOfYou.length > 0 ? Theme.warning : Theme.primary, key: "R",
          tip: (askedOfYou.length > 0 ? "answer what it asked you" : "answer what it asked, instead of whoever decides") + "  r",
          shown: asked.length > 0, run: () => decision.show(asked[0].id, false) },
        { text: "WRITE", icon: "edit", key: "W", tip: "write to its agent  w", run: () => agents.write(false) },
        { text: "COMMENT", icon: "plus", key: "C", tip: "a note for its agents, without a run  c",
          shown: node !== "", run: () => agents.write(true) },
        { text: "ESCALATE", icon: "chevron-up", key: "E", tip: "raise what it asked you to whoever decides above you  e",
          shown: askedOfYou.length > 0, run: () => decision.show(askedOfYou[0].id, true) },
        { text: "MARK READ", icon: "check", key: "M", tip: (notesHere.length > 1 ? "mark its " + notesHere.length + " notes read" : "mark its note read") + "  m",
          shown: notesHere.length > 0, run: () => notesHere.forEach(note => Omunculus.markRead(note.id)) }
      ]
    if (page === "map")
      return [
        back,
        { text: Omunculus.pending + " PENDING", short: String(Omunculus.pending), icon: "warning", role: "primary", tone: Theme.warning,
          tip: "pick what waits on you", shown: Omunculus.pending > 0, run: () => agents.pickPending() },
        { text: "FIT", icon: "map", place: "end", tip: "the whole map in view  f", run: () => agents.fit() }
      ]
    if (page === "board")
      return [
        back,
        { text: "BY STATE", short: "STATE", icon: "board", key: "S", group: "view", checked: board.group === "",
          tip: "the works by state alone  s", run: () => board.group = "" },
        { text: "BY AGENT", short: "AGENT", icon: "people", key: "A", group: "view", checked: board.group === "agent",
          tip: "a lane per agent  a", run: () => board.group = "agent" },
        { text: "BY PROJECT", short: "PROJECT", icon: "folder", key: "P", group: "view", checked: board.group === "project",
          tip: "a lane per project  p", run: () => board.group = "project" },
        { text: "FILTER", icon: "search", place: "end", tip: "filter the works  /", run: () => board.focusFilter() }
      ]
    if (page === "log")
      return [
        back,
        { text: "FILTER", icon: "search", place: "end", tip: "filter the events  /", run: () => log.focusFilter() },
        { text: log.picked ? "COPY EVENT" : "COPY LOG", icon: "copy", place: "end", tip: log.picked ? "copy the event picked" : "copy the events shown",
          enabled: log.picked !== null || log.rows.length > 0, run: () => log.copy() }
      ]
    return [
      back,
      { text: "REPLY", icon: "enter", role: "primary", tone: Theme.warning, key: "R",
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
      fresh(undefined)
    ]
  }

  // Whether the decision of a request is open over the page.
  readonly property bool dialogOpen: decision.visible

  function focusEntry() {
    if (page === "conversations")
      conversations.focusEntry()
    else if (page === "board")
      board.focusEntry()
    else if (page === "new")
      picker.forceActiveFocus()
    else if (page === "map")
      agents.forceActiveFocus()
    else if (page === "log")
      log.forceActiveFocus()
    else if (page === "cost")
      cost.forceActiveFocus()
    else if (page === "work")
      workPage.forceActiveFocus()
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
      // The conversation's pages go with it.
      if (!view.open && view.inConversation.includes(view.page))
        view.page = "conversations"
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
    shown: view.page === "chat"

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

  // Whom a new conversation is with.
  Stage {
    anchors.fill: parent
    shown: view.page === "new"

    AgentPicker {
      id: picker
      anchors.fill: parent
      focus: parent.shown
      onPicked: name => Omunculus.createConversation(name, () => view.page = "chat")
      onBack: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "map"

    AgentsView {
      id: agents
      anchors.fill: parent
      focus: view.page === "map"
      onLeave: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "log"

    LogView {
      id: log
      anchors.fill: parent
      focus: view.page === "log"
      onLeave: view.back()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "cost"

    CostView {
      id: cost
      anchors.fill: parent
      focus: view.page === "cost"
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
      onOpened: work => view.showWork(work)
    }

  }

  Stage {
    anchors.fill: parent
    shown: view.page === "work"

    WorkView {
      id: workPage
      anchors.fill: parent
      focus: view.page === "work"
      key: view.workKey
      onLeave: view.back()
      onPicked: key => view.showOther(key)
    }
  }

  // The projects' streams are read while the board is on screen.
  readonly property bool watching: active && page === "board"
  onWatchingChanged: Omunculus.watchBoard(watching)

  RequestDialog { id: decision }
}
