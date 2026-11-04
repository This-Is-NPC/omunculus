pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui/focus.js" as Focus
import "kit/ui"

// PagesView is the window's pages, one on screen at a time, in two levels.
// The project's: its conversations, and the board, the works of every
// project the window reaches, where a card opens its work on a page of its
// own, from where its conversation's team opens; whom a new conversation is
// with is chosen on a screen of the conversations. A conversation's, once one
// is open, in place of the project's: its chat, yours with the root agent,
// where each question for you is a card, under the progress strip and, opened,
// the progress beside the thread (a card over it on a medium window, a sheet
// over the page on a narrow one); the team, the outline of the works and the
// work picked in full (TeamView); the log, every event a row; and what it
// cost. A work's thread also opens as a page of its own, under the way down to
// it. The log, the team and the cost are loaded when first on screen. Each
// page gives the commands of its bar: on the chat, to answer what waits on
// you there, read its notes and open the progress; on the team, what you can
// do to the work picked — answer or escalate what waits, write to its agent,
// leave it a note, mark its notes read. On the chat a request is answered in
// its card; elsewhere in its decision, opened over the page. Every
// move into another level, conversation or project is remembered, so BACK, and
// Esc once the page has let go of what it holds, return to exactly where it
// was: the page, its project, its conversation and the node picked; back
// from the first page entered is back to the start.
Item {
  id: view

  property bool active: false
  property bool short: false
  // Back from the first page entered.
  signal startWanted()

  readonly property bool open: Omunculus.conversationId !== ""
  // The pages of the level on screen, in their order: the project's, or the
  // conversation's open.
  readonly property var inConversation: ["chat", "map", "log", "cost"]
  // The pages of a conversation: its own, and a work's thread, a page of the chat.
  readonly property var ofConversation: inConversation.concat(["thread"])
  readonly property var pages: ofConversation.includes(page) ? (open ? inConversation : ["chat"]) : ["conversations", "board"]
  // The one on screen: a page, or "new", whom a new conversation is with,
  // a screen of the conversations.
  property string page: "conversations"
  readonly property int tabIndex: pages.indexOf(({ new: "conversations", work: "board", thread: "chat" })[page] || page)
  readonly property string title: page === "new" ? "new conversation" : page
  // What the page is called in the masthead: the map is the team, a thread
  // is its work's title.
  readonly property string pageName: page === "map" ? "team" : page === "thread" ? Omunculus.titleOf(threadWork) : page
  // What the masthead names: the board, or the project, then the
  // conversation open and its page, or the page; on a narrow window, only
  // the conversation, or the page, as the bar names the page.
  readonly property string heading: page === "board" ? page
    : Omunculus.project + "  /  " + (ofConversation.includes(page) ? (Omunculus.subject || "new conversation") + "  /  " + pageName : title)
  readonly property string shortHeading: ofConversation.includes(page) ? Omunculus.subject || "new conversation" : title
  // Whether the chat asks whom an empty conversation is with.
  readonly property bool asking: page === "chat" && Omunculus.whomAsked
  // Whether the page takes the digits alone, as the pickers of whom a
  // conversation is with do; Ctrl with them still chooses a page.
  readonly property bool digitsTaken: page === "new" || asking

  // Whether the progress is open, as chosen on this conversation, or null
  // while it shows as its place has it: the dock open once there is a work,
  // the card and the sheet closed.
  property var progressChoice: null
  readonly property bool progressShown: progressChoice !== null ? progressChoice : chat.progressMode === "dock" && Omunculus.works.length > 0
  // The logged work the log is kept to, and, kept while the team page is
  // not loaded, the work picked on it ("" for none) and whether it shows the
  // outline or the map.
  property string logFilter: ""
  property string pickedNode: ""
  property string teamShownAs: "outline"
  // The work whose thread is on the thread page.
  property string threadWork: ""

  // Where the window was before each move, the last last, as {page,
  // project, socket, conversation, picked, work, thread}.
  property var history: []

  function here() {
    return { page: page, project: Omunculus.project, socket: Omunculus.socket, conversation: Omunculus.conversationId, picked: pickedNode, work: workKey, thread: threadWork }
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

  // Back to where the window was before its last move, or to the start. A
  // conversation that has said nothing, or is not made yet, is left for the
  // picker it began on; one that has is not returned to it. Leaving makes
  // nothing.
  function back() {
    const fresh = Omunculus.drafting || (open && Omunculus.thread("").count === 0)
    if (!fresh)
      while (history.length > 0 && history[history.length - 1].page === "new")
        history = history.slice(0, -1)
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
    // A page of a conversation has one open.
    page = ofConversation.includes(at.page) && at.conversation === "" ? "conversations" : at.page
    pickedNode = at.picked
    workKey = at.work
    threadWork = at.thread
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

  // Opens a work's conversation on its team page, the work picked.
  function openWork(work) {
    remember()
    reach(work)
    pickedNode = work.id
    page = "map"
  }

  // Opens the log kept to the events of a work; BACK returns.
  function showLog(work) {
    remember()
    logFilter = work
    page = "log"
  }

  // Shows a work's thread as a page of its own, under the way down to it.
  function openThread(work) {
    if (work === threadWork && page === "thread")
      return
    remember()
    threadWork = work
    page = "thread"
  }

  // The works from the conversation's root down to `work`, outermost first.
  function trailOf(work) {
    const chain = []
    for (let at = Omunculus.work(work); at; at = at.parent_id ? Omunculus.work(at.parent_id) : null)
      chain.unshift(at)
    return chain
  }

  // Puts the keyboard in the words of the newest question for you; the
  // sheet of the progress, over the chat, closes first.
  function replyNow() {
    if (progressShown && chat.progressMode === "sheet")
      progressChoice = false
    timeline.focusCard()
  }

  // Opens or closes the progress; opened, the keyboard goes to its tree
  // when `focusing`, or always over a narrow chat, where it covers the
  // composer; closed, back to the composer.
  function toggleProgress(focusing) {
    progressChoice = !progressShown
    if (!progressShown)
      mainComposer.focusEntry()
    else if (focusing || chat.progressMode === "sheet")
      Qt.callLater(() => { if (chat.progressArea()) chat.progressArea().focusTree() })
  }

  // The team page and the log, while they are loaded.
  readonly property TeamView team: agentsPage.item as TeamView
  readonly property LogView events: logPage.item as LogView

  // The work picked on the team page, or "" for none; its requests still
  // waiting, those on you first, those on you alone, and its notes to you
  // unread.
  readonly property string node: pickedNode
  readonly property var asked: node === "" ? [] : Omunculus.asked(node).slice().sort((a, b) => Requests.human(b.arbiter) - Requests.human(a.arbiter))
  readonly property var askedOfYou: asked.filter(request => Requests.human(request.arbiter))
  readonly property var notesHere: node === "" ? [] : Omunculus.unreadFrom(node)

  // The commands of the page on screen, as the PageBar takes them; those with
  // a `key` answer to it too.
  readonly property var commands: {
    const last = history.length > 0 ? history[history.length - 1] : null
    // On the team page, BACK lets go of what the page holds first.
    const back = { text: "BACK", role: "back", tip: "back to the " + (last ? ({ map: "team" })[last.page] || last.page : "start") + "  " + Shortcuts.label("back"),
      run: () => { if (!(view.page === "map" && team && team.back())) view.back() } }
    // A new conversation: the main action of the conversations, another on the chat.
    const fresh = role => ({ text: "NEW CONVERSATION", short: "NEW", icon: "plus", role: role, tip: "start another conversation  " + Shortcuts.label("new-conversation"),
      run: () => view.newConversation() })
    if (page === "conversations")
      return [back, fresh("primary")]
    if (page === "new" || page === "cost")
      return [back]
    if (page === "work") {
      const waiting = Omunculus.asked(workKey).filter(request => Requests.human(request.arbiter))
      return [
        back,
        { text: "REPLY", icon: "enter", role: "primary", tone: Theme.warning, key: Shortcuts.chord("reply"), tip: "answer what it asked you  " + Shortcuts.label("reply"),
          shown: waiting.length > 0, run: () => decision.show(waiting[0].id, false) },
        { text: "OPEN IN TEAM", short: "TEAM", icon: "people", key: Shortcuts.chord("open-team"), tip: "its conversation's team, the work picked  " + Shortcuts.label("open-team"),
          run: () => view.openWork({ id: workKey, project: Omunculus.project, conversation_id: Omunculus.conversationId }) }
      ]
    }
    if (page === "thread")
      return [
        back,
        { text: "OPEN IN TEAM", short: "TEAM", icon: "people", key: Shortcuts.chord("open-team"), tip: "the team, this work picked  " + Shortcuts.label("open-team"),
          run: () => view.openWork({ id: threadWork, project: Omunculus.project, conversation_id: Omunculus.conversationId }) },
        { text: "LOG", icon: "list", tip: "the log kept to this work", run: () => view.showLog(threadWork) }
      ]
    if (page === "map") {
      // Alt+R answers what waits on you nearest the work picked, else what
      // the work asked, instead of whoever decides.
      const nearest = team ? team.nearestForYou() : ""
      const replyTo = nearest !== "" ? nearest : asked.length > 0 ? asked[0].id : ""
      const mapAllowed = !!team && team.mapAllowed
      return [
        back,
        { text: "REPLY", icon: "enter", role: "primary", tone: nearest !== "" ? Theme.warning : Theme.primary, key: Shortcuts.chord("reply"),
          tip: (nearest !== "" ? "answer what waits on you, nearest the work picked" : "answer what it asked, instead of whoever decides") + "  " + Shortcuts.label("reply"),
          shown: replyTo !== "", run: () => decision.show(replyTo, false) },
        { text: "OUTLINE", icon: "list", group: "view", checked: teamShownAs !== "map", shown: mapAllowed,
          tip: "the works as an outline", run: () => view.teamShownAs = "outline" },
        { text: "MAP", icon: "map", group: "view", checked: teamShownAs === "map", shown: mapAllowed,
          tip: "the works as a map, one card each", run: () => view.teamShownAs = "map" },
        { text: "WRITE", icon: "edit", key: Shortcuts.chord("write"), tip: "write to its agent  " + Shortcuts.label("write"),
          shown: node !== "", run: () => team.write(false) },
        { text: "NOTE", icon: "plus", key: Shortcuts.chord("comment"), tip: "a note for its agents, without a run  " + Shortcuts.label("comment"),
          shown: node !== "", run: () => team.write(true) },
        { text: "ESCALATE", icon: "chevron-up", key: Shortcuts.chord("escalate"), tip: "raise what it asked you to whoever decides above you  " + Shortcuts.label("escalate"),
          shown: askedOfYou.length > 0, run: () => decision.show(askedOfYou[0].id, true) },
        { text: "MARK READ", icon: "check", key: Shortcuts.chord("mark-read"), tip: (notesHere.length > 1 ? "mark its " + notesHere.length + " notes read" : "mark its note read") + "  " + Shortcuts.label("mark-read"),
          shown: notesHere.length > 0, run: () => notesHere.forEach(note => Omunculus.markRead(note.id)) },
        { text: "FIT", icon: "map", place: "end", key: Shortcuts.chord("fit"), tip: "the whole map in view  " + Shortcuts.label("fit"),
          shown: mapAllowed && teamShownAs === "map", run: () => team.fit() },
        { text: "FILTER", icon: "search", place: "end", tip: "filter the works  /", run: () => team.focusFilter() }
      ]
    }
    if (page === "board")
      return [
        back,
        { text: "BY STATE", short: "STATE", icon: "board", key: Shortcuts.chord("by-state"), group: "view", checked: board.group === "",
          tip: "the works by state alone  " + Shortcuts.label("by-state"), run: () => board.group = "" },
        { text: "BY AGENT", short: "AGENT", icon: "people", key: Shortcuts.chord("by-agent"), group: "view", checked: board.group === "agent",
          tip: "a lane per agent  " + Shortcuts.label("by-agent"), run: () => board.group = "agent" },
        { text: "BY PROJECT", short: "PROJECT", icon: "folder", key: Shortcuts.chord("by-project"), group: "view", checked: board.group === "project",
          tip: "a lane per project  " + Shortcuts.label("by-project"), run: () => board.group = "project" },
        { text: "FILTER", icon: "search", place: "end", tip: "filter the works  /", run: () => board.focusFilter() }
      ]
    if (page === "log") {
      const picked = !!events && events.picked !== null
      return [
        back,
        { text: "FILTER", icon: "search", place: "end", tip: "filter the events  /", run: () => events.focusFilter() },
        { text: picked ? "COPY EVENT" : "COPY LOG", icon: "copy", place: "end", tip: picked ? "copy the event picked" : "copy the events shown",
          enabled: picked || (!!events && events.source.count > 0), run: () => events.copy() }
      ]
    }
    return [
      back,
      { text: "REPLY  " + Omunculus.waiting.length, short: "REPLY", icon: "enter", role: "primary", tone: Theme.warning, key: Shortcuts.chord("reply"),
        tip: "answer the newest question waiting on you" + (Omunculus.waiting.length > 1 ? ", of " + Omunculus.waiting.length : "") + "  " + Shortcuts.label("reply"),
        shown: Omunculus.waiting.length > 0, run: () => view.replyNow() },
      { text: "PROGRESS", icon: "list", key: Shortcuts.chord("progress"), checked: progressShown,
        tip: (progressShown ? "close" : "open") + " the progress of the works  " + Shortcuts.label("progress"),
        shown: !asking, run: () => view.toggleProgress(true) },
      { text: "MARK READ", icon: "check", tone: Theme.warning, key: Shortcuts.chord("mark-read"),
        tip: "show the oldest note to you and mark it read" + (Omunculus.unread.length > 1 ? ", of " + Omunculus.unread.length : "") + "  " + Shortcuts.label("mark-read"),
        shown: Omunculus.unread.length > 0, run: () => {
          timeline.reveal(Omunculus.unread[0].id)
          Omunculus.markRead(Omunculus.unread[0].id)
        } },
      fresh(undefined)
    ]
  }

  // Chords of the page that are no command of its bar: the team's tabs.
  readonly property var chords: page === "map" && team ? [
    { key: Shortcuts.chord("team-log"), run: () => view.team.showTab("log") },
    { key: Shortcuts.chord("team-changes"), run: () => view.team.showTab("changes") }
  ] : []

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
      agentsPage.forceActiveFocus()
    else if (page === "log")
      logPage.forceActiveFocus()
    else if (page === "cost")
      costPage.forceActiveFocus()
    else if (page === "work")
      workPage.forceActiveFocus()
    else if (page === "thread")
      threadComposer.focusEntry()
    else if (asking)
      whom.forceActiveFocus()
    else
      mainComposer.focusEntry()
  }

  focus: active
  onActiveChanged: if (active) focusEntry()
  // Esc in a question's card or in the progress returns to the composer;
  // the progress sheet over a narrow chat closes first.
  Keys.onEscapePressed: {
    if (page === "chat") {
      const sheet = progressShown && chat.progressMode === "sheet"
      if (sheet || timeline.cardFocused() || Focus.within(Window.activeFocusItem, chat.progressArea())) {
        if (sheet)
          progressChoice = false
        mainComposer.focusEntry()
        return
      }
    }
    back()
  }
  onPageChanged: {
    if (page !== "log")
      logFilter = ""
    Qt.callLater(focusEntry)
  }
  onAskingChanged: Qt.callLater(focusEntry)
  Connections {
    target: Omunculus
    function onLoadedChanged() {
      if (Omunculus.loaded)
        Qt.callLater(view.focusEntry)
    }
    function onConversationIdChanged() {
      // The conversation's pages go with it.
      if (!view.open && view.ofConversation.includes(view.page))
        view.page = "conversations"
      view.pickedNode = ""
      view.progressChoice = null
      if (view.events)
        view.events.picked = null
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
    // The composer takes the keyboard once the chat can show it.
    onVisibleChanged: if (visible) Qt.callLater(view.focusEntry)

    Item {
      id: chat
      anchors.fill: parent
      // Where the progress opens, by the window's width: docked beside the
      // thread, a card over it, or a sheet over the whole chat.
      readonly property string progressMode: ({ wide: "dock", medium: "card", narrow: "sheet" })[Breakpoints.size(Window.width)]
      // The item the progress is in, while it is open.
      function progressArea(): ProgressSheet { return (dockLoader.item || cardLoader.item) as ProgressSheet }
      readonly property bool docked: dockLoader.active && progressMode === "dock"

      ColumnLayout {
        anchors {
          left: parent.left
          top: parent.top
          bottom: parent.bottom
          right: chat.docked ? dockLoader.left : parent.right
          rightMargin: chat.docked ? 16 : 0
        }
        spacing: view.short ? 10 : 14

        ProgressStrip {
          Layout.fillWidth: true
          visible: !view.asking
          progress: Omunculus.progress || null
          lastEvent: Omunculus.lastEventAt
          expanded: view.progressShown
          onToggle: view.toggleProgress(false)
          onAnswer: view.replyNow()
        }

        // Medium: the progress under the strip, pushing the thread down.
        Loader {
          id: cardLoader
          Layout.fillWidth: true
          visible: active
          active: view.progressShown && chat.progressMode === "card" && !view.asking
          sourceComponent: progressView
        }

        TimelineView {
          id: timeline
          visible: !view.asking
          Layout.fillWidth: true
          Layout.fillHeight: true
          thread: ""
          onAnswered: mainComposer.focusEntry()
          onOpenWork: work => view.openThread(work)
        }

        // An empty conversation opened from the list names no agent yet.
        AgentPicker {
          id: whom
          visible: view.asking
          Layout.fillWidth: true
          Layout.fillHeight: true
          onPicked: name => Omunculus.agent = name
          onBack: view.back()
        }

        Composer {
          id: mainComposer
          visible: !view.asking
          Layout.fillWidth: true
        }
      }

      // Wide: the progress beside the thread, the page's full height;
      // narrow: a sheet over the whole chat.
      Loader {
        id: dockLoader
        z: 2
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
        width: chat.progressMode === "dock" ? 380 : chat.width
        active: view.progressShown && chat.progressMode !== "card" && !view.asking
        visible: active
        sourceComponent: progressView
      }

      // Each place loads it only in its own mode; the card is at most
      // 55 % of the chat's height.
      Component {
        id: progressView
        ProgressSheet {
          mode: chat.progressMode
          maximumHeight: chat.height * 0.55
          progress: Omunculus.progress || null
          onClosed: {
            view.progressChoice = false
            mainComposer.focusEntry()
          }
          onEscaped: mainComposer.focusEntry()
          onAnswer: view.replyNow()
          onOpenThread: work => view.openThread(work)
          onOpenLog: work => view.showLog(work)
          onOpenMap: work => {
            // The team shows the map where there is room for it.
            view.teamShownAs = "map"
            view.openWork({ id: work, project: Omunculus.project, conversation_id: Omunculus.conversationId })
          }
        }
      }
    }
  }

  // A work's thread, as a page of its own: the way down to it, its
  // transcript, and a composer to its agent. A crumb goes back up, the first
  // one to the chat.
  Stage {
    anchors.fill: parent
    shown: view.page === "thread"

    ColumnLayout {
      anchors.fill: parent
      spacing: view.short ? 10 : 14

      Breadcrumb {
        id: threadTrail
        readonly property var works: view.trailOf(view.threadWork)
        Layout.fillWidth: true
        trail: [{ text: "Conversation" }].concat(works.map(work => ({ text: work.title || "a work" })))
        onChosen: index => {
          if (index === 0)
            view.go("chat")
          else if (works[index - 1].id !== view.threadWork)
            view.openThread(works[index - 1].id)
        }
      }

      TimelineView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        thread: Omunculus.threadOf(view.threadWork)
        emptyText: "NOTHING SAID HERE YET"
        onOpenWork: work => view.openThread(work)
      }

      Composer {
        id: threadComposer
        Layout.fillWidth: true
        work: view.threadWork
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
      // The conversation is made by its first message, not by the pick.
      onPicked: name => {
        view.remember()
        Omunculus.agent = name
        view.page = "chat"
      }
      onBack: view.back()
    }
  }

  // The team, the log and the cost are loaded while on screen.
  Stage {
    id: teamStage
    anchors.fill: parent
    shown: view.page === "map"

    Loader {
      id: agentsPage
      anchors.fill: parent
      active: teamStage.shown || teamStage.visible
      focus: view.page === "map"
      sourceComponent: TeamView {
        onLeave: view.back()
        onOpenLog: work => view.showLog(work)
      }
    }
    // The work picked and the view shown are kept here, so they outlive the page.
    Connections {
      target: view.team
      function onPickedChanged() { view.pickedNode = view.team.picked }
      function onShownAsChanged() { view.teamShownAs = view.team.shownAs }
    }
    Binding {
      target: view.team
      property: "picked"
      value: view.pickedNode
      when: view.team !== null
    }
    Binding {
      target: view.team
      property: "shownAs"
      value: view.teamShownAs
      when: view.team !== null
    }
  }

  Stage {
    id: logStage
    anchors.fill: parent
    shown: view.page === "log"

    Loader {
      id: logPage
      anchors.fill: parent
      active: logStage.shown || logStage.visible
      focus: view.page === "log"
      sourceComponent: LogView {
        filter: view.logFilter
        onLeave: view.back()
      }
    }
  }

  Stage {
    id: costStage
    anchors.fill: parent
    shown: view.page === "cost"

    Loader {
      id: costPage
      anchors.fill: parent
      active: costStage.shown || costStage.visible
      focus: view.page === "cost"
      sourceComponent: CostView { onLeave: view.back() }
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
