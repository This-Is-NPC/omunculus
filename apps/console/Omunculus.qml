pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "kit/client"
import "kit/client/Model.js" as Model
import "kit/client/Requests.js" as Requests
import "kit/ui"

// Omunculus is the project as the window sees it: whether the server answers,
// its conversations, and the one on screen folded into threads a person can
// follow. The main thread is yours with the root agent; each work handed down
// has a thread of its own, where its agent says and does what it does. A run
// at depth 0 belongs to the main thread, a deeper one to its work's. Every
// read and command goes to the server's local socket through curl; the event
// stream is the conversation's WebSocket.
Singleton {
  id: root

  // The project the window is on and its socket: the one it was opened on,
  // until a card of another project's is opened on the board.
  Project {
    id: client
    onReached: {
      root.loadConversations()
      root.loadSetup()
      root.loadCapabilities()
    }
  }
  property alias socket: client.socket
  property alias project: client.project
  property alias base: client.base
  property alias connected: client.connected
  property alias message: client.message
  property alias messageIsError: client.messageIsError
  property alias noticeCount: client.noticeCount
  readonly property Http http: client.http
  // The project capabilities the member holds, such as project.manage_config.
  property var capabilities: []
  property var conversations: []
  // Conversation id -> {title, running, waiting}, read from its snapshot.
  property var summaries: ({})
  property string conversationId: ""
  // The agent the conversation on screen is with: the one its first message
  // named, or the one picked for a new or an empty one; every message names it again.
  property string agent: ""
  // Whom a new conversation may be with: the agents of depth 0 not only in workflows.
  readonly property var talkable: setup ? setup.agents.filter(each => each.depth === 0 && !each.workflow_only) : []
  readonly property var conversation: conversations.find(item => item.id === conversationId) || null
  readonly property string title: conversationId === "" ? "" : (summaries[conversationId] || {}).title || "new conversation"
  property var works: []
  property var runs: []
  property var requests: []
  property var inbox: []
  // The latest event cursor of the open conversation; the stream resumes after it.
  property string cursor: ""
  // While the history of the conversation opened is read in, and once it was.
  property bool replaying: false
  property bool loaded: false
  // Thread key ("" or a work id) -> its ListModel. Each entry: kind (speech,
  // turn or request), key, who, text, mine, stamp, at (seconds), work,
  // streaming, partial (the text its model is writing), steps (JSON), and
  // fresh: it arrived while the conversation was open, rather than with its
  // history. A turn is one run of an agent: what it said and what it did.
  // Every request and every note to you also shows in the main thread, where
  // it was made, keyed by its request or inbox id.
  property var threads: ({})
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
  // Inbox id -> the text its notify event carried, and request id -> how it
  // was answered ({option, who, body}); the snapshot has neither.
  property var notes: ({})
  property var replies: ({})
  // Request id -> true for each request the harness opened, passing on a
  // question someone left unanswered; the snapshot does not say.
  property var noted: ({})
  // The project's setup, as the config route gives it: {root, agents, models,
  // workspaces, workspace, workflows, ...}; null until it answers.
  property var setup: null
  // What the open conversation's model calls used, as their providers reported
  // it: {calls, input, cached, output, cost, priced}, in all and by agent. Shown
  // only when asked for.
  property var usage: ({ all: tally(), agents: {} })
  // Every event of the open conversation, oldest first, as a line of its log:
  // {id, at, time, type, who, run, work, what, event}.
  property var log: []
  // The lines of the history while it is read in, given to `log` at once.
  property var logBuffer: []

  // The board: every project the window's socket lists, as {id, socket},
  // and by project id its works, its setup as the config route gives it,
  // its conversations, and the runs open on its works (run id -> work id),
  // all kept from each project's stream while the board is watched. A work
  // on the board carries its `project`.
  property var boardProjects: []
  property var boardWorks: ({})
  property var boardSetups: ({})
  property var boardConversations: ({})
  property var boardRuns: ({})
  // Whether the board is on screen, and whether its projects' streams are
  // read, once the projects are known.
  property bool boardWanted: false
  property bool watching: false
  readonly property var board: [].concat(...boardProjects.map(place => boardWorks[place.id] || []))
  // The works an agent runs on now, each as "project/work id".
  readonly property var boardBusy: [].concat(...Object.keys(boardRuns).map(id => Object.values(boardRuns[id]).map(work => id + "/" + work)))

  // Agent name -> its colour, in the order agents first appear.
  property var tones: ({})

  readonly property var running: runs.filter(run => run.status === "open")
  readonly property var waiting: requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter))
  readonly property var unread: inbox.filter(item => !item.read_at)
  // What waits on you: requests to decide and notes to read.
  readonly property int pending: waiting.length + unread.length
  // Requests still waiting, on you or on an agent.
  readonly property var asking: requests.filter(request => Requests.pending(request))

  // copy puts text on the Wayland clipboard, as it is, and says so.
  function copy(text) {
    clipboard.command = ["wl-copy", "--", text]
    clipboard.startDetached()
    client.tell("copied", false)
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
    client.call("GET", base + "/capabilities", null, false, data => {
      if (on === project)
        capabilities = data.items
    })
  }

  // Puts back the files the work `key` changed, in the workspace it ran in;
  // `done` follows once it did; a refusal is told as a sentence.
  function revert(key, done) {
    client.call("POST", base + "/works/" + key + "/revert", {}, true, () => {
      client.tell("reverted", false)
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
    client.call("GET", base + "/conversations", null, false, data => {
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
      next[ids[0]] = summary(data)
      summaries = next
      summarize(place, ids.slice(1))
    }, () => summarize(place, ids.slice(1)))
  }

  function summary(data) {
    const said = data.prompts.find(prompt => prompt.kind === "message")
    return {
      title: said ? String(said.body).replace(/\s+/g, " ") : "",
      running: data.runs.filter(run => run.status === "open").length,
      waiting: data.requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter)).length
    }
  }

  // What a conversation is called: what was first said in it, or when it began.
  function conversationLabel(id) {
    const said = (summaries[id] || {}).title
    const began = [].concat(conversations, ...Object.values(boardConversations)).find(item => item.id === id)
    return said || (began ? "conversation of " + Qt.formatDateTime(new Date(began.created_at), "dd MMM hh:mm") : "a conversation")
  }

  // Follows every project's works while the board is on screen, from what
  // each project's stream sends from its start.
  function watchBoard(on) {
    boardWanted = on
    watching = false
    if (!on)
      return
    boardRuns = {}
    client.call("GET", "/v1/projects", null, false, data => {
      if (!boardWanted)
        return
      boardProjects = data.items
      for (const place of data.items) {
        loadWorks(place)
        loadBoardConversations(place)
        http.setup(place.socket, place.id, read => keep("boardSetups", place.id, read))
      }
      watching = true
    })
  }

  function loadWorks(place) {
    http.call(place.socket, "GET", "/v1/projects/" + place.id + "/works", null, false, data => {
      const works = data.items.map(work => Object.assign({ project: place.id }, work))
      keep("boardWorks", place.id, works)
      meet(works.map(work => agentOf(work)))
    })
  }

  function loadBoardConversations(place) {
    http.call(place.socket, "GET", "/v1/projects/" + place.id + "/conversations", null, false, data => {
      keep("boardConversations", place.id, data.items)
      summarize(place, data.items.map(item => item.id))
    })
  }

  // What an event of a project's stream changes on the board: the runs open,
  // the project's works, and, for a new conversation or what was first said
  // in one, the project's conversations.
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
    if (event.type === "conversation" || event.type === "prompt")
      staleConversations[place.id] = place
    staleWorks[place.id] = place
    boardTimer.restart()
  }
  // The projects whose works or conversations are read again once events
  // pause.
  property var staleWorks: ({})
  property var staleConversations: ({})
  Timer {
    id: boardTimer
    interval: 250
    onTriggered: {
      Object.values(root.staleWorks).forEach(place => root.loadWorks(place))
      Object.values(root.staleConversations).forEach(place => root.loadBoardConversations(place))
      root.staleWorks = {}
      root.staleConversations = {}
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

  // Opens the window on another project the socket listed, as {id, socket}:
  // its conversations and its setup, the conversation on screen closed.
  function switchProject(place) {
    if (place.id === project)
      return
    close()
    project = place.id
    socket = place.socket
    setup = null
    capabilities = []
    conversations = []
    loadConversations()
    loadSetup()
    loadCapabilities()
  }

  // A new conversation with the agent `name`, open once the server made it;
  // `opened` follows.
  function createConversation(name, opened) {
    client.call("POST", base + "/conversations", {}, true, data => {
      loadConversations()
      open(data.id)
      agent = name
      opened()
    })
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

  function open(id) {
    conversationId = id
    agent = ""
    loaded = false
    cursor = ""
    rows = {}
    parentOf = {}
    runThread = {}
    calling = {}
    threads = {}
    notes = {}
    replies = {}
    noted = {}
    tones = {}
    usage = { all: tally(), agents: {} }
    works = []
    runs = []
    requests = []
    inbox = []
    log = []
    logBuffer = []
    conversationStream.stop()
    // The history comes in one read, before the stream resumes after it.
    client.call("GET", base + "/conversations/" + id + "/events", null, false, data => {
      if (id !== conversationId)
        return
      replaying = true
      data.events.forEach(handle)
      replaying = false
      loaded = true
      log = logBuffer
      logBuffer = []
      refresh()
      conversationStream.start()
    })
  }

  // Closes the conversation on screen; its agents go on without the window.
  function close() {
    conversationId = ""
    loaded = false
    conversationStream.stop()
    threads = {}
    loadConversations()
  }

  function refresh() {
    if (conversationId === "")
      return
    const id = conversationId
    client.call("GET", base + "/conversations/" + id + "/snapshot", null, false, data => {
      if (id !== conversationId)
        return
      works = data.works
      runs = data.runs
      requests = data.requests
      inbox = data.inbox
      meet(works.map(work => work.assignee))
      const next = Object.assign({}, summaries)
      next[id] = summary(data)
      summaries = next
    })
  }

  // A message to the root agent, or, with a work, to that work's agent, with
  // the files at the paths `files` lists.
  function send(text, work, files) {
    const value = text.trim()
    if (value === "" || conversationId === "")
      return
    const body = { message: value }
    if (work)
      body.work_id = work
    else if (agent !== "")
      body.agent = agent
    http.post(socket, base + "/conversations/" + conversationId + "/messages", body, files, () => {})
  }

  // Saves a file attached in the conversation to the downloads directory and
  // opens it.
  function openAttachment(file) {
    http.openAttachment(socket, base + "/conversations/" + conversationId + "/attachments/" + file.sha256, file)
    client.tell("opening " + file.name, false)
  }

  // A note on a work: context its agents read, not a new run.
  function note(text, work) {
    const value = text.trim()
    if (value === "" || !work)
      return
    client.call("POST", base + "/conversations/" + conversationId + "/comments", { body: value, work_id: work }, true, () => client.tell("noted", false))
  }

  // Answers a request with words and an option, of the request itself or, by
  // the parts of path, of the decision it gathers that the option is of.
  function reply(requestId, option, body, path) {
    client.call("POST", base + "/conversations/" + conversationId + "/requests/" + requestId + "/reply",
      Requests.answer(option, body, path), true, () => client.tell(option ? "replied " + option : "replied", false))
  }

  // Raises a request waiting on you to whoever decides above you, as one
  // part named after its asker.
  function escalate(requestId, reason) {
    const request = requests.find(item => item.id === requestId)
    if (!request)
      return
    const origins = {}
    origins[Requests.label(request.requester)] = requestId
    client.call("POST", base + "/conversations/" + conversationId + "/requests/escalate",
      { reason: reason, origins: origins }, true, () => client.tell("escalated", false))
  }

  function markRead(inboxId) {
    client.call("POST", base + "/conversations/" + conversationId + "/inbox/" + inboxId + "/read", {}, true, () => refresh())
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

  // The works under `id` in tree order, each with its depth below it; `id`
  // itself first when `self`, and "" for every work of the conversation.
  function tree(id, self) {
    const ordered = []
    const visit = (parent, level) => works
      .filter(item => (item.parent_id || "") === parent)
      .forEach(item => { ordered.push({ work: item, level: level }); visit(item.id, level + 1) })
    const top = self ? work(id) : null
    if (top)
      ordered.push({ work: top, level: 0 })
    visit(id, top ? 1 : 0)
    return ordered
  }

  // Whether an agent is running on the work now ("" for runs without one),
  // the requests it made that still wait, and the notes from it you have not read.
  function busy(id) { return running.some(run => (run.work_id || "") === id) }
  function asked(id) { return asking.filter(request => (request.work_id || "") === id) }
  function unreadFrom(id) { return unread.filter(item => (item.work_id || "") === id) }

  // The thread a work's runs show in: its own for a work handed down, the
  // main one for a work the root agent opened for itself.
  function threadOf(work) {
    return work && (parentOf[work] !== undefined || works.some(item => item.id === work && item.parent_id)) ? work : ""
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
    return name === "you" ? Theme.primary : tones[name] || Theme.dim
  }

  // Gives each agent its colour the first time the window meets it.
  function meet(names) {
    const fresh = names.filter(name => name && name !== "you" && name !== "harness" && tones[name] === undefined)
    if (fresh.length === 0)
      return
    const next = Object.assign({}, tones)
    for (const name of fresh)
      next[name] = Theme.agentPalette[Object.keys(next).length % Theme.agentPalette.length]
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

  function brief(args) {
    const parts = Object.keys(args || {}).map(key => {
      const value = typeof args[key] === "string" ? args[key] : JSON.stringify(args[key])
      return key + ": " + value
    })
    const line = parts.join("  ·  ").replace(/\s+/g, " ")
    return line.length > 120 ? line.slice(0, 117) + "..." : line
  }

  // The event as a line of the log; while the history is read in, kept aside.
  function record(event) {
    const body = event.body || {}
    const line = {
      id: event.cursor || event.at + event.type,
      at: event.at,
      time: event.at.slice(11, 23),
      type: event.type,
      who: event.type === "start-run" ? body.agent || "" : actorName(event.actor),
      run: event.run_id || "",
      work: event.work_id || "",
      what: what(event.type, body),
      event: event
    }
    if (replaying)
      logBuffer.push(line)
    else
      log = log.concat([line])
  }

  // What an event says, on one line.
  function what(type, body) {
    const line = value => String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").trim()
    const json = value => line(JSON.stringify(value))
    switch (type) {
    case "prompt":
      return line(body.message)
    case "comment":
      return line(body.body)
    case "model":
      return line(Model.text(body)) || json(body)
    case "tool":
      return (body.via ? body.via + " → " : "") + body.name + " " + json(body.args || {}) + (body.ok ? "  ok" : "  failed")
        + (body.output ? "  ·  " + (typeof body.output === "string" ? line(body.output) : json(body.output)) : "")
    case "start-run":
      return (body.agent || "") + (body.depth !== undefined ? " at depth " + body.depth : "") + (body.via ? " via " + body.via : "")
    case "end-run":
      return ""
    default:
      return json(body)
    }
  }

  // Who an event's actor is: an agent by its name, the harness as "harness",
  // and any person as you.
  function actorName(actor) {
    if (!actor)
      return ""
    return actor.kind === "agent" ? actor.id : actor.kind === "harness" ? "harness" : "you"
  }

  function append(key, entry) {
    if (!threads[key]) {
      const next = Object.assign({}, threads)
      next[key] = threadModel.createObject(root)
      threads = next
    }
    const model = threads[key]
    model.append(Object.assign({
      kind: "speech", key: "", who: "", text: "", mine: false, note: false, stamp: "", at: 0, work: "",
      streaming: false, partial: "", steps: "[]", files: "[]",
      fresh: !replaying
    }, entry))
    return { thread: key, row: model.count - 1 }
  }

  function entryAt(place) { return threads[place.thread].get(place.row) }
  function update(place, role, value) { threads[place.thread].setProperty(place.row, role, value) }

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

  function tally() {
    return { calls: 0, input: 0, cached: 0, output: 0, cost: 0, priced: 0 }
  }

  // Adds one model call's reported usage to the conversation's and its agent's.
  function count(who, reported) {
    const add = into => {
      into.calls++
      into.input += reported.prompt_tokens || reported.input_tokens || 0
      into.cached += (reported.prompt_tokens_details || reported.input_tokens_details || {}).cached_tokens || 0
      into.output += reported.completion_tokens || reported.output_tokens || 0
      if (typeof reported.cost === "number") {
        into.cost += reported.cost
        into.priced++
      }
    }
    const next = { all: Object.assign({}, usage.all), agents: Object.assign({}, usage.agents) }
    next.agents[who] = Object.assign(tally(), next.agents[who] || {})
    add(next.all)
    add(next.agents[who])
    usage = next
  }

  // Adds a line to the turn of the run it happened in.
  function step(runId, line) {
    const place = rows[runId]
    if (place === undefined)
      return
    const steps = JSON.parse(entryAt(place).steps)
    steps.push(line)
    update(place, "steps", JSON.stringify(steps))
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
    const body = event.body || {}
    const who = actorName(event.actor)
    const stamp = event.at.slice(11, 16)
    const at = Date.parse(event.at) / 1000
    const work = event.work_id || ""
    if (event.type === "delegate" && work)
      keep("parentOf", work, body.parent_id || "")
    if (event.type === "start-run")
      keep("runThread", event.run_id, Number(body.depth) > 0 && work ? work : "")
    // Where the event shows: its run's thread, else its work's.
    const key = runThread[event.run_id] !== undefined ? runThread[event.run_id] : threadOf(work)
    meet([who, body.agent])
    switch (event.type) {
    case "prompt":
      if (agent === "" && body.agent)
        agent = body.agent
      append(key, { who: "you", mine: true, text: body.message || "", stamp: stamp, at: at, files: JSON.stringify(body.attachments || []) })
      break
    case "attach":
      say(key, event.run_id, who, String(body.note || ""), stamp, at, body.attachments || [])
      break
    case "comment":
      if (body.body)
        say(key, event.run_id, who, body.body, stamp, at)
      break
    case "model": {
      if (body.usage)
        count(who, body.usage)
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
      const place = rows[event.run_id]
      if (place !== undefined) {
        update(place, "streaming", false)
        update(place, "partial", "")
      }
      break
    }
    case "tool": {
      // The prompt, the end and the chained steps have entries of their own;
      // a hook, called with the event alone, shows only when it fails.
      const hook = body.args && typeof body.args.event === "object" && Object.keys(body.args).length === 1
      if (!["assemble", "send", "end"].includes(body.name) && !body.via && !(hook && body.ok !== false)) {
        step(event.run_id, { name: body.name, ok: body.ok !== false, text: hook ? "" : brief(body.args), output: body.ok === false ? String(body.output || "") : "", outcome: false })
        keep("calling", work, body.name)
      }
      break
    }
    case "continue":
      step(event.run_id, { name: "continue", ok: true, text: body.to ? "moved the work to " + body.to : "closed the work", output: "", outcome: true })
      break
    case "grant":
      step(event.run_id, { name: "grant", ok: true, text: "granted " + body.name + (body.scope ? " for the " + body.scope : " for this work"), output: "", outcome: true })
      break
    case "request":
      if (Requests.byHarness(event))
        keep("noted", event.request_id, true)
      append("", { kind: "request", key: event.request_id, who: who, stamp: stamp, at: at, work: work })
      break
    case "reply":
      keep("replies", event.request_id, { option: Requests.chosen(body), who: who, body: body.body || "" })
      break
    case "notify":
      if (event.inbox_id)
        keep("notes", event.inbox_id, body.body || "")
      // A note the harness left is no one's words.
      append("", { key: event.inbox_id || "", who: who, note: who === "harness", text: body.body || "", stamp: stamp, at: at, work: work })
      break
    }
    if (!replaying)
      refreshTimer.restart()
  }

  // The open conversation's events, after the last one read.
  EventStream {
    id: conversationStream
    socket: root.socket
    path: root.base + "/conversations/" + root.conversationId + "/stream" + (root.cursor !== "" ? "?after=" + root.cursor : "")
    onReceived: event => root.handle(event)
  }

  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: root.refresh()
  }
}
