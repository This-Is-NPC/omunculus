pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "kit/client"
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// Mail is every project of the server as an e-mail client shows it. A thread
// is a conversation with one agent of depth 0; Mailbox.js makes its e-mails
// from the snapshot and the events. Every read and command goes to a
// project's local socket through curl. Which threads you read, archived and
// the drafts you left are kept in Quickshell's state directory.
Singleton {
  id: root

  // The socket the mailbox was opened on; it lists every project.
  readonly property string socket: Quickshell.env("OMUNCULUS_SOCKET")
  // The project it was opened on, whose default agent a new message starts with.
  readonly property string home: Quickshell.env("OMUNCULUS_PROJECT")

  property bool connected: false
  // You, as the server knows you: {issuer, subject}.
  property var me: null
  // Every project, as {id, socket, agents, defaultAgent}: the agents of
  // depth 0 a thread can be with, and the one its config declares the default.
  property var projects: []
  // Project id -> every agent of its config: the agents whose pictures and
  // colours the e-mails show.
  property var rosters: ({})
  // "project/conversation" -> its thread, as Mailbox.build makes it.
  property var threads: ({})
  // A thread with nothing in it, for a view whose thread has just gone.
  readonly property var blank: ({ key: "", project: "", id: "", agent: "", with: { agent: "", project: "", name: "", address: "", text: "" },
    subject: "", label: "", messages: [], pending: [], reviews: [], at: "", heard: "", received: 0, sent: 0, parties: "", snippet: "" })
  // A review with nothing in it, for a view whose review has just gone.
  readonly property var blankReview: ({ key: "", project: "", conversation: "", request: "", summary: "", args: [], text: "", outcome: "", reason: "", at: "",
    from: { agent: "", project: "", name: "", address: "", text: "" } })
  // Newest first.
  readonly property var all: Object.values(threads).sort((a, b) => b.at.localeCompare(a.at))
  // "inbox", "sent", "drafts", "pending" or "archive".
  property string folder: "inbox"
  onFolderChanged: {
    if (folder === "pending")
      selected = ""
    else
      selectedReview = ""
  }
  // What the search box asks for, lowercased; "" finds every thread.
  property string query: ""
  readonly property var shown: all.filter(thread => Mailbox.inFolder(thread, folder, archived)
    && Mailbox.matches(thread, query))
  readonly property var shownDrafts: drafts.filter(draft => query === ""
    || [draft.subject, draft.body, draft.agent].some(word => String(word).toLowerCase().includes(query)))
  // The reviews waiting on you, newest first: what the Pending folder lists.
  readonly property var reviews: all.reduce((list, thread) => list.concat(thread.reviews), [])
    .filter(review => !given[review.key]).sort((a, b) => b.at.localeCompare(a.at))
  // Review key -> the option of its answer on the way; the review stays on
  // screen, its buttons off, until the server has taken it.
  property var answering: ({})
  // Review key -> true once its answer was taken: it leaves Pending at once,
  // not at the next sweep.
  property var given: ({})
  readonly property var shownReviews: reviews.filter(review => Mailbox.reviewMatches(review, query))
  property string selected: ""
  readonly property var thread: threads[selected] || null
  // The key of the review open, "project/conversation/request".
  property string selectedReview: ""
  readonly property var review: reviews.find(item => item.key === selectedReview) || null
  // Asks the window for a message to write, from `preset`: {to, subject, body,
  // draft}, each optional.
  signal composeRequested(var preset)
  // Asks the thread on screen for a reply to the message `key`, or to its last.
  signal replyRequested(string key)

  // Thread key -> the time of the last mail from its agent you read.
  property var seen: ({})
  // Thread key -> when you archived it.
  property var archived: ({})
  // Drafts, newest first: {id, project, agent, subject, body, at}.
  property var drafts: []
  readonly property int unread: all.filter(thread => Mailbox.inFolder(thread, "inbox", archived) && isUnread(thread)).length

  // What the window tells, as toasts; the server did not answer the last sweep.
  property bool unreachable: false
  readonly property Notices notices: Notices { offline: root.unreachable }

  // Thread key -> {cursor, events, snapshot}: what its thread is built from.
  property var cache: ({})
  property bool sweeping: false
  // After the first sweep, a new mail is announced on the desktop.
  property bool primed: false

  Component.onCompleted: {
    if (socket === "")
      tell("this window was opened without a server to reach", true)
    else
      sweep()
  }

  Timer { interval: 2500; repeat: true; running: root.socket !== ""; onTriggered: root.sweep() }

  function tell(text, isError) { notices.tell(text, isError) }

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

  // When something happened: the time today, else the day.
  function when(at) {
    const date = new Date(at)
    if (isNaN(date))
      return ""
    return date.toDateString() === new Date().toDateString() ? Qt.formatTime(date, "HH:mm") : Qt.formatDate(date, "d MMM")
  }

  // A full date and time, as a mail's header shows it.
  function stamp(at) {
    const date = new Date(at)
    return isNaN(date) ? "" : Qt.formatDateTime(date, "d MMM yyyy, HH:mm")
  }

  function isUnread(thread) { return Mailbox.isUnread(thread, seen) }

  function projectOf(id) {
    return projects.find(item => item.id === id) || null
  }

  function open(key) {
    selectedReview = ""
    selected = key
    markSeen(key)
  }

  function close() {
    selected = ""
    selectedReview = ""
  }

  function openReview(key) {
    selected = ""
    selectedReview = key
  }

  // Opens the review `by` places from the one open.
  function stepReview(by) {
    if (shownReviews.length === 0)
      return
    const at = shownReviews.findIndex(item => item.key === selectedReview)
    openReview(shownReviews[Math.max(0, Math.min(shownReviews.length - 1, at < 0 ? 0 : at + by))].key)
  }

  // Opens the thread `by` places from the one open in the list shown.
  function step(by) {
    if (folder === "pending")
      return stepReview(by)
    if (shown.length === 0)
      return
    const at = shown.findIndex(thread => thread.key === selected)
    open(shown[Math.max(0, Math.min(shown.length - 1, at < 0 ? 0 : at + by))].key)
  }

  function keep(file, value) { file.setText(JSON.stringify(value)) }

  // Marks a thread unread and goes back to the list.
  function markUnread(key) {
    seen = Object.assign({}, seen, { [key]: "" })
    keep(seenFile, seen)
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
    keep(seenFile, seen)
  }

  function markSeen(key) {
    const thread = threads[key]
    if (!thread || !isUnread(thread))
      return
    seen = Object.assign({}, seen, { [key]: thread.heard })
    keep(seenFile, seen)
  }

  // Moves a thread to the archive and goes back to the list.
  function archive(key) {
    archived = Object.assign({}, archived, { [key]: new Date().toISOString() })
    keep(archiveFile, archived)
    if (selected === key)
      close()
  }

  // Moves a thread back to the inbox.
  function restore(key) {
    const left = Object.assign({}, archived)
    delete left[key]
    archived = left
    keep(archiveFile, archived)
    if (selected === key)
      close()
  }

  // Asks the window for a new message, or for one started from `preset`.
  function compose(preset) {
    composeRequested(preset || {})
  }

  // Keeps what is written as a draft; one with an `id` replaces its own.
  function saveDraft(draft) {
    const next = { id: draft.id || String(Date.now()), project: draft.project, agent: draft.agent, subject: draft.subject, body: draft.body, at: new Date().toISOString() }
    drafts = [next].concat(drafts.filter(other => other.id !== next.id))
    keep(draftsFile, drafts)
    return next.id
  }

  function discardDraft(id) {
    drafts = drafts.filter(draft => draft.id !== id)
    keep(draftsFile, drafts)
  }

  // A new thread: a conversation in `project` and your first message to
  // `agent` there, or, with none, to the project's default agent, its subject its first line, with the files at the paths
  // `files` lists. `draft` is the draft it was written from, gone once sent.
  // `stay` leaves what is on screen as it is, as a reply to several does.
  function send(project, agent, subject, body, files, draft, stay) {
    const place = projectOf(project)
    const text = [subject.trim(), body.trim()].filter(part => part !== "").join("\n\n")
    if (text === "" || !place)
      return
    http.call(place.socket, "POST", "/v1/projects/" + project + "/conversations", {}, true, data => {
      http.post(place.socket, "/v1/projects/" + project + "/conversations/" + data.id + "/messages",
        agent === "" ? { message: text } : { message: text, agent: agent }, files, () => {
          if (draft)
            discardDraft(draft)
          // What you sent is in Sent, not next to an empty Inbox.
          if (!stay) {
            folder = "sent"
            selected = project + "/" + data.id
          }
          sweep()
        })
    })
  }

  // Your reply in a thread: the answer to `request` when one is given, in
  // words only, else your next message to the thread's agent, with the files
  // at the paths `files` lists.
  function reply(key, request, text, files) {
    const thread = threads[key]
    const value = text.trim()
    if (!thread || value === "")
      return
    const base = "/v1/projects/" + thread.project + "/conversations/" + thread.id
    const socket = projectOf(thread.project).socket
    const sent = () => {
      sweep()
    }
    if (request !== "")
      http.call(socket, "POST", base + "/requests/" + request + "/reply", Mailbox.answer(value), true, sent)
    else
      http.post(socket, base + "/messages", { message: value, agent: thread.agent }, files, sent)
  }

  // Decides a review: `option` is "approve", "edit" or "deny", `text` the
  // edited text or the reason.
  function decide(review, option, text) {
    const place = projectOf(review.project)
    if (!place || answering[review.key])
      return
    answering = Object.assign({}, answering, { [review.key]: option })
    const settle = () => {
      const left = Object.assign({}, answering)
      delete left[review.key]
      answering = left
    }
    http.call(place.socket, "POST", "/v1/projects/" + review.project + "/conversations/" + review.conversation + "/requests/" + review.request + "/reply",
      Mailbox.decision(option, text), true, () => {
        given = Object.assign({}, given, { [review.key]: true })
        settle()
        tell(Mailbox.decided[option] + ": " + review.summary, false)
        sweep()
      }, reason => {
        settle()
        tell("The answer was not sent: " + reason, true)
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
  // depth 0 a thread can be with, its declared default, and every agent, for
  // its picture and colour; and whether you may write there.
  function loadAgents(items) {
    const known = projects.filter(item => items.some(other => other.id === item.id))
    projects = items.map(item => known.find(other => other.id === item.id) || { id: item.id, socket: item.socket, agents: [], defaultAgent: "", canWrite: false })
    if (Object.keys(rosters).some(id => !items.some(item => item.id === id)))
      rosters = Object.fromEntries(Object.entries(rosters).filter(([id]) => items.some(item => item.id === id)))
    for (const item of items) {
      if (known.some(other => other.id === item.id))
        continue
      http.setup(item.socket, item.id, setup => {
        projects = projects.map(other => other.id === item.id
          ? Object.assign({}, other, { agents: Mailbox.chat(setup.agents), defaultAgent: Mailbox.defaultAgent(setup) }) : other)
        rosters = Object.assign({}, rosters, { [item.id]: setup.agents })
      })
      http.call(item.socket, "GET", "/v1/projects/" + item.id + "/capabilities", null, false, caps => {
        projects = projects.map(other => other.id === item.id ? Object.assign({}, other, { canWrite: Mailbox.canWrite(caps.items) }) : other)
      })
    }
  }

  // The agents a message can go to, those of the current project first.
  readonly property var recipients: Mailbox.recipients(projects, home)

  // The agent a message with no recipient goes to: the default agent of the
  // project the window was opened on; none when its config declares none.
  function defaultRecipient() {
    const place = projectOf(home)
    return place && place.canWrite && place.defaultAgent !== "" ? Mailbox.person(place.defaultAgent, place.id) : null
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
        update(key, Mailbox.build(place.id, id, snapshot, all, me))
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
    if (primed && selected !== key && thread.heard !== "" && (!before || before.heard < thread.heard))
      announce(thread.with.name + " · " + thread.subject, thread.snippet)
  }

  function announce(title, body) {
    notifier.command = ["notify-send", "-a", "omunculus", title, body]
    notifier.startDetached()
  }
  Process { id: notifier }

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

  FileView {
    id: archiveFile
    path: Quickshell.statePath("archive.json")
    printErrors: false
    onLoaded: {
      try {
        root.archived = JSON.parse(text())
      } catch (e) {}
    }
  }

  FileView {
    id: draftsFile
    path: Quickshell.statePath("drafts.json")
    printErrors: false
    onLoaded: {
      try {
        root.drafts = JSON.parse(text())
      } catch (e) {}
    }
  }

  readonly property Http client: http
  Http {
    id: http
    onRefused: reason => root.tell(reason, true)
  }
}
