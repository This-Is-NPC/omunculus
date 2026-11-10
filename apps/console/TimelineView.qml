pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Requests.js" as Requests
import "kit/ui/focus.js" as Focus
import "kit/ui"

// TimelineView is one thread of the conversation: what you and its agents
// said, what each run did on a line below its words, and, in the main thread,
// each request where it was made, live or read back.
// Like a chat, it sits on the bottom and grows upwards, and it follows new
// entries unless you scrolled up to read; then a pill counts what arrived out
// of view and leads back to it. A turn streaming taller than the view is held
// by its top, so its first words stay readable. From the keyboard, Tab reaches
// it on the newest entry: ↑/↓ and PgUp/PgDn move, Home goes to the first and
// End back to the newest, and Tab moves into the tools of the entry it is on.
// A request is a card only while it waits on you; your answer reads as a
// bubble, and what the team asked among itself is an exchange (TeamRow). A
// note a handed-down work's agent left on its work is a card of its own
// where it was left (TeamNote). A work handed down is a SubWorkBlock where it
// was, which unfolds into its own thread nested here; each run of the works
// below that ended is a line of the log in the main thread (LogLine), "designer
// worked 4 min · 12 steps". A question for you that arrives while the view
// follows is held by its top. While an agent works for the thread, a live line
// at its end says who, from the agent you wrote to down to the one at work,
// what that one does and for how long, unless that agent's own turn streams
// here and says it. Its implicit height is its entries', for a thread nested
// in a block, which says itself that its agents work.
Item {
  id: root

  // The thread shown: "" for the main one, or a work's.
  property string thread: ""
  // How deep this thread is nested in sub-work blocks: 0 for a page's own.
  property int nesting: 0
  readonly property ListModel model: Omunculus.thread(thread)
  property string emptyText: ""
  // Whether requests show where they were made; beside the map they show on
  // the node that asked instead.
  property bool requestsShown: true
  // Counts changes to the entries, so each line knows again whether it
  // continues the turn before it.
  property int revision: 0
  // Counts every change to the entries, a turn streaming included.
  property int changes: 0

  // Entries that arrived while the view was not following, counted once each.
  property int unseen: 0
  property var seen: ({})
  // The turns streaming, by key, so the one that finishes counts as new.
  property var streams: ({})
  // The streaming turn whose top the view holds, and the one you jumped to
  // the end of, which it does not hold.
  property string held: ""
  property string released: ""
  // Whether `held` is a question for you rather than a streaming turn.
  property bool holdingCard: false
  // The question whose card the keyboard was in when it was answered.
  property string typing: ""
  // The answer to a question the keyboard was in has come: focus belongs elsewhere.
  signal answered()
  // A work is wanted as a transcript of its own.
  signal openWork(string work)
  // The log of a work is wanted ("" for the conversation's own).
  signal openLog(string work)
  // The requests no other request gathers; the rest are its climb.
  readonly property var contained: Requests.contained(Omunculus.requests)

  // Counts a new entry when the view is away from the end; speech has no key.
  function arrived(key) {
    if (timeline.following || (key !== "" && root.seen[key]))
      return
    if (key !== "")
      root.seen[key] = true
    root.unseen++
  }

  function rowOf(key) {
    for (let row = 0; row < model.count; row++) {
      if (model.get(row).key === key)
        return row
    }
    return -1
  }

  // Brings the entry of `key` into view, and stops following the end unless
  // the keyboard is inside an entry, where the view stays as it is kept. An
  // entry that takes the keyboard, or is taller than most of the view, starts
  // at its top, so a form shows its first questions.
  function reveal(key, top = false) {
    const row = rowOf(key)
    if (row < 0)
      return
    if (!inEntry)
      timeline.following = false
    // A row added while the view was hidden has no item until it lays out.
    timeline.forceLayout()
    const entry = timeline.itemAtIndex(row)
    timeline.positionViewAtIndex(row, top || (entry && entry.height > timeline.height * 0.6) ? ListView.Beginning : ListView.Center)
  }

  // Brings the delivered result, the newest note of a done conversation, into view.
  function showResult() {
    if (newestNote >= 0)
      reveal(model.get(newestNote).key, true)
  }

  // The card of the newest question for you, once its entry exists.
  function cardItem() {
    const row = newestCard !== "" ? rowOf(newestCard) : -1
    const entry = row >= 0 ? timeline.itemAtIndex(row) : null
    return entry ? entry.content : null
  }

  // Brings the newest question into view and puts the keyboard in its words.
  // Hidden, it waits for the view to show (the page calls it again then); a
  // card whose row or form is not built yet is tried again every 100 ms, ten
  // times at most, until the keyboard is inside it and it is in view, so
  // a card placed while rows were still unmeasured is placed again.
  function focusCard() {
    if (newestCard === "" || !visible)
      return
    focusTries = 10
    focusRetry.restart()
    reveal(newestCard, true)
    tryFocusCard()
  }
  property int focusTries: 0
  function tryFocusCard() {
    if (!cardShown())
      reveal(newestCard, true)
    const card = cardItem()
    if (card)
      card.focusWords()
    if (cardFocused() && cardShown() || --focusTries <= 0)
      focusRetry.stop()
  }
  // Whether the newest question's entry shows whole, or from its top when it is
  // taller than the view.
  function cardShown() {
    const row = newestCard !== "" ? rowOf(newestCard) : -1
    const entry = row >= 0 ? timeline.itemAtIndex(row) : null
    return !!entry && entry.y >= timeline.contentY - 1 && entry.y + Math.min(entry.height, timeline.height) <= timeline.contentY + timeline.height + 1
  }
  Timer {
    id: focusRetry
    interval: 100
    repeat: true
    onTriggered: root.tryFocusCard()
  }

  // Decides the request of `key` with `option`, as its card's own options do,
  // so the card shows what was sent while it goes.
  function decide(key, option, path) {
    reveal(key)
    const row = rowOf(key)
    const entry = row >= 0 ? timeline.itemAtIndex(row) : null
    if (entry && entry.content)
      (entry.content as RequestDecision).decide(option, (entry.content as RequestDecision).note, path)
  }

  // Whether the options of the newest decision waiting on you are in view,
  // so the quick chips need not offer them again.
  readonly property bool decidingShown: {
    timeline.contentY; timeline.height; timeline.contentHeight; revision
    const row = Omunculus.deciding ? rowOf(Omunculus.deciding.id) : -1
    const entry = row >= 0 ? timeline.itemAtIndex(row) : null
    const options = entry && entry.content ? entry.content.choicesRow : null
    if (!options || !options.visible)
      return false
    const top = options.mapToItem(timeline.contentItem, 0, 0).y
    return top >= timeline.contentY && top + options.height <= timeline.contentY + timeline.height
  }

  // Whether the keyboard is inside the card of a question.
  function cardFocused() {
    const card = cardItem()
    return !!card && Focus.within(Window.activeFocusItem, card)
  }

  // How the entry at `row` shows: "card" for a request waiting on you,
  // "answer" for one you answered, "team" for the rest, "none" for one
  // another gathers; "turn", "work", "note", "worked" and "speech" for the
  // rest of the thread.
  function roleAt(row) {
    const entry = model.get(row)
    if (!entry)
      return "none"
    if (entry.kind !== "request")
      return ["turn", "work", "note", "worked"].includes(entry.kind) ? entry.kind : "speech"
    const request = Omunculus.requests.find(item => item.id === entry.key)
    if (!request || contained.has(entry.key))
      return "none"
    if (Requests.pending(request) && Requests.human(request.arbiter))
      return "card"
    const answer = Omunculus.replies[entry.key]
    return answer && answer.who === "you" ? "answer" : "team"
  }

  // The newest question waiting on you, by key; "" when none.
  readonly property string newestCard: {
    if (revision < 0)
      return ""
    for (let row = model.count - 1; row >= 0; row--) {
      if (roleAt(row) === "card")
        return model.get(row).key
    }
    return ""
  }
  // The row of the newest note a work's agent left, or -1.
  readonly property int newestNote: {
    if (revision < 0)
      return -1
    for (let row = model.count - 1; row >= 0; row--) {
      if (roleAt(row) === "note")
        return row
    }
    return -1
  }
  // Whether the conversation's work is done: its closing note shows whole.
  readonly property bool finished: !!Omunculus.progress && Omunculus.progress.state === "done"
  // A card that arrives while the keyboard is free is offered to the page.
  signal cardArrived
  onNewestCardChanged: {
    if (newestCard !== "" && !inEntry)
      cardArrived()
    if (newestCard !== "" && timeline.following) {
      held = newestCard
      holdingCard = true
    } else if (newestCard === "" && holdingCard) {
      held = ""
      holdingCard = false
      Qt.callLater(timeline.follow)
    }
  }

  // Goes to the end and follows it again, past a turn still streaming.
  function jump() {
    const newest = timeline.count > 0 ? timeline.model.get(timeline.count - 1) : null
    root.released = newest && newest.streaming ? newest.key : ""
    root.held = ""
    root.holdingCard = false
    timeline.following = true
    if (timeline.currentIndex >= 0)
      timeline.currentIndex = timeline.count - 1
    timeline.positionViewAtEnd()
  }

  // What the person sends or answers is seen at once, never as news.
  Connections {
    target: Omunculus
    function onActed() { root.jump() }
  }

  Connections {
    target: root.model
    // A turn growing as it streams changes no one's turn, but it is new again
    // when it finishes.
    function onDataChanged(topLeft) {
      root.changes++
      const entry = root.model.get(topLeft.row)
      if (entry.streaming)
        root.streams[entry.key] = true
      else if (root.streams[entry.key]) {
        delete root.streams[entry.key]
        root.arrived(entry.key)
      }
    }
    function onRowsInserted(parent, first, last) {
      root.revision++
      root.changes++
      for (let row = first; row <= last; row++) {
        const entry = root.model.get(row)
        if (entry.streaming)
          root.streams[entry.key] = true
        root.arrived(entry.key)
      }
    }
    function onRowsRemoved() {
      root.revision++
      root.changes++
    }
  }

  // Who works for this thread, as {chain, agent, doing, since, round}
  // (Progress.live); null when no one does, in a thread nested in a block, or
  // while that agent's own turn streams here and shows it.
  readonly property var working: {
    const live = nesting > 0 ? null : Progress.live(Omunculus.progress, thread, Omunculus.agent || Omunculus.lastAgent)
    if (!live || changes < 0)
      return null
    for (let row = model.count - 1; row >= 0; row--) {
      const entry = model.get(row)
      if (entry.kind === "turn" && entry.streaming && entry.who === live.agent
          && (entry.text !== "" || entry.partial !== "" || entry.files !== "[]" || JSON.parse(entry.steps).some(line => !(line.hook && line.ok))))
        return null
    }
    return live
  }

  // Another thread on screen starts at its end.
  onModelChanged: {
    changes++
    timeline.following = true
    unseen = 0
    seen = {}
    streams = {}
    held = ""
    released = ""
    holdingCard = false
  }

  // The keyboard is inside an entry, in a form being written, not on the list.
  readonly property bool inEntry: !timeline.activeFocus && Focus.within(Window.activeFocusItem, timeline.contentItem)

  // The keyboard is on the timeline or in the entry it is on.
  readonly property bool keyboard: timeline.activeFocus || (timeline.currentItem !== null && Focus.within(Window.activeFocusItem, timeline.currentItem))

  // Seconds of silence after which a working team is said to have no news.
  readonly property int quiet: 600

  // Seconds of silence after which a speaker's next line starts a new turn.
  readonly property int pause: 120

  // Whether the line at `index` is said by the speaker of the line just before
  // it, yours after yours or the same agent's after its own, with no longer
  // pause between them. A delegate may ask with its old index while the
  // entries change under it.
  function continues(index) {
    if (index <= 0 || index >= timeline.model.count)
      return false
    const previous = timeline.model.get(index - 1)
    const current = timeline.model.get(index)
    const apart = ["request", "work", "note", "worked"]
    return !apart.includes(previous.kind) && !apart.includes(current.kind)
      && previous.who === current.who && current.at - previous.at < root.pause
  }

  implicitHeight: timeline.contentHeight + timeline.topMargin + timeline.bottomMargin

  ListView {
    id: timeline

    property bool following: true
    onFollowingChanged: if (following) { root.unseen = 0; root.seen = {} }

    // Keeps the newest entry in view: its end, or the top of a turn streaming
    // taller than the view.
    function follow() {
      if (!following)
        return
      const last = count - 1
      const entry = itemAtIndex(last)
      if (entry && entry.streaming && entry.key !== root.released && entry.height > root.height - topMargin - bottomMargin)
        root.held = entry.key
      const heldRow = root.held !== "" ? root.rowOf(root.held) : -1
      // A held entry that fits shows whole, its bottom with it.
      const held = heldRow >= 0 ? itemAtIndex(heldRow) : null
      if (heldRow >= 0 && !(held && held.height <= root.height - topMargin - bottomMargin))
        positionViewAtIndex(heldRow, ListView.Beginning)
      else
        positionViewAtEnd()
    }

    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: Math.min(root.height, contentHeight + topMargin + bottomMargin)
    clip: true
    // An entry's outline never lies on the clip's edge, where a fractional scale
    // would cut it.
    topMargin: 1
    bottomMargin: 1
    spacing: 0
    model: root.model
    footer: workingRow
    onMovementEnded: following = atYEnd
    onContentHeightChanged: if (following) Qt.callLater(follow)
    onCountChanged: if (following) Qt.callLater(follow)

    // No entry is current until the keyboard comes, so nothing pulls the view.
    currentIndex: -1
    activeFocusOnTab: true
    keyNavigationEnabled: true
    // Only the list itself taking the keyboard picks an entry: a field inside
    // an entry also makes the list's activeFocus true, and making an entry
    // current would take the keyboard from that field.
    onActiveFocusChanged: if (activeFocus && Window.activeFocusItem === timeline && (currentIndex < 0 || currentIndex >= count)) currentIndex = count - 1
    onCurrentIndexChanged: if (!root.inEntry) following = currentIndex === count - 1
    // Entries beyond the view are kept for two views each way, so a form
    // scrolled away from while written in is not rebuilt.
    cacheBuffer: root.height * 2
    Keys.onPressed: event => {
      const page = { [Qt.Key_PageDown]: 5, [Qt.Key_PageUp]: -5 }[event.key]
      if (page !== undefined)
        currentIndex = Math.max(0, Math.min(count - 1, currentIndex + page))
      else if (event.key === Qt.Key_Home)
        currentIndex = 0
      else if (event.key === Qt.Key_End)
        root.jump()
      else
        return
      event.accepted = true
    }

    // Removed entries fade; what they leave behind closes up instead of jumping.
    remove: Transition {
      NumberAnimation { property: "opacity"; to: 0; duration: 140 }
    }
    displaced: Transition {
      NumberAnimation { property: "y"; duration: 180; easing.type: Easing.OutCubic }
    }

    delegate: Item {
      id: entry

      required property int index
      required property string kind
      required property string key
      required property string who
      required property string text
      required property bool mine
      required property bool note
      required property string stamp
      required property real at
      required property bool streaming
      required property string partial
      required property string steps
      required property string files
      required property bool fresh
      required property bool pending
      required property string work

      // Entries are set apart by a margin above each one, so one that draws
      // nothing leaves no gap.
      readonly property int gap: Theme.space.line
      readonly property string role: root.revision >= 0 && kind === "request" && root.requestsShown ? root.roleAt(index) : kind
      readonly property alias content: slot.item
      readonly property bool drawn: slot.status === Loader.Ready && slot.item.implicitHeight > 0
      readonly property bool selected: ListView.isCurrentItem && root.keyboard
      readonly property bool rises: kind === "request" || kind === "work"

      width: timeline.width
      height: drawn ? slot.height + gap : 0
      // Not tied to the content's `visible`, which follows the page that holds
      // the thread: hidden, every entry would measure 0 and the view fall to its top.
      clip: !drawn

      Loader {
        id: slot
        y: entry.gap
        width: entry.width
        sourceComponent: ({ card: request, answer: answer, team: team, turn: turn, work: handed, note: teamNote, worked: worked, speech: speech })[entry.role] || null

        FocusRing { shown: entry.selected; anchors.margins: 0 }
      }

      // A new line slides in from its speaker's side, a request or a work
      // handed down rises from below. What the conversation held before it
      // opened is just there.
      transform: Translate { id: shift }
      ListView.onAdd: if (entry.fresh) arrive.start()
      ParallelAnimation {
        id: arrive
        NumberAnimation { target: entry; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
        NumberAnimation {
          target: shift
          property: entry.rises ? "y" : "x"
          from: entry.rises ? 16 : entry.mine ? 28 : -28
          to: 0
          duration: 300
          easing.type: Easing.OutCubic
        }
      }

      Component {
        id: speech
        SpeechTurn {
          width: entry.width
          who: entry.who
          text: entry.text
          mine: entry.mine
          pending: entry.pending
          note: entry.note
          stamp: entry.stamp
          files: entry.files
          continued: root.revision >= 0 && root.continues(entry.index)
        }
      }

      Component {
        id: request
        RequestDecision {
          width: entry.width
          key: entry.key
          stamp: entry.stamp
          onSent: keyboard => root.typing = keyboard ? entry.key : ""
        }
      }

      Component {
        id: answer
        AnswerBubble {
          id: said
          // The keyboard was in the card that this answer replaces.
          Component.onCompleted: if (root.typing === entry.key) {
            root.typing = ""
            timeline.currentIndex = -1
            root.jump()
            root.answered()
          }
          readonly property var asked: Omunculus.requests.find(item => item.id === entry.key) || null
          readonly property var reply: Omunculus.replies[entry.key] || null
          width: entry.width
          asker: asked ? Requests.asker(asked) : ""
          route: asked ? Requests.route(asked, Omunculus.noted[entry.key]) : []
          question: asked ? Requests.question(asked, Omunculus.noted[entry.key]) : ""
          readonly property var wanted: asked ? Requests.granted(asked) : null
          readonly property var job: asked ? Omunculus.work(asked.work_id || "") : null
          readonly property var place: Omunculus.workspaceOf(job ? job.workspace || "" : "")
          unlock: Requests.unlocks(wanted, place.root)
          choice: reply ? Requests.chose(reply.option, wanted !== null, asked ? { who: Requests.label(asked.requester), stage: job && job.stage ? job.stage : "", folder: place.name || "" } : undefined) : ""
          body: reply && reply.body !== reply.option ? reply.body : ""
          stamp: reply && reply.stamp ? reply.stamp : entry.stamp
        }
      }

      Component {
        id: team
        TeamRow {
          width: entry.width
          key: entry.key
          stamp: entry.stamp
        }
      }

      Component {
        id: handed
        SubWorkBlock {
          width: entry.width
          work: entry.key
          nesting: root.nesting
          stamp: entry.stamp
          onOpened: work => root.openWork(work)
        }
      }

      Component {
        id: teamNote
        TeamNote {
          width: entry.width
          who: entry.who
          text: entry.text
          stamp: entry.stamp
          unfolded: root.finished && entry.index === root.newestNote
          result: root.finished && entry.index === root.newestNote
        }
      }

      Component {
        id: worked
        LogLine {
          width: entry.width
          names: [entry.who]
          // A run of the thread's own that failed: its error under "failed".
          readonly property bool why: entry.text.startsWith("failed: ")
          text: why ? "failed" : entry.text
          detail: why ? entry.text.slice(8) : ""
          failed: entry.text.startsWith("failed")
          icon: entry.text.startsWith("failed") ? "warning" : "check"
          tone: entry.text.startsWith("failed") ? Theme.error : Theme.dim
          stamp: entry.stamp
        }
      }

      Component {
        id: turn
        AgentTurn {
          width: entry.width
          run: entry.key
          who: entry.who
          text: entry.text
          partial: entry.partial
          streaming: entry.streaming
          steps: entry.steps
          files: entry.files
          stamp: entry.stamp
          continued: root.revision >= 0 && root.continues(entry.index)
          work: entry.work
          selected: entry.selected
          onLogged: work => root.openLog(work)
        }
      }
    }
  }

  // The live line: who works for the thread, the one at work last, in its
  // tone, with its clock; what it does under them; a long silence after it.
  Component {
    id: workingRow
    Item {
      readonly property var at: root.working
      readonly property real silence: Omunculus.lastEventAt > 0 ? Omunculus.tick - Omunculus.lastEventAt : 0
      width: timeline.width
      height: at ? line.y + line.implicitHeight : 0
      visible: at !== null
      LogLine {
        id: line
        y: Theme.space.inset
        width: parent.width
        live: true
        tone: parent.at ? Omunculus.toneOf(parent.at.agent) : Theme.dim
        names: parent.at ? parent.at.chain.concat([parent.at.agent]) : []
        text: parent.at ? "working" + (parent.at.since !== null ? " " + Progress.clock(Omunculus.tick - parent.at.since) : "") + (parent.at.round > 1 ? " · round " + parent.at.round : "") : ""
        detail: parent.at ? Progress.lively(parent.at.doing, parent.at.since, Omunculus.tick) + (parent.silence > root.quiet ? " · no news for " + Progress.duration(parent.silence) : "") : ""
      }
    }
  }

  // Whether the newest question's form ends below the view, where its
  // actions float on the bottom edge (QuestionForm); the pill goes above them.
  readonly property bool formFloats: {
    // Read first, so the view's scrolling and size update it.
    const shown = timeline.contentY
    const tall = timeline.height
    const row = newestCard !== "" ? rowOf(newestCard) : -1
    const entry = row >= 0 ? timeline.itemAtIndex(row) : null
    if (!entry || !entry.content || !entry.content.form)
      return false
    const top = entry.y - shown
    return top < tall && top + entry.height > tall
  }

  NewPill {
    anchors {
      horizontalCenter: parent.horizontalCenter
      bottom: parent.bottom
      // Over a floating form's actions: a row of them, two when narrow.
      bottomMargin: Theme.space.gap + (root.formFloats ? Theme.size.control + Theme.space.gap + (root.width < Theme.size.measureFrom ? Theme.size.control : 0) : 0)
    }
    count: root.unseen
    onClicked: root.jump()
  }

  Label {
    anchors.centerIn: parent
    visible: timeline.count === 0
    text: root.emptyText
    color: Theme.dim
    font.pixelSize: Theme.type.meta.size
    font.letterSpacing: Theme.type.meta.tracking
  }
}
