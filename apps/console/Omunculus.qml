pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "kit/client"
import "kit/client/Events.js" as Events
import "kit/client/Model.js" as Model
import "kit/client/Phrases.js" as Phrases
import "kit/client/Projects.js" as Projects
import "kit/client/Progress.js" as Progress
import "kit/client/Requests.js" as Requests
import "kit/client/Time.js" as Time
import "kit/client/Usage.js" as Usage
import "kit/ui"

// Omunculus is the server's registry and the project on screen as the window
// sees them: whether the server answers, every project's conversations,
// works and state, the project's conversations, and the one on screen folded
// into threads a person can follow. The main thread is yours with the root agent; each work handed down
// has a thread of its own, where its agent says and does what it does. A run
// at depth 0 belongs to the main thread, a deeper one to its work's, and leaves a
// line in the main thread when it ends, so that thread tells the team's work in order. Every
// read and command goes to the server's local socket through curl; the event
// stream is the conversation's WebSocket.
Singleton {
  id: root

  // The project the window is on and its socket: the one it was opened on,
  // until another is opened; none, on the registry's socket, when it was
  // opened without one.
  Project {
    id: connection
    onReached: {
      root.loadProjects()
      if (root.registry)
        return
      root.loadConversations()
      root.loadSetup()
      root.loadCapabilities()
    }
  }
  // The project's client, for what the kit asks one of.
  readonly property Project client: connection
  // Whether the window is on no project yet, only on the server's registry.
  readonly property alias registry: connection.registry
  property alias socket: connection.socket
  property alias project: connection.project
  property alias base: connection.base
  property alias connected: connection.connected
  // What the window tells, as toasts.
  readonly property Notices notices: connection.notices
  readonly property Http http: connection.http
  // The project capabilities the member holds, such as project.manage_config.
  property var capabilities: []
  property var conversations: []
  // Conversation id -> {title, running, waiting}, read from its snapshot.
  property var summaries: ({})
  property string conversationId: ""
  // The agent the conversation on screen is with: the one its first message
  // named, or the one picked for a new or an empty one; every message names it again.
  property string agent: ""
  // The agent the last message of this window went to; "" before any.
  property string lastAgent: ""
  // Whom a new conversation may be with: the agents of depth 0 not only in workflows.
  readonly property var talkable: setup ? setup.agents.filter(each => each.depth === 0 && !each.workflow_only) : []
  readonly property var conversation: conversations.find(item => item.id === conversationId) || null
  readonly property string title: conversationId === "" ? "" : (summaries[conversationId] || {}).title || "new conversation"
  // What the conversation is called: its first root work's title, else what
  // was first said in it.
  readonly property string subject: {
    const first = works.find(work => !work.parent_id)
    return first && first.title ? first.title : title
  }
  property var works: []
  property var runs: []
  property var requests: []
  property var inbox: []
  // What was typed in the main composer and not sent, by conversation id; a
  // conversation opened again gets its words back.
  property var composerDrafts: ({})
  // What was typed in the forms of requests and not sent, by request id:
  // {answers, at}, `at` the box the keyboard was in or -1; a form rebuilt
  // takes its words and the keyboard back from it.
  property var drafts: ({})
  function draftOf(key) { return drafts[key] || (drafts[key] = { answers: [], at: -1 }) }
  // The latest event cursor of the open conversation; the stream resumes after it.
  property string cursor: ""
  // While the history of the conversation opened is read in, and once it was.
  property bool replaying: false
  property bool loaded: false
  // Thread key ("" or a work id) -> its ListModel. Each entry: kind (speech,
  // turn, request or work), key, who, text, mine, stamp, at (seconds), work,
  // streaming, partial (the text its model is writing), steps (JSON), and
  // fresh: it arrived while the conversation was open, rather than with its
  // history. A turn is one run of an agent: what it said and what it did. A
  // work handed down shows, keyed by its id, in the thread of the run that
  // handed it down. A request between agents shows in the thread it was asked
  // in, keyed by its id; a request for you, and every note to you, in the
  // main thread.
  property var threads: ({})
  // Whether the first message will make the conversation: it is with an agent
  // picked and none exists on the server yet.
  readonly property bool drafting: conversationId === "" && agent !== ""
  // Whether the conversation on screen is empty and several agents could take
  // it, so the first message must say which. With one, the server names it.
  readonly property bool whomAsked: loaded && agent === "" && talkable.length > 1 && thread("").count === 0
  // Run id -> {thread, row}.
  property var rows: ({})
  // Work id -> the work it was handed down from, and run id -> its thread.
  property var parentOf: ({})
  property var runThread: ({})
  // Work id ("" for runs without one) -> the tool its agent called last.
  property var calling: ({})
  // Work id -> the args of that call.
  property var callArgs: ({})
  // Inbox id -> the text its notify event carried, and request id -> how it
  // was answered ({option, who, body}); the snapshot has neither.
  property var notes: ({})
  property var replies: ({})
  // Request id -> true for each request the harness opened, passing on a
  // question someone left unanswered; the snapshot does not say.
  property var noted: ({})
  // Request id -> the request that gathers it (from the escalate events), and
  // inbox id -> the request a harness note is about, for each note whose
  // question the person already sees as a card.
  property var gatheredBy: ({})
  property var cardNotes: ({})
  // The project's setup, as the config route gives it: {root, agents, models,
  // workspaces, workspace, workflows, ...}; null until it answers.
  property var setup: null
  // What the open conversation's model calls used, as their providers reported
  // it: {calls, input, cached, output, cost, priced}, in all, by agent and by
  // work ("" for runs without one). Shown only when asked for.
  property var usage: ({ all: Usage.tally(), agents: {}, works: {} })
  // Work id -> its tool calls: {count, failed, firstFailed, last: {text, at}},
  // `firstFailed` the tool of the first failed call, `last` the newest call or
  // outcome.
  property var callsOf: ({})
  // Request id -> how many questions it asked, for the log's sentences.
  property var questionsOf: ({})
  // Who asked each request, by request id, as the log names them.
  property var askersOf: ({})
  // Work id -> the stages it went through, as Progress.journal keeps them.
  property var journeys: ({})
  // Work id -> its title, as the events that made it gave it, before the
  // snapshot has the work.
  property var titles: ({})
  // Every event of the open conversation as a row of the log page.
  property EventLog eventLog: EventLog {}
  // Run id -> when its run started (seconds), and run id -> why it ended, when
  // it ended in an error.
  property var runStarts: ({})
  property var runErrors: ({})
  // Request id -> "sending" while its answer goes, "failed" when it did not
  // reach the server; cleared once the answer is read back.
  property var sending: ({})
  // The time of the newest event of the open conversation, in seconds.
  property real lastEventAt: 0
  // Where the conversation's works are, as Progress.build derives it; null
  // until it was first derived.
  property var progress: null
  // Now, in seconds, a second at a time while a run is open: the clocks of
  // the views count from it.
  property real tick: Date.now() / 1000

  // The registry: every project the window's socket lists, as {id, socket},
  // by id, and by project id its works, its setup as the config route gives
  // it, its conversations, and the runs open on its works (run id -> work
  // id), all kept from each project's stream while the registry is watched;
  // and the ids of those whose socket did not answer. A work on the board
  // carries its `project`.
  property var boardProjects: []
  property var boardWorks: ({})
  property var boardSetups: ({})
  property var boardConversations: ({})
  property var boardRuns: ({})
  property var unreachable: ({})
  // Whether the registry is watched, the window entered, and whether its
  // projects' streams are read, once the projects are known.
  property bool registryWanted: false
  property bool watching: false
  // Each project as a row of the projects page, in its order, and how many
  // conversations need you in the projects the window is not on.
  readonly property var projectRows: Projects.sort(Projects.rows({
    projects: boardProjects, conversations: boardConversations, works: boardWorks, summaries: summaries,
    unreachable: new Set(Object.keys(unreachable)), current: project
  }))
  readonly property int elsewhere: Projects.elsewhere(projectRows)
  readonly property var board: [].concat(...boardProjects.map(place => boardWorks[place.id] || []))
  // The works an agent runs on now, each as "project/work id".
  readonly property var boardBusy: [].concat(...Object.keys(boardRuns).map(id => Object.values(boardRuns[id]).map(work => id + "/" + work)))

  // Agent name -> its colour, in the order agents first appear in the
  // conversation on screen; the board's agents have their own, in the order
  // the window meets them.
  property var tones: ({})
  property var boardTones: ({})

  readonly property var running: runs.filter(run => run.status === "open")
  readonly property var waiting: requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter))
  readonly property var unread: inbox.filter(item => !item.read_at && !cardNotes[item.id])
  // The newest request waiting on you that offers options, none gathering
  // it from below; null for none.
  readonly property var deciding: {
    const gathered = Requests.contained(requests)
    return waiting.filter(request => !gathered.has(request.id) && Requests.choices(request).length > 0).pop() || null
  }
  // What waits on you: requests to decide and notes to read.
  readonly property int pending: waiting.length + unread.length
  // Requests still waiting, on you or on an agent.
  readonly property var asking: requests.filter(request => Requests.pending(request))

  // copy puts text on the Wayland clipboard, as it is, and says so.
  function copy(text) {
    clipboard.command = ["wl-copy", "--", text]
    clipboard.startDetached()
    connection.tell("copied", false)
  }
  Process { id: clipboard }

  // Reads the project's setup on the local socket.
  function loadSetup() {
    const on = project
    http.setup(socket, on, read => {
      if (on === project)
        setup = read
    })
  }

  function loadCapabilities() {
    const on = project
    connection.call("GET", base + "/capabilities", null, false, data => {
      if (on === project)
        capabilities = data.items
    })
  }

  // Puts back the files the work `key` changed, in the workspace it ran in;
  // `done` follows once it did; a refusal is told as a sentence.
  function revert(key, done) {
    connection.call("POST", base + "/works/" + key + "/revert", {}, true, () => {
      connection.tell("reverted", false)
      done()
    })
  }

  // Runs the tool `name` with `args` on the local socket, as the local user;
  // `done` gets its output, and `failed`, when given, why it failed.
  function command(name, args, done, failed) {
    http.command(socket, name, args, done, failed)
  }

  // The model id an agent runs on, as configured, or "" before the setup.
  function modelOf(agent) {
    if (!setup)
      return ""
    const configured = setup.agents.find(item => item.name === agent)
    const model = configured ? setup.models.find(item => item.name === configured.model) : null
    return model ? model.model || model.name : configured ? configured.model : ""
  }

  // A workspace by name, or the default one for "", as {name, root}; the
  // project root when there is none.
  function workspaceOf(name) {
    if (!setup)
      return { name: "", root: "" }
    const wanted = name || setup.workspace
    return setup.workspaces.find(item => item.name === wanted) || { name: "", root: setup.root }
  }

  function loadConversations() {
    const on = project
    connection.call("GET", base + "/conversations", null, false, data => {
      if (on !== project)
        return
      conversations = data.items.slice().sort((a, b) => b.created_at.localeCompare(a.created_at))
      summarize({ id: project, socket: socket }, conversations.map(item => item.id))
    })
  }

  // Reads each conversation's snapshot in turn, on its project's socket, for
  // its line in the history and its name on the board.
  function summarize(place, ids) {
    if (ids.length === 0)
      return
    http.call(place.socket, "GET", "/v1/projects/" + place.id + "/conversations/" + ids[0] + "/snapshot", null, false, data => {
      const next = Object.assign({}, summaries)
      next[ids[0]] = Projects.summary(data)
      summaries = next
      summarize(place, ids.slice(1))
    }, () => summarize(place, ids.slice(1)))
  }

  // What a conversation is called: what was first said in it, or when it began.
  function conversationLabel(id) {
    const said = (summaries[id] || {}).title
    const began = [].concat(conversations, ...Object.values(boardConversations)).find(item => item.id === id)
    return said || (began ? "conversation of " + Time.began(began.created_at, Date.now()) : "a conversation")
  }

  // Reads the projects of the registry, in the order of their ids; while
  // the registry is watched, each one not read yet is read in full.
  function loadProjects() {
    connection.call("GET", "/v1/projects", null, false, data => {
      const listed = data.items.slice().sort((a, b) => a.id.localeCompare(b.id))
      const read = new Set(watching ? boardProjects.map(place => place.id) : [])
      if (JSON.stringify(listed) !== JSON.stringify(boardProjects))
        boardProjects = listed
      if (!registryWanted)
        return
      listed.filter(place => !read.has(place.id)).forEach(readProject)
      watching = true
    })
  }

  // Follows every project while the window is entered, from what each
  // project's stream sends from its start.
  function watchRegistry(on) {
    registryWanted = on
    watching = false
    if (!on)
      return
    boardRuns = {}
    loadProjects()
  }

  function readProject(place) {
    loadWorks(place)
    loadBoardConversations(place, true)
    http.setup(place.socket, place.id, read => keep("boardSetups", place.id, read))
  }

  function loadWorks(place) {
    http.call(place.socket, "GET", "/v1/projects/" + place.id + "/works", null, false, data => {
      const works = data.items.map(work => Object.assign({ project: place.id }, work))
      keep("boardWorks", place.id, works)
      meet(works.map(work => agentOf(work)), true)
    }, () => {})
  }

  // Reads a project's conversations, and, with `all`, each one's summary;
  // a socket that does not answer marks its project not reachable.
  function loadBoardConversations(place, all) {
    http.call(place.socket, "GET", "/v1/projects/" + place.id + "/conversations", null, false, data => {
      keep("boardConversations", place.id, data.items)
      if (unreachable[place.id]) {
        const rest = Object.assign({}, unreachable)
        delete rest[place.id]
        unreachable = rest
      }
      if (all)
        summarize(place, data.items.map(item => item.id))
    }, () => keep("unreachable", place.id, true))
  }

  // What an event of a project's stream changes: the runs open, the
  // project's works, the summary of the conversation it is of, and, for a
  // new conversation, the project's conversations.
  function boardEvent(place, event) {
    if (event.type === "run.delta")
      return
    if (event.type === "start-run" || event.type === "end-run") {
      const runs = Object.assign({}, boardRuns[place.id] || {})
      if (event.type === "start-run")
        runs[event.run_id] = event.work_id || ""
      else
        delete runs[event.run_id]
      keep("boardRuns", place.id, runs)
    }
    if (event.type === "conversation")
      staleConversations[place.id] = place
    if (event.conversation_id)
      staleSummaries[event.conversation_id] = place
    staleWorks[place.id] = place
    boardTimer.restart()
  }
  // The projects whose works or conversations are read again, and the
  // conversations summarized again (id -> its project), once events pause.
  property var staleWorks: ({})
  property var staleConversations: ({})
  property var staleSummaries: ({})
  Timer {
    id: boardTimer
    interval: 250
    onTriggered: {
      Object.values(root.staleWorks).forEach(place => root.loadWorks(place))
      Object.values(root.staleConversations).forEach(place => root.loadBoardConversations(place, false))
      const ids = {}
      for (const [id, place] of Object.entries(root.staleSummaries))
        (ids[place.id] = ids[place.id] || { place: place, list: [] }).list.push(id)
      Object.values(ids).forEach(each => root.summarize(each.place, each.list))
      root.staleWorks = {}
      root.staleConversations = {}
      root.staleSummaries = {}
    }
  }
  Instantiator {
    model: root.watching ? root.boardProjects : []
    delegate: EventStream {
      required property var modelData
      // The cursor it resumes after.
      property string cursor: ""
      socket: modelData.socket
      path: "/v1/projects/" + modelData.id + "/stream" + (cursor !== "" ? "?after=" + cursor : "")
      onReceived: event => {
        if (event.cursor)
          cursor = event.cursor
        root.boardEvent(modelData, event)
      }
      Component.onCompleted: start()
    }
  }

  // Opens the window on another project the socket listed, as {id, socket},
  // or on none, the registry, with an empty id: the conversation on screen
  // closed, its agents going on; the project's conversations, setup and
  // capabilities are read once its socket answers.
  function switchProject(place) {
    if (place.id === project)
      return
    clear("")
    setup = null
    capabilities = []
    conversations = []
    connection.switchTo(place)
  }

  // The file of an agent's image, of the window's project or of another one
  // on the board, as a url, or "" while it has none or it is being fetched.
  function imageOf(name, place) {
    if (!place || place === project)
      return images.source(name)
    const keeper = boardImages.count > 0 ? boardImages.objectAt(boardProjects.findIndex(item => item.id === place)) : null
    return keeper ? keeper.source(name) : ""
  }
  AgentImages {
    id: images
    http: root.http
    socket: root.socket
    base: root.base
    agents: root.setup ? root.setup.agents : []
  }
  Instantiator {
    id: boardImages
    model: root.boardProjects
    delegate: AgentImages {
      required property var modelData
      http: root.http
      socket: modelData.socket
      base: "/v1/projects/" + modelData.id
      agents: (root.boardSetups[modelData.id] || { agents: [] }).agents
    }
  }

  // Leaves the conversation on screen for `id`, or for none, with nothing of it.
  function clear(id) {
    conversationId = id
    agent = ""
    loaded = false
    cursor = ""
    rows = {}
    parentOf = {}
    runThread = {}
    calling = {}
    callArgs = {}
    threads = {}
    notes = {}
    replies = {}
    noted = {}
    gatheredBy = {}
    cardNotes = {}
    drafts = {}
    tones = {}
    usage = { all: Usage.tally(), agents: {}, works: {} }
    callsOf = {}
    questionsOf = {}
    askersOf = {}
    journeys = {}
    titles = {}
    runStarts = {}
    runErrors = {}
    sending = {}
    lastEventAt = 0
    works = []
    runs = []
    requests = []
    inbox = []
    eventLog.clear()
    conversationStream.stop()
  }

  function open(id) {
    clear(id)
    // The history comes in one read, before the stream resumes after it.
    connection.call("GET", base + "/conversations/" + id + "/events", null, false, data => {
      if (id !== conversationId)
        return
      replaying = true
      data.events.forEach(handle)
      replaying = false
      loaded = true
      eventLog.flush()
      const newest = data.events[data.events.length - 1]
      if (newest)
        lastEventAt = Date.parse(newest.at) / 1000
      refresh()
      conversationStream.start()
    })
  }

  // Closes the conversation on screen; its agents go on without the window.
  function close() {
    clear("")
    loadConversations()
  }

  function refresh() {
    if (conversationId === "")
      return
    const id = conversationId
    connection.call("GET", base + "/conversations/" + id + "/snapshot", null, false, data => {
      if (id !== conversationId)
        return
      works = data.works
      runs = data.runs
      requests = data.requests
      inbox = data.inbox
      const unsettled = Object.keys(sending).filter(key => requests.some(request => request.id === key && Requests.pending(request)))
      if (unsettled.length !== Object.keys(sending).length)
        sending = Object.fromEntries(unsettled.map(key => [key, sending[key]]))
      const next = Object.assign({}, summaries)
      next[id] = Projects.summary(data)
      summaries = next
    })
  }

  // The person sent a message or answered a request: views follow the end.
  signal acted()

  // A message to the root agent, or, with a work, to that work's agent, with
  // the files at the paths `files` lists. A conversation not yet made, with
  // an agent picked, is made by its first message. `done` follows once the
  // server took it, `failed` if it did not.
  function send(text, work, files, done, failed) {
    const value = text.trim()
    const refuse = reason => {
      if (!work)
        dropPending(value)
      connection.tell("could not send: " + reason, true)
      if (failed)
        failed()
    }
    if (value === "") {
      if (failed)
        failed()
      return
    }
    if (!work)
      showPending(value)
    if (conversationId !== "")
      return deliver(value, work, files, done, refuse)
    if (agent === "")
      return refuse("no conversation is open")
    const name = agent
    connection.call("POST", base + "/conversations", {}, true, data => {
      loadConversations()
      open(data.id)
      agent = name
      if (!work)
        showPending(value)
      deliver(value, work, files, done, refuse)
    }, refuse)
  }

  function deliver(value, work, files, done, refuse) {
    acted()
    const body = { message: value }
    if (work)
      body.work_id = work
    else if (agent !== "") {
      body.agent = agent
      lastAgent = agent
    }
    http.post(socket, base + "/conversations/" + conversationId + "/messages", body, files || [], () => {
      if (done)
        done()
    }, refuse)
  }

  // Says something on the status line.
  function tell(text, isError) { connection.tell(text, isError) }

  // Saves a file attached in the conversation to the downloads directory and
  // opens it.
  function openAttachment(file) {
    http.openAttachment(socket, base + "/conversations/" + conversationId + "/attachments/" + file.sha256, file)
    connection.tell("opening " + file.name, false)
  }

  // A note on a work: context its agents read, not a new run.
  function note(text, work) {
    const value = text.trim()
    if (value === "" || !work)
      return
    connection.call("POST", base + "/conversations/" + conversationId + "/comments", { body: value, work_id: work }, true, () => connection.tell("noted", false))
  }

  // Answers a request with words and an option, of the request itself or, by
  // the parts of path, of the decision it gathers that the option is of.
  // The card shows the result, so success says nothing more.
  function reply(requestId, option, body, path) {
    keep("sending", requestId, "sending")
    acted()
    connection.call("POST", base + "/conversations/" + conversationId + "/requests/" + requestId + "/reply",
      Requests.answer(option, body, path), true, null, reason => failedSend(requestId, reason))
  }

  // Marks the answer to a request as not sent, and says why.
  function failedSend(requestId, reason) {
    keep("sending", requestId, "failed")
    connection.tell(reason, true)
  }

  // Raises a request waiting on you to whoever decides above you, as one
  // part named after its asker.
  function escalate(requestId, reason) {
    const request = requests.find(item => item.id === requestId)
    if (!request)
      return
    const origins = {}
    origins[Requests.label(request.requester)] = requestId
    keep("sending", requestId, "sending")
    acted()
    connection.call("POST", base + "/conversations/" + conversationId + "/requests/escalate",
      { reason: reason, origins: origins }, true, () => connection.tell("escalated", false),
      why => failedSend(requestId, why))
  }

  function markRead(inboxId) {
    connection.call("POST", base + "/conversations/" + conversationId + "/inbox/" + inboxId + "/read", {}, true, () => refresh())
  }

  function work(id) {
    return works.find(item => item.id === id) || null
  }

  // The workflow a work goes through, as its project's setup has it, as its
  // lane: {name, steps, at}, the stage it is at among the steps, whose agent
  // runs it; null for a work in none, or at a stage its workflow no longer
  // has.
  function laneOf(work) {
    const known = work.project && work.project !== project ? boardSetups[work.project] : setup
    const flow = known && work.workflow ? known.workflows.find(each => each.name === work.workflow) : null
    const at = flow ? flow.steps.findIndex(step => step.name === work.stage) : -1
    return at < 0 ? null : { name: flow.name, steps: flow.steps, at: at }
  }

  // The agent a work is with: its stage's in a workflow, else its assignee.
  function agentOf(work) {
    const lane = laneOf(work)
    return lane ? lane.steps[lane.at].agent : work.assignee || ""
  }

  // Whether an agent is running on the work now ("" for runs without one),
  // the requests it made that still wait, and the notes from it you have not read.
  function busy(id) { return running.some(run => (run.work_id || "") === id) }
  function asked(id) { return asking.filter(request => (request.work_id || "") === id) }
  function unreadFrom(id) { return unread.filter(item => (item.work_id || "") === id) }

  // The thread a work's runs show in: its own for a work drawn as a block in
  // the thread (handed down, or opened by a run), else the main one.
  function threadOf(work) {
    return work && (titles[work] !== undefined || parentOf[work] !== undefined || works.some(item => item.id === work && item.parent_id)) ? work : ""
  }

  // The model of a thread; an empty one until the thread has entries.
  function thread(key) {
    return threads[key] || empty
  }
  property ListModel empty: ListModel {}
  Component { id: threadModel; ListModel {} }

  // The colour of a work's state: open in the accent, done, broken, cancelled,
  // and waiting in the warning colour.
  function stateTone(state) {
    return { open: Theme.primary, done: Theme.success, cancelled: Theme.dim, broken: Theme.error }[state] || Theme.warning
  }

  function toneOf(name) {
    return name === "you" ? Theme.primary : tones[name] || boardTones[name] || Theme.dim
  }

  // Gives each agent its colour the first time it appears: in the
  // conversation on screen, or, with `board`, on the board. A conversation's
  // colours stay while it is open.
  function meet(names, board) {
    const known = board ? boardTones : tones
    const fresh = Array.from(new Set(names.filter(name => name && name !== "you" && name !== "harness" && known[name] === undefined)))
    if (fresh.length === 0)
      return
    const next = Object.assign({}, known)
    for (const name of fresh)
      next[name] = Theme.agentPalette[Object.keys(next).length % Theme.agentPalette.length]
    if (board)
      boardTones = next
    else
      tones = next
  }

  // Streamed Markdown with its open marks closed — a fence, bold, inline
  // code — or dropped when nothing follows them yet.
  function closed(text) {
    if ((text.match(/^```/gm) || []).length % 2)
      return text + "\n```"
    let shown = text.replace(/\s+$/, "")
    const open = ["**", "`"].filter(mark => shown.split(mark).length % 2 === 0)
      .map(mark => ({ mark: mark, at: shown.lastIndexOf(mark) }))
      .sort((a, b) => b.at - a.at)
    for (const left of open)
      shown = shown.slice(left.at + left.mark.length).trim() === "" ? shown.slice(0, left.at).replace(/\s+$/, "") : shown + left.mark
    return shown
  }

  // Text as Markdown should show it: without inline code marks, which would
  // set it in a larger font.
  function inline(text) {
    return text.replace(/`([^`\n]+)`/g, "$1")
  }

  // The event as a row of the log page.
  function record(event) {
    const body = event.body || {}
    if (event.type === "request" && event.request_id) {
      questionsOf[event.request_id] = Events.questions(body.reason)
      askersOf[event.request_id] = Events.party(body.requester)
    }
    const failed = event.type === "break" || (event.type === "tool" && body.ok === false && !Phrases.missed(body.name, body.output)) || (event.type === "end-run" && !!body.error)
    const who = event.type === "start-run" ? body.agent || "" : Progress.actorOf(event)
    eventLog.append({
      id: event.cursor || event.at + event.type,
      at: event.at,
      time: Time.second(event.at),
      type: event.type,
      kind: Events.kind(event.type, body),
      minor: Events.minor(event.type, body),
      who: who,
      run: event.run_id || "",
      work: event.work_id || "",
      what: Events.what(event.type, body, who, questionsOf, event.request_id, askersOf),
      ok: !failed,
      tool: event.type === "tool" && !Events.hook(body) ? body.name : event.type === "break" || event.type === "reopen" ? "break" : "",
      request: event.type === "request" && !!body.arbiter && Requests.human(body.arbiter) ? event.request_id : "",
      raw: JSON.stringify(event)
    })
  }

  function append(key, entry) {
    // Words with no text and no files draw nothing.
    if (!entry.kind && !entry.text && (entry.files || "[]") === "[]")
      return null
    if (!threads[key]) {
      const next = Object.assign({}, threads)
      next[key] = threadModel.createObject(root)
      threads = next
    }
    const model = threads[key]
    model.append(Object.assign({
      kind: "speech", key: "", who: "", text: "", mine: false, note: false, stamp: "", at: 0, work: "",
      streaming: false, partial: "", steps: "[]", files: "[]",
      fresh: !replaying, pending: false
    }, entry))
    return { thread: key, row: model.count - 1 }
  }

  // The oldest row of these words of the person's not yet echoed by the
  // server, or -1: each message sent waits for its own copy.
  function pendingRow(text) {
    const model = threads[""]
    for (let at = 0; model && at < model.count; at++) {
      const entry = model.get(at)
      if (entry.pending && entry.text === text)
        return at
    }
    return -1
  }

  // Shows the words just sent in the main thread, dim, until the server's copy
  // takes their place.
  function showPending(text) {
    if (pendingRow(text) < 0)
      append("", { who: "you", mine: true, text: text, pending: true })
  }

  function dropPending(text) {
    const at = pendingRow(text)
    if (at >= 0)
      threads[""].remove(at)
  }

  function entryAt(place) { return threads[place.thread].get(place.row) }
  function update(place, role, value) { threads[place.thread].setProperty(place.row, role, value) }

  // Whether a request is, or climbs into, one the harness opened: its
  // question reaches the person as a card.
  function isCard(id) {
    for (let at = id; at; at = gatheredBy[at])
      if (noted[at])
        return true
    return false
  }

  // Whether `id` is `top` or climbs into it.
  function climbsTo(id, top) {
    for (let at = id; at; at = gatheredBy[at])
      if (at === top)
        return true
    return false
  }

  function keep(map, key, value) {
    const next = Object.assign({}, root[map])
    next[key] = value
    root[map] = next
  }

  // How long ago a stamp was, as of `now` in milliseconds: now, 5m, 3h, 2d.
  function ago(stamp, now) {
    const seconds = Math.max(0, (now - Date.parse(stamp)) / 1000)
    return seconds < 60 ? "now" : seconds < 3600 ? Math.floor(seconds / 60) + "m" : seconds < 86400 ? Math.floor(seconds / 3600) + "h" : Math.floor(seconds / 86400) + "d"
  }

  // A sum of money as the provider reported it, in US dollars.
  function money(spent) {
    return "US$ " + (spent < 0.01 ? spent.toFixed(4) : spent.toFixed(2))
  }

  // A count of tokens, in thousands from a thousand and millions from a
  // million: 950, 12k, 5.7M.
  function tokens(count) {
    return count >= 1e6 ? (count / 1e6).toFixed(1) + "M" : count >= 1000 ? Math.round(count / 1000) + "k" : String(count)
  }

  // Adds one model call's reported usage to the conversation's, its agent's
  // and its work's.
  function count(who, work, reported) {
    const next = { all: Object.assign({}, usage.all), agents: Object.assign({}, usage.agents), works: Object.assign({}, usage.works) }
    next.agents[who] = Object.assign(Usage.tally(), next.agents[who] || {})
    next.works[work] = Object.assign(Usage.tally(), next.works[work] || {})
    Usage.add(next.all, reported)
    Usage.add(next.agents[who], reported)
    Usage.add(next.works[work], reported)
    usage = next
  }

  // Adds a line to the turn of the run it happened in, and makes it the
  // newest thing done on its work; a call is counted too.
  function step(runId, work, line) {
    const was = callsOf[work] || { count: 0, failed: 0, firstFailed: "", firstArgs: {}, firstError: "", open: {}, retried: 0, last: null }
    const call = !line.outcome && !line.hook
    const fails = call && !line.ok
    // A later success of the same tool settles its earlier failures as retried.
    const open = Object.assign({}, was.open)
    let retried = was.retried
    if (call && line.ok && open[line.name]) {
      retried += open[line.name]
      delete open[line.name]
    }
    if (fails)
      open[line.name] = (open[line.name] || 0) + 1
    keep("callsOf", work, {
      firstFailed: was.firstFailed || (fails ? line.name : ""),
      firstArgs: was.firstFailed ? was.firstArgs : fails ? line.args : {},
      firstError: was.firstFailed ? was.firstError : fails ? Events.reason(line.name, line.output) : "",
      count: was.count + (call ? 1 : 0),
      failed: was.failed + (fails ? 1 : 0),
      open: open,
      retried: retried,
      last: line.hook ? was.last : { text: line.outcome ? line.text : (line.name + "  " + Phrases.brief(line.name, line.args)).trim(), at: line.at }
    })
    const place = rows[runId]
    if (place === undefined)
      return
    const steps = JSON.parse(entryAt(place).steps)
    steps.push(line)
    update(place, "steps", JSON.stringify(steps))
  }

  // What a work made by an event is called, by its id.
  function titleOf(id) {
    const known = work(id)
    return known && known.title ? known.title : titles[id] || "the work"
  }

  // Adds what was said, and the files attached with it, to the turn of its
  // run, or as a line of its own in `key`.
  function say(key, runId, who, said, stamp, at, files) {
    const place = rows[runId]
    if (place === undefined) {
      append(key, { who: who, mine: who === "you", text: said, stamp: stamp, at: at, files: JSON.stringify(files || []) })
      return
    }
    const entry = entryAt(place)
    if (said !== "")
      update(place, "text", entry.text === "" ? said : entry.text + "\n\n" + said)
    if (files && files.length > 0)
      update(place, "files", JSON.stringify(JSON.parse(entry.files).concat(files)))
  }

  function handle(event) {
    if (event.type === "run.delta") {
      const place = rows[event.run_id]
      if (place !== undefined)
        update(place, "partial", entryAt(place).partial + event.text)
      return
    }
    if (event.cursor)
      cursor = event.cursor
    record(event)
    const next = Progress.journal(journeys, event)
    if (next !== journeys)
      journeys = next
    const body = event.body || {}
    const who = Progress.actorOf(event)
    const stamp = Time.clock(event.at, Date.now())
    const at = Date.parse(event.at) / 1000
    const work = event.work_id || ""
    if (event.type === "delegate" && work)
      keep("parentOf", work, body.parent_id || "")
    // A work made by a run: handed down, or a root one the run opened.
    const made = work !== "" && (event.type === "delegate" || (event.type === "work" && !!event.run_id && typeof body.title === "string"))
    if (made)
      keep("titles", work, body.title || "")
    if (event.type === "start-run") {
      keep("runThread", event.run_id, threadOf(work))
      keep("runStarts", event.run_id, at)
      // A new run has made no call yet, on a work or the front agent's own.
      keep("calling", work, "")
      keep("callArgs", work, {})
    }
    // Where the event shows: its run's thread, else its work's.
    const key = runThread[event.run_id] !== undefined ? runThread[event.run_id] : threadOf(work)
    meet([who, body.agent])
    switch (event.type) {
    case "prompt":
      if (agent === "" && body.agent)
        agent = body.agent
      const waiting = key === "" ? pendingRow(body.message || "") : -1
      if (waiting >= 0) {
        // The server's copy takes the place of the words shown while sending.
        threads[""].set(waiting, { stamp: stamp, at: at, files: JSON.stringify(body.attachments || []), pending: false })
      } else {
        append(key, { who: "you", mine: true, text: body.message || "", stamp: stamp, at: at, files: JSON.stringify(body.attachments || []) })
      }
      break
    case "attach":
      say(key, event.run_id, who, String(body.note || ""), stamp, at, body.attachments || [])
      break
    case "comment":
      if (body.body) {
        say(key, event.run_id, who, body.body, stamp, at)
        // News on a root work shows in the main thread too, where the person looks.
        if (key !== "" && key === work && !parentOf[work] && !works.some(item => item.id === work && item.parent_id))
          append("", { kind: "note", who: who, text: body.body, stamp: stamp, at: at, work: work })
      }
      break
    case "model": {
      if (body.usage)
        count(who, work, body.usage)
      const said = Model.text(body)
      const place = rows[event.run_id]
      if (place !== undefined)
        update(place, "partial", "")
      if (said !== "")
        say(key, event.run_id, who, said, stamp, at)
      break
    }
    case "start-run":
      keep("rows", event.run_id, append(key, { kind: "turn", key: event.run_id, who: body.agent, work: work, streaming: true, stamp: stamp, at: at }))
      break
    case "end-run": {
      if (body.error)
        keep("runErrors", event.run_id, String(body.error))
      const place = rows[event.run_id]
      if (place !== undefined) {
        update(place, "streaming", false)
        update(place, "partial", "")
        // A run below leaves a line in the main thread, so it tells the
        // team's work in order: who worked, how long and how many steps.
        if (place.thread !== "") {
          const ran = entryAt(place)
          const calls = JSON.parse(ran.steps).filter(line => !line.outcome && !line.hook).length
          append("", { kind: "worked", key: event.run_id, who: ran.who, text: Progress.worked(at - (runStarts[event.run_id] || at), calls, !!body.error), stamp: stamp, at: at, work: work })
        }
        // A run of the thread's own that failed says so in it, with why.
        else if (body.error)
          append("", { kind: "worked", key: event.run_id + ":failed", who: entryAt(place).who, text: "failed: " + String(body.error), stamp: stamp, at: at, work: work })
      }
      break
    }
    case "tool": {
      // The prompt and the end have entries of their own; the turn folds the
      // hooks that passed.
      const hook = Events.hook(body)
      // The person's own calls (a reply, a read) are no agent's work.
      if (who !== "you" && !["assemble", "send", "end"].includes(body.name)) {
        step(event.run_id, work, { name: body.name, ok: body.ok !== false || Phrases.missed(body.name, body.output), text: "", args: body.args || {}, output: body.ok === false ? String(body.output || "") : "", outcome: false, hook: hook, at: at })
        if (!hook) {
          keep("calling", work, body.name)
          keep("callArgs", work, body.args || {})
        }
      }
      break
    }
    case "continue":
      step(event.run_id, work, { name: "continue", ok: true, text: body.to ? "moved on to " + body.to : "finished the work", output: "", outcome: true, at: at })
      break
    case "grant":
      step(event.run_id, work, { name: "grant", ok: true, text: "granted " + body.name + (body.scope ? " for the " + body.scope : " for this work"), output: "", outcome: true, at: at })
      break
    case "reopen":
      step(event.run_id, work, { name: "reopen", ok: true, text: "sent \"" + titleOf(work) + "\" back to " + (body.stage || "its stage"), output: "", outcome: true, at: at })
      break
    case "break":
      step(event.run_id, work, { name: "break", ok: true, text: "stopped: " + String(body.body || "").split("\n")[0].trim(), output: "", outcome: true, at: at })
      break
    case "delegate":
    case "work":
      if (made)
        append(key, { kind: "work", key: work, who: who, stamp: stamp, at: at, work: work })
      break
    case "request":
      if (Requests.byHarness(event))
        keep("noted", event.request_id, true)
      append(!body.arbiter || Requests.human(body.arbiter) ? "" : key, { kind: "request", key: event.request_id, who: who, stamp: stamp, at: at, work: work })
      break
    case "escalate":
      Object.values(body.origins || {}).forEach(origin => keep("gatheredBy", origin, event.request_id))
      break
    case "reply":
      keep("replies", event.request_id, { option: Requests.chosen(body), who: who, body: body.body || "", stamp: stamp })
      if (!replaying)
        Object.keys(cardNotes).filter(id => climbsTo(cardNotes[id], event.request_id)).filter(id => inbox.some(item => item.id === id && !item.read_at)).forEach(id => markRead(id))
      if (sending[event.request_id] !== undefined) {
        const rest = Object.assign({}, sending)
        delete rest[event.request_id]
        sending = rest
      }
      break
    case "notify":
      // A note about a question already on a card says nothing new.
      if (event.inbox_id && who === "harness" && isCard(event.request_id)) {
        keep("cardNotes", event.inbox_id, event.request_id)
        break
      }
      if (event.inbox_id)
        keep("notes", event.inbox_id, body.body || "")
      // A note the harness left is no one's words.
      append("", { key: event.inbox_id || "", who: who, note: who === "harness", text: body.body || "", stamp: stamp, at: at, work: work })
      break
    }
    if (!replaying) {
      lastEventAt = at
      refreshTimer.restart()
    }
  }

  // The open conversation's events, after the last one read.
  EventStream {
    id: conversationStream
    socket: root.socket
    path: root.base + "/conversations/" + root.conversationId + "/stream" + (root.cursor !== "" ? "?after=" + root.cursor : "")
    onReceived: event => root.handle(event)
  }

  // Derives where the works are from the state, soon after it changes; the
  // clocks move with `tick` in between.
  function recompute() {
    progressTimer.stop()
    tick = Date.now() / 1000
    const lanes = {}
    for (const item of works)
      lanes[item.id] = laneOf(item)
    progress = Progress.build({
      runs: runs.map(run => runErrors[run.id] ? Object.assign({}, run, { error: runErrors[run.id] }) : run),
      works: works, requests: requests, noted: noted, replies: replies, lanes: lanes, calling: calling, callArgs: callArgs, runStarts: runStarts,
      journeys: journeys, rootAgent: agent || lastAgent, now: tick, usage: usage.works, calls: callsOf
    })
  }
  onWorksChanged: progressTimer.restart()
  onRunsChanged: progressTimer.restart()
  onRequestsChanged: progressTimer.restart()
  onNotedChanged: progressTimer.restart()
  onCallingChanged: progressTimer.restart()
  onRunStartsChanged: progressTimer.restart()
  onRunErrorsChanged: progressTimer.restart()
  onSetupChanged: progressTimer.restart()
  onJourneysChanged: progressTimer.restart()
  onUsageChanged: progressTimer.restart()
  onCallsOfChanged: progressTimer.restart()
  onAgentChanged: progressTimer.restart()
  Timer {
    id: progressTimer
    interval: 50
    onTriggered: root.recompute()
  }
  Timer {
    interval: 1000
    repeat: true
    running: root.running.length > 0 || (!!root.progress && !!root.progress.focus && !Progress.closed(root.progress.focus.state))
    onTriggered: root.tick = Date.now() / 1000
  }

  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: root.refresh()
  }
}
