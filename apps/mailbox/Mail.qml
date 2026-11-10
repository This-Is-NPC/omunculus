pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "kit/client"
import "kit/client/Model.js" as Model
import "kit/client/Questions.js" as Questions
import "kit/client/Requests.js" as Requests
import "kit/ui"

// Mail is every project of the server as the mailbox sees it. A thread is a
// conversation with one agent of depth 0: what you write goes to that agent,
// and what it says comes back. Its questions and approvals for you, the
// requests whose arbiter you are, show in the thread too. Every read and
// command goes to a project's local socket through curl.
Singleton {
  id: root

  // The socket the mailbox was opened on; it lists every project.
  readonly property string socket: Quickshell.env("OMUNCULUS_SOCKET")

  property bool connected: false
  // You, as the server knows you: {issuer, subject}.
  property var me: null
  // Every project, as {id, socket, agents}: the agents of depth 0 a thread
  // can be with.
  property var projects: []
  // Project id -> every agent of its config, as the config route lists them:
  // the agents whose pictures and colours the threads show.
  property var rosters: ({})
  // "project/conversation" -> its thread: {key, project, id, agent, subject,
  // working, waiting, status, at, heard, snippet, entries}.
  property var threads: ({})
  // A thread with nothing in it, for a view whose thread has just gone.
  readonly property var blank: ({ key: "", project: "", id: "", agent: "", subject: "", working: false,
    waiting: [], status: { state: "idle", label: "", brief: "", line: "", next: "" }, at: "", heard: "", snippet: "", entries: [] })
  // Newest first.
  readonly property var all: Object.values(threads).sort((a, b) => b.at.localeCompare(a.at))
  // "all", "waiting" (a decision or a word of yours) or "working" (a run open).
  property string folder: "all"
  // A project id, or "" for every project.
  property string project: ""
  // What the search box asks for, lowercased; "" finds every thread.
  property string query: ""
  readonly property var shown: all.filter(thread => (project === "" || thread.project === project)
    && (folder === "all" || (folder === "waiting" ? waitsOnYou(thread) : thread.working))
    && matches(thread))
  property string selected: ""
  readonly property var thread: threads[selected] || null
  // Asks the window for a new thread, and the thread on screen for a reply or
  // for the decision it waits on.
  signal composeRequested()
  signal replyRequested()
  signal decisionRequested()

  // Thread key -> the time of the last word from its agent you read; kept
  // across sessions.
  property var seen: ({})
  readonly property int unread: all.filter(thread => isUnread(thread)).length
  readonly property int waiting: all.filter(thread => waitsOnYou(thread)).length
  readonly property int working: all.filter(thread => thread.working).length

  // What the window tells, as toasts; the server did not answer the last sweep.
  property bool unreachable: false
  readonly property Notices notices: Notices { offline: root.unreachable }

  // Thread key -> {cursor, events, snapshot}: what its thread is built from.
  property var cache: ({})
  property bool sweeping: false
  // After the first sweep, a new word from an agent is announced on the desktop.
  property bool primed: false

  Component.onCompleted: {
    if (socket === "")
      tell("this window was opened without a server to reach", true)
    else
      sweep()
  }

  Timer { interval: 2500; repeat: true; running: root.socket !== ""; onTriggered: root.sweep() }

  function tell(text, isError) { notices.tell(text, isError) }

  // Whether a thread holds what the search asks for: in its subject, agent,
  // project, any of its messages or the names of their files.
  function matches(thread) {
    if (query === "")
      return true
    const words = [thread.subject, thread.agent, thread.project]
      .concat(thread.entries.map(entry => entry.text), thread.entries.reduce((names, entry) => names.concat(entry.files.map(file => file.name)), []))
    return words.some(word => String(word).toLowerCase().includes(query))
  }

  // The day a thread belongs to in the list: today, yesterday or its date.
  function day(at) {
    const date = new Date(at)
    if (isNaN(date))
      return ""
    const today = new Date()
    const yesterday = new Date(today.getTime() - 86400000)
    return date.toDateString() === today.toDateString() ? "today"
      : date.toDateString() === yesterday.toDateString() ? "yesterday"
      : Qt.formatDate(date, "d MMMM yyyy")
  }

  function isUnread(thread) {
    return thread.heard !== "" && (seen[thread.key] || "") < thread.heard
  }

  function projectOf(id) {
    return projects.find(item => item.id === id) || null
  }

  function open(key) {
    selected = key
    markSeen(key)
  }

  function close() {
    selected = ""
  }

  // Opens the thread `by` places from the one open in the list shown.
  function step(by) {
    if (shown.length === 0)
      return
    const at = shown.findIndex(thread => thread.key === selected)
    open(shown[Math.max(0, Math.min(shown.length - 1, at < 0 ? 0 : at + by))].key)
  }

  // Marks a thread unread, as a mail client does, and goes back to the list.
  function markUnread(key) {
    seen = Object.assign({}, seen, { [key]: "" })
    seenFile.setText(JSON.stringify(seen))
    if (selected === key)
      close()
  }

  // Marks every thread shown read.
  function markAllRead() {
    const next = Object.assign({}, seen)
    for (const thread of shown)
      if (thread.heard !== "")
        next[thread.key] = thread.heard
    seen = next
    seenFile.setText(JSON.stringify(seen))
    tell("marked " + shown.length + " threads read", false)
  }

  function markSeen(key) {
    const thread = threads[key]
    if (!thread || !isUnread(thread))
      return
    seen = Object.assign({}, seen, { [key]: thread.heard })
    seenFile.setText(JSON.stringify(seen))
  }

  // What arrives in the thread on screen is read as it arrives.
  onThreadsChanged: if (selected !== "") markSeen(selected)

  function compose() {
    composeRequested()
  }

  // A new thread: a conversation in `project` and your first message to
  // `agent` there, with the files at the paths `files` lists.
  function send(project, agent, text, files) {
    const value = text.trim()
    const place = projectOf(project)
    if (value === "" || !place || agent === "")
      return
    http.call(place.socket, "POST", "/v1/projects/" + project + "/conversations", {}, true, data => {
      http.post(place.socket, "/v1/projects/" + project + "/conversations/" + data.id + "/messages",
        { message: value, agent: agent }, files, () => {
          selected = project + "/" + data.id
          tell("sent to " + agent, false)
          sweep()
        })
    })
  }

  // Your next message in a thread, to its agent, with the files at the paths `files` lists.
  function reply(key, text, files) {
    const thread = threads[key]
    const value = text.trim()
    if (!thread || value === "")
      return
    http.post(projectOf(thread.project).socket, "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/messages",
      { message: value, agent: thread.agent }, files, () => {
        tell("sent to " + thread.agent, false)
        sweep()
      })
  }

  // Saves a file attached in a thread to the downloads directory and opens it.
  function openAttachment(key, file) {
    const thread = threads[key]
    if (!thread)
      return
    http.openAttachment(projectOf(thread.project).socket,
      "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/attachments/" + file.sha256, file)
    tell("opening " + file.name, false)
  }

  // Answers a request of a thread with words, an option, or both: an option
  // of the request itself or, by the parts of path, of the decision below it
  // that the option is of.
  function decide(key, requestId, option, body, path) {
    const thread = threads[key]
    if (!thread || (!option && body.trim() === ""))
      return
    http.call(projectOf(thread.project).socket, "POST",
      "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/requests/" + requestId + "/reply",
      Requests.answer(option, body.trim(), path), true, () => {
        tell(option ? "answered " + option : "answered", false)
        sweep()
      })
  }

  // Reads who you are and the projects, then every project's conversations; a
  // snapshot whose cursor moved brings its new events.
  function sweep() {
    if (sweeping)
      return
    sweeping = true
    const failed = () => {
      connected = false
      unreachable = true
      sweeping = false
    }
    http.call(socket, "GET", "/v1/identity", null, false, identity => {
      me = identity
      http.call(socket, "GET", "/v1/projects", null, false, data => {
        connected = true
        unreachable = false
        loadAgents(data.items)
        const pending = data.items.slice()
        const keys = []
        const nextProject = () => {
          if (pending.length === 0) {
            for (const key of Object.keys(threads))
              if (!keys.includes(key))
                forget(key)
            sweeping = false
            primed = true
            return
          }
          const place = pending.shift()
          http.call(place.socket, "GET", "/v1/projects/" + place.id + "/conversations", null, false, list => {
            const ids = list.items.map(item => item.id)
            ids.forEach(id => keys.push(place.id + "/" + id))
            readAll(place, ids, nextProject)
          }, nextProject)
        }
        nextProject()
      }, failed)
    }, failed)
  }

  // The agents of each project not yet known, from its config: those of
  // depth 0 a thread can be with, and every one, for its picture and colour.
  function loadAgents(items) {
    const known = projects.filter(item => items.some(other => other.id === item.id))
    projects = items.map(item => known.find(other => other.id === item.id) || { id: item.id, socket: item.socket, agents: [] })
    if (Object.keys(rosters).some(id => !items.some(item => item.id === id)))
      rosters = Object.fromEntries(Object.entries(rosters).filter(([id]) => items.some(item => item.id === id)))
    for (const item of items) {
      if (known.some(other => other.id === item.id))
        continue
      http.setup(item.socket, item.id, setup => {
        const roster = setup.agents
        const agents = roster.filter(agent => agent.depth === 0 && !agent.workflow_only).map(agent => agent.name)
        projects = projects.map(other => other.id === item.id ? Object.assign({}, other, { agents: agents }) : other)
        rosters = Object.assign({}, rosters, { [item.id]: roster })
      })
    }
  }

  function forget(key) {
    const left = Object.assign({}, threads)
    delete left[key]
    threads = left
    delete cache[key]
  }

  function readAll(place, ids, done) {
    if (ids.length === 0)
      return done()
    const id = ids[0]
    const key = place.id + "/" + id
    const rest = () => readAll(place, ids.slice(1), done)
    const base = "/v1/projects/" + place.id + "/conversations/" + id
    http.call(place.socket, "GET", base + "/snapshot", null, false, snapshot => {
      const known = cache[key] || { cursor: "", events: [], snapshot: null }
      if (known.snapshot && known.snapshot.cursor === snapshot.cursor)
        return rest()
      events(place.socket, base, known.cursor, known.events, (cursor, all) => {
        cache[key] = { cursor: cursor, events: all, snapshot: snapshot }
        update(key, build(place.id, id, snapshot, all))
        rest()
      }, rest)
    }, rest)
  }

  // Every event after `cursor`, a page of up to 500 at a time.
  function events(on, base, cursor, read, done, failed) {
    http.call(on, "GET", base + "/events" + (cursor ? "?after=" + cursor : ""), null, false, data => {
      const all = read.concat(data.events)
      const last = data.events.length > 0 ? data.events[data.events.length - 1].cursor : cursor
      if (data.events.length === 500)
        events(on, base, last, all, done, failed)
      else
        done(last, all)
    }, failed)
  }

  function update(key, thread) {
    const before = threads[key]
    threads = Object.assign({}, threads, { [key]: thread })
    if (!primed || selected === key)
      return
    const broke = ["failed", "stalled"].includes(thread.status.state) && (!before || before.status.state !== thread.status.state)
    if (broke)
      announce(thread.agent + " · " + thread.status.label.toLowerCase(), thread.status.line)
    else if (thread.heard !== "" && (!before || before.heard < thread.heard))
      announce(waitsOnYou(thread) ? thread.agent + " waits for you" : thread.agent + " · " + thread.subject, thread.snippet)
  }

  // Whether nothing in a thread moves until you act: a request of yours is
  // pending, or its work waits for your next message.
  function waitsOnYou(thread) {
    return thread.waiting.length > 0 || thread.status.state === "awaited"
  }

  function announce(title, body) {
    notifier.command = ["notify-send", "-a", "omunculus", title, body]
    notifier.startDetached()
  }
  Process { id: notifier }

  // Whether a participant is you.
  function isMe(participant) {
    return !!participant && !!me && Requests.human(participant) && participant.issuer === me.issuer && participant.subject === me.subject
  }

  // The thread a conversation's snapshot and events make. Its entries, in
  // order: each message you wrote, and each answer you gave a request of the
  // thread, the option it chose with its words; each run of an agent of depth 0, as what it
  // said to you: the text of its model replies that call no tool, its
  // comments and the files it attached; and each request whose arbiter is
  // you, the question of whoever asked it when the harness passed it on, as
  // when the agent left a question unanswered, with the harness's sentence as
  // its fine print.
  function build(projectId, id, snapshot, events) {
    const rootRuns = {}
    for (const run of snapshot.runs)
      if (String(run.depth) === "0")
        rootRuns[run.id] = run
    const entries = []
    const spoken = {}
    const replies = {}
    let agent = ""
    for (const event of events) {
      const body = event.body || {}
      if (event.type === "prompt" && event.actor && event.actor.kind === "human") {
        agent = agent || body.agent || ""
        entries.push({ kind: "you", key: event.cursor, from: "you", to: body.agent || agent, text: body.message || "", at: event.at, open: false, files: body.attachments || [] })
      } else if (event.type === "reply" && event.request_id && isMe(event.actor)) {
        replies[event.request_id] = event
      } else if (rootRuns[event.run_id] && ["model", "comment", "attach"].includes(event.type)) {
        // A reply that calls a tool is the agent acting: its text narrates the
        // call to itself, and only a reply that calls none speaks to you.
        const words = (event.type === "model" ? (calls(body).length > 0 ? "" : Model.text(body))
          : event.type === "comment" ? String(body.body || "") : String(body.note || "")).trim()
        const files = event.type === "attach" ? body.attachments || [] : []
        if (words === "" && files.length === 0)
          continue
        const run = rootRuns[event.run_id]
        agent = agent || run.agent
        if (spoken[run.id] === undefined) {
          spoken[run.id] = entries.length
          entries.push({ kind: "agent", key: run.id, from: run.agent, to: "you", text: words, at: event.at, open: run.status === "open", files: files })
        } else {
          const entry = entries[spoken[run.id]]
          entry.text = [entry.text, words].filter(part => part !== "").join("\n\n")
          entry.files = entry.files.concat(files)
        }
      }
    }
    const notes = noted(events)
    const asked = snapshot.requests.filter(request => isMe(request.arbiter))
    for (const request of asked) {
      const question = asking(request, notes, agent)
      const reply = replies[request.id]
      entries.push({
        kind: "request", key: request.id, from: question.from, to: "you",
        note: question.note,
        text: question.text, at: request.created_at, open: Requests.pending(request),
        files: [],
        choices: Requests.choices(request),
        origins: question.origins,
        answered: !!reply
      })
      // Your answer is a message of yours: its words, and the option it chose.
      if (reply) {
        const option = Requests.chosen(reply.body)
        const words = String(reply.body.body || "")
        entries.push({ kind: "you", key: reply.cursor, from: "you", to: agent, answering: true,
          option: option, text: words === option ? "" : words, at: reply.at, open: false, files: [] })
      }
    }
    entries.sort((a, b) => a.at.localeCompare(b.at))

    const first = entries.find(entry => entry.kind === "you")
    const subject = first ? String(first.text).trim().split("\n")[0] : ""
    const theirs = entries.filter(entry => entry.kind !== "you")
    const latest = entries.length > 0 ? entries[entries.length - 1] : null
    return {
      key: projectId + "/" + id,
      project: projectId,
      id: id,
      agent: agent,
      subject: subject.length > 90 ? subject.slice(0, 87) + "..." : subject || "(no message)",
      working: snapshot.runs.some(run => run.status === "open"),
      waiting: asked.filter(request => Requests.pending(request)).map(request => request.id),
      status: status(snapshot, events, asked.filter(request => Requests.pending(request)), agent),
      at: latest ? latest.at : snapshot.conversation.created_at,
      heard: theirs.length > 0 ? theirs[theirs.length - 1].at : "",
      snippet: latest ? oneLine((latest.kind === "you" ? "you: " : "") + latest.text
        + (latest.files.length > 0 ? " [" + latest.files.map(file => file.name).join(", ") + "]" : "")) : "",
      entries: entries
    }
  }

  // What a thread's conversation is doing, as the client reads it: only the
  // agent they write to is named, never a model, tool, stage, work or other
  // agent. {state, label, brief, line, next}: "waiting" while a request of
  // yours is pending, with `ask` saying you "answer" it or "decide" it; "working" while a run of any depth is open or a request
  // waits on someone else; "failed" (STUCK) when nothing runs and the last run
  // ended with an error, whose reason stays in the console; "awaited" while
  // nothing runs and a work you gave waits for your next message; "stalled"
  // when nothing runs, nothing is pending and a work is not over; "done" when
  // every work it began is done or cancelled; "idle" otherwise. `brief` is for
  // the list, `line` and `next` for the thread's head.
  function status(snapshot, events, pending, to) {
    const agent = to || "the agent"
    const ended = {}
    for (const event of events)
      if (event.type === "end-run" && event.run_id)
        ended[event.run_id] = event.body || {}
    const runs = snapshot.runs.slice().sort((a, b) => a.started_at.localeCompare(b.started_at))
    const failure = run => run && ended[run.id] && ended[run.id].error ? String(ended[run.id].error) : ""

    if (pending.length > 0) {
      // Questions are answered, a choice of options or a permission decided.
      const answers = Requests.kind(pending[0]) === "needs-you"
      const form = answers ? Questions.parse(Requests.question(pending[0], true)) : null
      const needs = form ? agent + " has " + form.items.length + " questions for you" : agent + " needs your " + (answers ? "answer" : "decision")
      return { state: "waiting", ask: answers ? "answer" : "decide", label: "WAITING FOR YOU", brief: needs, line: needs + (pending.length > 1 ? "  (+" + (pending.length - 1) + " more)" : ""),
        next: answers ? "Nothing moves until you answer: ANSWER takes you to the question." : "Nothing moves until you decide: DECIDE takes you to it." }
    }

    const working = { state: "working", label: "WORKING", brief: agent + " is working on it", line: agent + " is working on it.", next: "" }
    if (runs.some(run => run.status === "open"))
      return working

    const finished = runs.filter(run => run.status !== "open").sort((a, b) => String(a.finished_at || "").localeCompare(String(b.finished_at || "")))
    const last = finished.length > 0 ? finished[finished.length - 1] : null
    const error = failure(last)
    if (error !== "")
      return { state: "failed", label: "STUCK", brief: agent + " could not go on right now",
        line: agent + " could not go on right now.",
        next: "Write again to try once more." }

    // A request that waits on someone else is work going on, to the client.
    if (snapshot.requests.some(request => Requests.pending(request)))
      return working

    // A work you gave that waits for your next message: only you move it on.
    const awaited = snapshot.works.find(work => !work.parent_id && work.state === "waiting" && work.waiting === "message")
    if (awaited) {
      return { state: "awaited", label: "WAITING FOR YOU", brief: agent + " needs your answer",
        line: agent + " needs your answer.",
        next: "Nothing in this thread moves until you write to " + agent + ": REPLY picks it up." }
    }

    // With nothing running or pending, a work open, or waiting, waits on nothing.
    const stuck = snapshot.works.find(work => work.state === "open") || snapshot.works.find(work => work.state === "waiting")
    if (stuck) {
      return { state: "stalled", label: "STALLED", brief: agent + " stopped before finishing",
        line: agent + " stopped before finishing, and nothing runs now.",
        next: "Write again to pick it up." }
    }

    const roots = snapshot.works.filter(work => !work.parent_id)
    if (roots.length > 0 && roots.every(work => work.state === "done" || work.state === "cancelled"))
      return { state: "done", label: roots.every(work => work.state === "cancelled") ? "CANCELLED" : "DONE", brief: "", line: "", next: "" }
    return { state: "idle", label: "", brief: "", line: "", next: "" }
  }

  // The requests the harness opened, by id: the events that opened them are
  // its, whoever the request names as its requester.
  function noted(events) {
    const notes = {}
    for (const event of events)
      if (Requests.byHarness(event))
        notes[event.request_id] = true
    return notes
  }

  // The names of the tools a model event asks to call: an Anthropic message's
  // tool uses, an OpenAI message's tool calls, a Responses output's function
  // calls, or a command model's call; code mode's script is "code".
  function calls(body) {
    if (body === null || typeof body !== "object")
      return []
    const names = body.type === "call" ? [body.name]
      : Array.isArray(body.content) ? body.content.filter(part => part.type === "tool_use").map(part => part.name)
      : Array.isArray(body.tool_calls) ? body.tool_calls.map(call => call.function ? call.function.name : "")
      : Array.isArray(body.output) ? body.output.filter(part => part.type === "function_call").map(part => part.name)
      : []
    return names.filter(name => !!name).map(name => name === "__omunculus_execute" ? "code" : name)
  }

  // What a request asks, as {from, text, origins, note}, each question once:
  // a reason an origin's question holds gives way to that question, and an
  // origin's question the text shown already holds is left out. It comes from
  // `agent`, the one the thread is with, whoever below asked it: the harness's
  // own sentence on how it came to you is left out. A request the harness
  // opened asks what it passes on; passing on nothing, it is a note, its
  // reason no one's words.
  function asking(request, notes, agent) {
    const passed = notes[request.id] ? Requests.passedOn(request) : []
    if (passed.length > 0)
      return { from: agent, text: Requests.question(request, true), origins: [], note: false }
    const plain = value => String(value || "").replace(/\s+/g, " ").trim().toLowerCase()
    const origins = Object.keys(request.origins || {}).map(part => ({ reason: request.origins[part].reason || "" }))
    const text = origins.map(origin => origin.reason)
      .filter(reason => plain(reason).includes(plain(request.reason)))
      .reduce((longest, reason) => reason.length > longest.length ? reason : longest, request.reason || "")
    return { from: notes[request.id] ? "note" : agent, text: text,
      origins: origins.filter(origin => !plain(text).includes(plain(origin.reason))), note: !!notes[request.id] }
  }

  // A text on one line, without its Markdown marks, cut short when long.
  function oneLine(value) {
    const line = String(value || "").replace(/^\s*(?:[#>|-]+|\d+\.)\s*/gm, "").replace(/[*`|]/g, "").replace(/\s+/g, " ").trim()
    return line.length > 140 ? line.slice(0, 137) + "..." : line
  }

  // When something happened: the time today, the day before.
  function when(at) {
    const date = new Date(at)
    if (isNaN(date))
      return ""
    return date.toDateString() === new Date().toDateString() ? Qt.formatTime(date, "HH:mm") : Qt.formatDate(date, "d MMM")
  }

  // The tone of a thread's state: the accent while an agent works, the
  // warning's when it waits on you or stalled, the error's when it failed,
  // the success's when it is done.
  function toneOfState(state) {
    return ({ working: Theme.primary, waiting: Theme.warning, awaited: Theme.warning, stalled: Theme.warning,
      failed: Theme.error, done: Theme.success })[state] || Theme.dim
  }

  // Whether a name is of an agent of a project, rather than a person's.
  function isAgent(project, name) {
    return (rosters[project] || []).some(agent => agent.name === name)
  }

  // An agent's colour, by its place among its project's agents.
  function toneOf(project, name) { return Theme.agentTone(rosters[project] || [], name) }

  // The file of an agent's picture, as a url, or "" while it has none.
  function imageOf(project, name) {
    const keeper = images.objectAt(Object.keys(rosters).indexOf(project))
    return keeper ? keeper.source(name) : ""
  }

  // Each project's pictures, fetched once through its own socket.
  Instantiator {
    id: images
    model: Object.keys(root.rosters)
    delegate: AgentImages {
      required property string modelData
      // Mail's Http, which `http` here would name this property.
      http: root.client
      socket: (root.projectOf(modelData) || { socket: "" }).socket
      base: "/v1/projects/" + modelData
      agents: root.rosters[modelData] || []
    }
  }

  FileView {
    id: seenFile
    path: Quickshell.statePath("seen.json")
    printErrors: false
    onLoaded: {
      try {
        root.seen = JSON.parse(text())
      } catch (e) {}
    }
  }

  readonly property Http client: http
  Http {
    id: http
    onRefused: reason => root.tell(reason, true)
  }
}
