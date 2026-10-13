import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// ConversationView is a conversation on screen, one of its pages at a time,
// all reading the one conversation the window holds: the conversation, yours
// with the root agent, where every request shows where it was made; the map
// of its agents at work, where the node picked opens beside it; and the log,
// every event a row. Each page gives the commands of its bar: on the
// conversation, to answer what waits on you there and read its notes; on the
// map, with a node picked, what you can do to it — answer or escalate what it
// asked, leave it a note, mark its notes read, write to it. A request is
// answered in its decision, opened over the page. The composer's pending
// button opens the map on what waits on you. Esc closes what a page has
// picked, then goes back to the conversations.
Item {
  id: view

  property bool active: false
  property bool compact: false
  property bool short: false
  // The page on screen, one of `pages`.
  property string page: "conversation"
  signal pageChosen(string page)
  signal costWanted()

  // The pages, in their order.
  readonly property var pages: ["conversation", "map", "log"]

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
    const back = { text: "CONVERSATIONS", short: "BACK", icon: "chevron-left", role: "navigation", tip: "back to the conversations  esc", run: () => Omunculus.leave() }
    const cost = { text: "COST", icon: "cost", tip: "what this conversation cost", run: () => view.costWanted() }
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
      { text: "NEW CONVERSATION", short: "NEW", icon: "plus", tip: "start another conversation", run: () => { Omunculus.leave(); Omunculus.startConversation() } },
      cost
    ]
  }

  // Whether the decision of a request is open over the page.
  readonly property bool dialogOpen: decision.visible

  function focusEntry() {
    if (page === "map")
      agents.forceActiveFocus()
    else if (page === "log")
      log.forceActiveFocus()
    else
      mainComposer.focusEntry()
  }

  // Opens the map on what waits on you.
  function showPending() {
    pageChosen("map")
    agents.pickPending()
  }

  focus: active
  onActiveChanged: if (active) focusEntry()
  Keys.onEscapePressed: Omunculus.leave()
  onPageChanged: Qt.callLater(focusEntry)
  Connections {
    target: Omunculus
    function onConversationIdChanged() { agents.picked = null; log.picked = null }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "conversation"

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

  Stage {
    anchors.fill: parent
    shown: view.page === "map"

    AgentsView {
      id: agents
      anchors.fill: parent
      focus: view.page === "map"
      onLeave: Omunculus.leave()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "log"

    LogView {
      id: log
      anchors.fill: parent
      focus: view.page === "log"
      onLeave: Omunculus.leave()
    }
  }

  RequestDialog { id: decision }
}
