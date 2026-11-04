pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui/focus.js" as Focus
import "kit/ui"

// PagesView is the window's pages, one on screen at a time, in three levels.
// The registry's: the projects of the server, where one opens at its
// conversations and NEW PROJECT registers another, and the board of all
// their works. A project's: its conversations, and the board, its works
// first, every project's one click away, where a card opens its work on a
// page of its own, from where its conversation's team opens; whom a new
// conversation is with is chosen on a screen of the conversations. Each page
// of these two levels gives the commands of its bar and the count of its
// readout. A conversation's, once one is open, in place of the project's,
// under its head: the header strip, with the conversation's meta, whose
// counts open the team and the cost, ANSWER while something waits on you
// and its progress on two lines, and its tabs.
// The chat, yours with the root agent, where each question for you is a
// card, the quick chips of the newest decision over the composer, and,
// opened, the progress beside the thread (a card over it on a medium window,
// a sheet over the page on a narrow one); the team, the outline of the works
// and the work picked in full (TeamView); the log, every event a row; and
// what it cost. A work's thread also opens as a page of its own, under the
// way down to it. The log, the team and the cost are loaded when first on
// screen. A conversation's pages have no bar: their rarer actions are the
// items of the masthead's menu (`more`), and their keys are chords. On the
// chat a request is answered in its card; elsewhere in its decision, opened
// over the page. Every move into another level, conversation or project is
// remembered, so BACK, and Esc once the page has let go of what it holds,
// return to exactly where it was: the page, its level, its project, its
// conversation and the node picked; back from the first page entered is
// back to the start. While the pages are entered, every project of the
// registry is followed.
Item {
  id: view

  property bool active: false
  property bool short: false
  // Between the blocks of a page: the head, the tabs, the content.
  readonly property int gap: short ? Theme.space.blockShort : Theme.space.block
  // Back from the first page entered.
  signal startWanted()

  readonly property bool open: Omunculus.conversationId !== ""
  // The pages of a conversation open, in their order.
  readonly property var inConversation: ["chat", "map", "log", "cost"]
  // The pages of a conversation: its own, and a work's thread, a page of the chat.
  readonly property var ofConversation: inConversation.concat(["thread"])
  // The level on screen: "registry", "project" or "conversation".
  property string level: "project"
  // The pages of the level on screen, in their order.
  readonly property var pages: level === "conversation" ? (open ? inConversation : ["chat"])
    : level === "registry" ? ["projects", "board"] : ["conversations", "board"]
  // The one on screen: a page, or "new", whom a new conversation is with,
  // a screen of the conversations.
  property string page: "conversations"
  readonly property int tabIndex: pages.indexOf(({ new: "conversations", work: "board", thread: "chat" })[page] || page)
  // Whether a conversation's pages are on screen, under its head and tabs.
  readonly property bool inside: level === "conversation"
  readonly property string title: page === "new" ? "new conversation" : page
  // What a page is called on its tab and the rail: the map is the team.
  function nameOf(name) { return name === "map" ? "team" : name }
  // What the masthead calls the conversation: the title of its first work
  // once it has one; before, whom it is with, never what was first said,
  // which its chat already shows.
  readonly property string named: {
    const first = Omunculus.works.find(work => !work.parent_id)
    const who = Omunculus.agent || Omunculus.lastAgent
    return first && first.title ? first.title : open && who !== "" ? "conversation with " + who : "new conversation"
  }
  // The way to the page, for the masthead, as {text, run}: on the registry
  // the page; on a project its id, which opens the projects, then the page;
  // in a conversation, then its name, which opens its chat, and on a
  // thread its work's title. A conversation's tabs name its page.
  readonly property var crumbs: {
    if (level === "registry")
      return [{ text: title }]
    const place = [{ text: Omunculus.project, run: () => view.go("projects") }]
    if (level === "project")
      return place.concat([{ text: title }])
    const subject = { text: named }
    if (page !== "chat")
      subject.run = () => view.go("chat")
    return place.concat([subject], page === "thread" ? [{ text: Omunculus.titleOf(threadWork) }] : [])
  }
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

  // Whether the conversation has said nothing yet, or is not made.
  readonly property bool fresh: Omunculus.drafting || (open && Omunculus.thread("").count === 0)

  // Where the window was before each move, the last last, as {page, level,
  // project, socket, conversation, picked, work, thread}.
  property var history: []
  // The place the start was on when a project was entered from it, to go
  // back to with the start; null when the start was on the same one.
  property var startPlace: null

  function here() {
    return { page: page, level: level, project: Omunculus.project, socket: Omunculus.socket, conversation: Omunculus.conversationId, picked: pickedNode, work: workKey, thread: threadWork }
  }
  function remember() { history = history.concat([here()]).slice(-50) }

  // Puts a page on screen, at its level: the projects on the registry's,
  // the conversations and whom a new one is with on a project's, the pages
  // of a conversation on its own; the board and a work's page on the level
  // they were reached from, a project's from a conversation.
  function show(name) {
    level = name === "projects" ? "registry"
      : ofConversation.includes(name) ? "conversation"
      : ["conversations", "new"].includes(name) || level === "conversation" ? "project"
      : level
    page = name
  }

  // Goes to a page: one of the level on screen in place of the one there,
  // another level remembering where it was.
  function go(name) {
    if (name === page)
      return
    if (!pages.includes(name))
      remember()
    show(name)
  }

  // Chooses a page of the level by its place, round from either end, and
  // gives it the keyboard.
  function choose(index) {
    go(pages[(index + pages.length) % pages.length])
    Qt.callLater(focusEntry)
  }

  // Leaves the conversation: a fresh one for the picker it began on, one
  // with something said for the list of the project's; BACK returns.
  function leave() {
    if (fresh)
      back()
    else
      go("conversations")
  }

  // Enters the pages from the start, at a page, with nothing behind it.
  function enter(name) {
    history = []
    startPlace = null
    level = Omunculus.registry ? "registry" : "project"
    show(name)
  }

  // The projects, with the chip of a state lit, "" for ALL.
  function showProjects(chip) {
    go("projects")
    projectsList.filter = chip
  }

  // Opens a project at its conversations; the conversation on screen of
  // another one closes, and BACK returns to it; `chip` lights a filter.
  function openProject(place, chip) {
    remember()
    land(place, chip)
  }

  // Enters the pages from the start at a project's conversations, with
  // nothing behind it: BACK returns to the start.
  function enterProject(place, chip) {
    history = []
    startPlace = { id: Omunculus.project, socket: Omunculus.socket }
    land(place, chip)
  }

  function land(place, chip) {
    Omunculus.switchProject(place)
    conversations.filter = chip || ""
    show("conversations")
  }

  // Asks for a project to add to the server's registry.
  function newProject() { newProjectDialog.open() }

  // Back to where the window was before its last move, or to the start. A
  // conversation that has said nothing, or is not made yet, is left for the
  // picker it began on; one that has is not returned to it. Leaving makes
  // nothing.
  function back() {
    if (!fresh)
      while (history.length > 0 && history[history.length - 1].page === "new")
        history = history.slice(0, -1)
    if (history.length === 0) {
      if (startPlace)
        Omunculus.switchProject(startPlace)
      startPlace = null
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
    level = at.level
    show(ofConversation.includes(at.page) && at.conversation === "" ? "conversations" : at.page)
    pickedNode = at.picked
    workKey = at.work
    threadWork = at.thread
  }

  // Opens a conversation at one of its pages, its chat for none.
  function openConversation(id, at) {
    remember()
    if (id !== Omunculus.conversationId)
      Omunculus.open(id)
    show(at || "chat")
  }

  // Whom a new conversation is with.
  function newConversation() {
    remember()
    Omunculus.close()
    show("new")
  }

  // The project the board was last opened on, "" on the registry's.
  property string boardLevel: ""

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
    show("work")
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
    show("map")
  }

  // Opens a work of the conversation open on its team page.
  function openInTeam(key) { openWork({ id: key, project: Omunculus.project, conversation_id: Omunculus.conversationId }) }

  // Opens the log kept to the events of a work; BACK returns.
  function showLog(work) {
    remember()
    logFilter = work
    show("log")
  }

  // Shows a work's thread as a page of its own, under the way down to it.
  function openThread(work) {
    if (work === threadWork && page === "thread")
      return
    remember()
    threadWork = work
    show("thread")
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

  // Answers what waits on you: on the team, nearest the work picked; on a
  // work's page, what it asked; elsewhere in the conversation, the newest
  // question for you, on the chat.
  function answer() {
    if (page === "map") {
      if (replyTo !== "")
        decision.show(replyTo, false)
    } else if (page === "work") {
      if (workAsks.length > 0)
        decision.show(workAsks[0].id, false)
    } else {
      go("chat")
      Qt.callLater(replyNow)
    }
  }

  // Takes the chat to the delivered result.
  function showResult() {
    go("chat")
    Qt.callLater(timeline.showResult)
  }

  // Opens or closes the progress; opened, the keyboard goes to its tree
  // when `focusing`, or always over a narrow chat, where it covers the
  // composer; closed, back to the composer. From another page of the
  // conversation it opens on the chat.
  function toggleProgress(focusing) {
    if (page !== "chat") {
      go("chat")
      progressChoice = true
      return
    }
    progressChoice = !progressShown
    if (!progressShown)
      mainComposer.focusEntry()
    else if (focusing || chat.progressMode === "sheet")
      Qt.callLater(() => { if (chat.progressArea()) chat.progressArea().focusTree() })
  }

  // Shows the oldest note to you on the chat and marks it read.
  function readNote() {
    const note = Omunculus.unread[0]
    if (!note)
      return
    go("chat")
    Qt.callLater(() => timeline.reveal(note.id))
    Omunculus.markRead(note.id)
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

  // What the team asks to be answered: what waits on you nearest the work
  // picked, else what the work asked, instead of whoever decides; "" for
  // nothing. A work's page answers what its work asked you.
  readonly property string nearest: page === "map" && team ? team.nearestForYou() : ""
  readonly property string replyTo: nearest !== "" ? nearest : asked.length > 0 ? asked[0].id : ""
  readonly property var workAsks: page === "work" ? Omunculus.asked(workKey).filter(request => Requests.human(request.arbiter)) : []

  // What the page on screen counts, at the end of its bar, as its list says it.
  readonly property string readout: page === "projects" ? projectsList.readout
    : page === "conversations" ? conversations.readout
    : page === "board" ? board.readout
    : ""

  // The commands of the page on screen, as the PageBar takes them; those with
  // a `key` answer to it too. A conversation's pages have none.
  readonly property var commands: {
    if (inside)
      return []
    const last = history.length > 0 ? history[history.length - 1] : null
    const back = { text: "BACK", role: "back", tip: "back to the " + (last ? nameOf(last.page) : "start") + "  " + Shortcuts.label("back"),
      run: () => view.back() }
    if (page === "projects")
      return [
        back,
        { text: "NEW PROJECT", short: "NEW", icon: "plus", role: "primary", tip: "add a project to the server's registry", run: () => view.newProject() }
      ]
    if (page === "conversations")
      return [
        back,
        { text: "NEW CONVERSATION", short: "NEW", icon: "plus", role: "primary", tip: "start another conversation  " + Shortcuts.label("new-conversation"),
          run: () => view.newConversation() },
        { text: "PROJECTS", icon: "folder", tip: "every project of the server  " + Shortcuts.label("projects"), run: () => view.showProjects("") }
      ]
    if (page === "board")
      return [
        back,
        { text: "BY STATE", short: "STATE", icon: "board", key: Shortcuts.chord("by-state"), group: "view", checked: board.group === "",
          tip: "the works by state alone  " + Shortcuts.label("by-state"), run: () => board.group = "" },
        { text: "BY AGENT", short: "AGENT", icon: "people", key: Shortcuts.chord("by-agent"), group: "view", checked: board.group === "agent",
          tip: "a lane per agent  " + Shortcuts.label("by-agent"), run: () => board.group = "agent" },
        { text: "BY PROJECT", short: "PROJECT", icon: "folder", key: Shortcuts.chord("by-project"), group: "view", checked: board.group === "project",
          tip: "a lane per project  " + Shortcuts.label("by-project"), run: () => board.group = "project" }
      ]
    return [back]
  }

  // The rarer actions of a conversation's page, as the masthead's ActionMenu
  // takes them, each with what it runs; those the page shows itself are not
  // repeated here.
  readonly property var more: {
    if (!inside)
      return []
    const items = []
    const add = (id, icon, text, run) => items.push({ id: id, icon: icon, text: text, run: run })
    if (page === "map" && team) {
      if (teamShownAs === "map" && team.mapAllowed)
        add("fit", "map", "FIT THE MAP", () => view.team.fit())
      if (node !== "") {
        add("write", "edit", "WRITE TO ITS AGENT", () => view.team.write(false))
        add("comment", "plus", "LEAVE A NOTE", () => view.team.write(true))
      }
    }
    if (page === "thread") {
      add("open-team", "people", "OPEN IN TEAM", () => view.openInTeam(view.threadWork))
      add("log", "list", "ITS LOG", () => view.showLog(view.threadWork))
    }
    add("new", "plus", "NEW CONVERSATION", () => view.newConversation())
    return items
  }

  // The quick chips over the chat's composer: the options of the newest
  // decision waiting on you, which decide it with the card's note — a grant
  // saved for good is chosen on its card — while its buttons are out of view,
  // then PROGRESS; none while no decision waits.
  readonly property var quick: {
    const request = Omunculus.deciding
    if (!request)
      return []
    const progress = { text: "PROGRESS", tip: (progressShown ? "close" : "open") + " the progress of the works", run: () => view.toggleProgress(true) }
    // The card's own buttons decide it; the strip opens the progress.
    if (timeline.decidingShown)
      return []
    const options = [].concat(...Requests.choices(request).map(choice => Requests.ordered(choice.options, Requests.kind(choice.request) === "permission")
      .map(option => ({
        text: Requests.optionLabel(option),
        tip: option.replace(/_/g, " ") + ", to what " + Requests.label(choice.request.requester) + " asks",
        run: () => timeline.decide(request.id, option, choice.path)
      }))))
    return options.concat([progress])
  }

  // The chords of the page that no command of its bar has: those of a work's
  // page, of a conversation's pages, its menu's and the quick chips', which a
  // field being written leaves to them. None is a bare key.
  readonly property var chords: {
    const chord = (id, run) => ({ key: Shortcuts.chord(id), run: run })
    if (page === "work")
      return [chord("reply", () => view.answer()), chord("open-team", () => view.openInTeam(view.workKey))]
    if (!inside)
      return []
    const all = [chord("reply", () => view.answer()), chord("progress", () => view.toggleProgress(true))]
    if (page === "chat" && Omunculus.unread.length > 0)
      all.push(chord("mark-read", () => view.readNote()))
    if (page === "chat" && !asking)
      quick.slice(0, Shortcuts.keys("quick").length).forEach((chip, index) => all.push({ key: Shortcuts.keys("quick")[index], run: chip.run }))
    if (page === "map" && team) {
      all.push(chord("team-log", () => view.team.showTab("log")), chord("team-changes", () => view.team.showTab("changes")))
      more.filter(item => ["write", "comment", "fit"].includes(item.id)).forEach(item => all.push(chord(item.id, item.run)))
      // The detail's menu has these too.
      if (askedOfYou.length > 0)
        all.push(chord("escalate", () => decision.show(view.askedOfYou[0].id, true)))
      if (notesHere.length > 0)
        all.push(chord("mark-read", () => view.notesHere.forEach(note => Omunculus.markRead(note.id))))
    }
    if (page === "thread")
      all.push(chord("open-team", () => view.openInTeam(view.threadWork)))
    return all
  }

  // The room a composer takes at the bottom of the page, which the toasts
  // stay above.
  readonly property real bottomRoom: page === "chat" && !asking ? mainComposer.height + gap
    : page === "thread" ? threadComposer.height + gap : 0

  // Whether the decision of a request is open over the page.
  readonly property bool dialogOpen: decision.visible || newProjectDialog.visible

  function focusEntry() {
    if (page === "projects")
      projectsList.focusEntry()
    else if (page === "conversations")
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
    else if (mainComposer.answerWaits && mainComposer.empty)
      timeline.focusCard()
    else
      mainComposer.focusEntry()
  }

  focus: active
  onActiveChanged: {
    Omunculus.watchRegistry(active)
    if (active)
      focusEntry()
  }
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
    // The board opens on the level's works, every project's on the
    // registry's, the project's own on a project's; on the same level it
    // keeps what it was kept to.
    const kept = level === "registry" ? "" : Omunculus.project
    if (page === "board" && kept !== boardLevel) {
      board.project = kept
      boardLevel = kept
    }
    Qt.callLater(focusEntry)
  }
  onAskingChanged: Qt.callLater(focusEntry)
  // A question that arrives takes the keyboard from an empty box.
  Connections {
    target: mainComposer
    function onAnswerWaitsChanged() {
      if (mainComposer.answerWaits && mainComposer.empty && view.page === "chat")
        Qt.callLater(view.focusEntry)
    }
  }
  Connections {
    target: Omunculus
    function onLoadedChanged() {
      if (Omunculus.loaded)
        Qt.callLater(view.focusEntry)
    }
    function onConversationIdChanged() {
      // The conversation's pages go with it.
      if (!view.open && view.ofConversation.includes(view.page))
        view.show("conversations")
      view.pickedNode = ""
      view.progressChoice = null
      if (view.events)
        view.events.picked = null
      Qt.callLater(view.focusEntry)
    }
  }

  // A conversation's head: its header strip and lines, and its tabs, which
  // wrap on a narrow window. Asking whom it is with, it has none yet.
  ColumnLayout {
    id: head
    anchors { left: parent.left; right: parent.right; top: parent.top }
    visible: view.inside && !view.asking
    spacing: view.gap

    ProgressStrip {
      Layout.fillWidth: true
      progress: Omunculus.progress
      lastEvent: Omunculus.lastEventAt
      waiting: Omunculus.waiting.length
      usage: Omunculus.usage.all
      heading: view.named
      expanded: view.progressShown && view.page === "chat"
      threadWorking: view.page === "chat" && timeline.working !== null
      onToggle: view.toggleProgress(false)
      onAnswer: view.answer()
      onOpenResult: view.showResult()
      onOpenTeam: view.go("map")
      onOpenCost: view.go("cost")
    }

    // Before there is more than the chat, a lone tab gives no choice.
    Flow {
      Layout.fillWidth: true
      visible: view.pages.length > 1
      spacing: Theme.space.section
      Repeater {
        model: view.inside ? view.pages : []
        delegate: Tab {
          required property string modelData
          required property int index
          label: view.nameOf(modelData)
          digit: String(index + 1).padStart(2, "0")
          current: view.tabIndex === index
          // The log says when a work failed.
          alert: modelData === "log" && !!Omunculus.progress && Omunculus.progress.state === "failed"
          onChosen: view.choose(index)
        }
      }
    }
  }

  // The page on screen, under the head while there is one.
  Item {
    id: body
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; top: head.visible ? head.bottom : parent.top; topMargin: head.visible ? view.gap : 0 }

    Stage {
      anchors.fill: parent
      shown: view.page === "projects"

      ProjectsView {
        id: projectsList
        anchors.fill: parent
        active: parent.shown && view.active
        focus: view.page === "projects"
        onOpened: place => view.openProject(place)
        onLeave: view.back()
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
        onOpened: (id, at) => view.openConversation(id, at)
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
            rightMargin: chat.docked ? Theme.space.section : 0
          }
          spacing: view.gap

          // Medium: the progress under the tabs, pushing the thread down.
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
            emptyText: Omunculus.agent ? "WITH " + Omunculus.agent.toUpperCase() : ""
            onAnswered: mainComposer.focusEntry()
            // Every form that arrives takes the keyboard from an empty box,
            // not only the first.
            onCardArrived: if (mainComposer.empty && view.page === "chat") Qt.callLater(timeline.focusCard)
            onOpenWork: work => view.openThread(work)
            onOpenLog: work => view.showLog(work)
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

          // The quick chips keep their room on a short window, not their keys.
          Composer {
            id: mainComposer
            visible: !view.asking
            Layout.fillWidth: true
            quick: view.quick
            chipsShown: !view.short
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
            progress: Omunculus.progress
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
              view.openInTeam(work)
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
        spacing: view.gap

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
          onOpenLog: work => view.showLog(work)
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
          view.show("chat")
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
          onDecide: (id, escalating) => decision.show(id, escalating)
        }
      }
      // The work picked and the view shown are kept here, so they outlive the page.
      Connections {
        target: view.team
        function onPickedChanged() { view.pickedNode = view.team.picked }
        function onShownAsChanged() { view.teamShownAs = view.team.shownAs }
      }
      // A team going away keeps its values, so nothing is written back from it.
      Binding {
        target: view.team
        property: "picked"
        value: view.pickedNode
        when: view.team !== null
        restoreMode: Binding.RestoreNone
      }
      Binding {
        target: view.team
        property: "shownAs"
        value: view.teamShownAs
        when: view.team !== null
        restoreMode: Binding.RestoreNone
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
        onAnswer: id => decision.show(id, false)
        onOpenTeam: view.openInTeam(view.workKey)
      }
    }
  }

  RequestDialog { id: decision }

  // Once a project is registered, the projects are read again and its row
  // is picked.
  NewProjectDialog {
    id: newProjectDialog
    client: Omunculus.client
    onRegistered: id => {
      Omunculus.loadProjects()
      projectsList.selected = id
    }
  }
}
