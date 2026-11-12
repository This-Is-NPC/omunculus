pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Pending.js" as Pending
import "kit/client/Requests.js" as Requests
import "kit/client/Time.js" as Time
import "kit/ui/focus.js" as Focus
import "kit/ui"

// TimelineView is one thread of the conversation. The main thread is the
// dialogue and the whole history of the conversation, in time order: what you
// and the agent you write to said, each work handed down and each stage
// started as a line of the log, every request addressed to you as a card
// (RequestDecision) answered in place and, once answered, kept with the answer
// given, and what the agents asked one another as a compact line (TeamRow);
// what each run did is the tree's. A work's own thread also holds a work
// handed down as a SubWorkBlock that unfolds into its own thread nested here,
// and the notes its agents left (TeamNote).
// Like a chat, it sits on the bottom and grows upwards, and it follows new
// entries unless you scrolled up to read; then a pill counts what arrived out
// of view and leads back to it. A turn streaming taller than the view is held
// by its top, so its first words stay readable. The dialogue opens, above its
// first entry, on a mark that says where the conversation starts. From the keyboard, Tab reaches
// it on the newest entry: ↑/↓ and PgUp/PgDn move, Home goes to the first and
// End back to the newest, and Tab moves into the tools of the entry it is on.
// While an agent works for the thread, a live line at its end says who, from
// the agent you wrote to down to the one at work, what that one does, in a
// plain verb, and for how long, unless that agent's own turn streams here and
// says it. Its
// implicit height is its entries', for a thread nested in a block, which says
// itself that its agents work.
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
  // Whether this is the main thread, the dialogue.
  readonly property bool dialogue: thread === ""
  // Counts changes to the entries, so each line knows again whether it
  // continues the turn before it.
  property int revision: 0
  // Counts every change to the entries, a turn streaming included.
  property int changes: 0

  // How many entries lie below the view: the ones the NEW pill counts. An
  // entry that draws nothing, an empty turn or a request the queue holds, is
  // not news, and a thread that fits has none.
  readonly property int below: {
    if (changes < 0 || timeline.contentHeight < 0 || timeline.contentHeight + timeline.edge <= timeline.height)
      return 0
    const last = timeline.indexAt(1, timeline.contentY + timeline.height - 2)
    let count = 0
    for (let row = last < 0 ? timeline.count : last + 1; row < timeline.count; row++) {
      const entry = timeline.itemAtIndex(row)
      if (!entry || entry.drawn)
        count++
    }
    return count
  }
  // The streaming turn whose top the view holds, and the one you jumped to
  // the end of, which it does not hold.
  property string held: ""
  property string released: ""
  // A work is wanted as a transcript of its own.
  signal openWork(string work)
  // The log of a work is wanted ("" for the conversation's own).
  signal openLog(string work)
  // The requests no other request gathers; the rest are its climb.
  readonly property var contained: Requests.contained(Omunculus.requests)

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

  // Brings the oldest request waiting on you into view and puts the keyboard
  // in it; false when none waits.
  function showAsk() {
    const first = Pending.queue(Omunculus.requests, Omunculus.me)[0]
    const row = first ? rowOf(first.id) : -1
    if (row < 0)
      return false
    reveal(first.id, true)
    Qt.callLater(() => {
      const entry = timeline.itemAtIndex(row)
      if (entry && entry.content && entry.content.focusFirst)
        entry.content.focusFirst()
    })
    return true
  }

  // How the entry at `row` shows: "turn", "note" and "speech" for what is
  // said; "mark" for a work handed down in the dialogue or a stage started,
  // "work" for a work handed down in a work's thread; "ask" for a request
  // addressed to you, waiting or answered, and "team" for the agents' own;
  // "none" for one another gathers or not read yet.
  function roleAt(row) {
    const entry = model.get(row)
    if (!entry)
      return "none"
    if (entry.kind === "work")
      return dialogue ? "mark" : "work"
    if (entry.kind !== "request")
      return ["turn", "note", "mark"].includes(entry.kind) ? entry.kind : "speech"
    if (!requestsShown)
      return "none"
    const place = Pending.place(Omunculus.requests.find(item => item.id === entry.key), { me: Omunculus.me, contained: contained })
    return place === "history" ? "ask" : place
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
  // Goes to the end and follows it again, past a turn still streaming.
  function jump() {
    const newest = timeline.count > 0 ? timeline.model.get(timeline.count - 1) : null
    root.released = newest && newest.streaming ? newest.key : ""
    root.held = ""
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
    function onDataChanged() { root.changes++ }
    function onRowsInserted() {
      root.revision++
      root.changes++
    }
    function onRowsRemoved() {
      root.revision++
      root.changes++
    }
  }

  // Who works for this thread, as {chain, agent, doing, since, round}
  // (Progress.live); null when no one does, in a thread nested in a block, or
  // while that agent's own turn streams here and shows it. In the dialogue it
  // is whoever works, down the team, at every width.
  readonly property var working: {
    const front = Omunculus.agent || Omunculus.lastAgent
    const live = nesting > 0 ? null : Progress.live(Omunculus.progress, thread, front)
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
    held = ""
    released = ""
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
    const apart = ["request", "mark", "work", "note"]
    return !apart.includes(previous.kind) && !apart.includes(current.kind)
      && previous.who === current.who && current.at - previous.at < root.pause
  }

  implicitHeight: timeline.contentHeight + timeline.edge

  ListView {
    id: timeline

    property bool following: true

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
      if (heldRow >= 0 && !(held && held.height <= root.height - topMargin - bottomMargin)) {
        positionViewAtIndex(heldRow, ListView.Beginning)
        // The entry before it shows whole above it, never cut by the view.
        const before = heldRow > 0 ? itemAtIndex(heldRow - 1) : null
        if (before)
          contentY = Math.max(originY - topMargin, contentY - before.height)
      } else
        positionViewAtEnd()
    }

    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: newerBand }
    height: Math.min(root.height - earlierBand - newerBand, contentHeight + edge)
    clip: true
    // An entry's outline never lies on the clip's edge, where a fractional scale
    // would cut it. Once the thread outgrows the view, each end has a band for
    // a pill, so a pill never covers an entry; the band does not follow the
    // pill, whose count follows the view.
    readonly property bool scrolls: contentHeight + edge > Math.min(root.height, Window.height / 2)
    // The two pixels of an entry's outline, one at each end.
    readonly property int edge: 2
    // The bands above and below the view hold the pills, so none covers a line.
    readonly property real earlierBand: scrolls ? earlier.height + Theme.space.gap + Theme.space.gap : 0
    readonly property real newerBand: scrolls ? newer.anchors.bottomMargin + newer.height + Theme.space.gap : 0
    topMargin: edge / 2
    bottomMargin: edge / 2
    spacing: 0
    model: root.model
    header: root.dialogue ? startMark : null
    footer: workingRow
    // Only the person's own scrolling ends it, and the end is within a row:
    // the live row under the entries changes height as work goes on.
    onMovementEnded: following = contentHeight - (contentY + height) < Theme.size.control
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
    onCurrentIndexChanged: if (!root.inEntry && currentIndex >= 0) following = currentIndex === count - 1
    // Entries beyond the view are kept for two views each way, so a form
    // scrolled away from while written in is not rebuilt.
    cacheBuffer: Window.height * 2
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
      required property string subject

      // Entries are set apart by a margin above each one, so one that draws
      // nothing leaves no gap.
      readonly property int gap: Theme.space.line
      readonly property string role: root.revision >= 0 ? root.roleAt(index) : kind
      readonly property alias content: slot.item
      readonly property bool drawn: slot.status === Loader.Ready && slot.item.implicitHeight > 0
      readonly property bool selected: ListView.isCurrentItem && root.keyboard
      readonly property bool rises: kind === "request" || kind === "mark" || kind === "work"

      width: timeline.width
      height: drawn ? slot.height + gap : 0
      // Not tied to the content's `visible`, which follows the page that holds
      // the thread: hidden, every entry would measure 0 and the view fall to its top.
      clip: !drawn

      Loader {
        id: slot
        y: entry.gap
        width: entry.width
        sourceComponent: ({ mark: mark, ask: ask, team: team, turn: turn, work: handed, note: teamNote, speech: speech })[entry.role] || null

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
          subject: entry.subject
          continued: root.revision >= 0 && root.continues(entry.index)
        }
      }

      // A stage started, a work handed down: a line of the log, in time.
      Component {
        id: mark
        LogLine {
          readonly property var record: entry.kind === "work" ? Omunculus.work(entry.key) : null
          readonly property string assignee: record ? Omunculus.agentOf(record) : ""
          width: entry.width
          icon: entry.kind === "work" ? "branch" : "chevron-right"
          names: [entry.who, assignee].filter(name => name !== "")
          text: entry.kind === "work" ? "handed down \u201c" + Omunculus.titleOf(entry.key) + "\u201d" : entry.text
          // Where the root work stood at this line, so the latest one says where it is.
          stages: entry.kind === "work" || !Omunculus.progress ? [] : Progress.trail(Omunculus.progress.flat, Omunculus.journeys, entry.key, entry.at)
          stamp: entry.stamp
        }
      }

      // A request addressed to you: the card that answers it while it waits,
      // and with your answer once it is settled.
      Component {
        id: ask
        RequestDecision {
          width: entry.width
          key: entry.key
          stamp: entry.stamp
        }
      }

      Component {
        id: team
        TeamRow {
          width: entry.width
          key: entry.key
          stamp: entry.stamp
          // In the chat it is history; the work's thread may decide it.
          decidable: !root.dialogue
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
        id: turn
        AgentTurn {
          width: entry.width
          run: entry.key
          who: entry.who
          text: entry.text
          partial: entry.partial
          streaming: entry.streaming
          // The dialogue has the words only: the steps of a run are the tree's.
          steps: root.dialogue ? "[]" : entry.steps
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

  // The start of the dialogue, as the first thing in it once the view is
  // scrolled up to it.
  Component {
    id: startMark
    Item {
      readonly property string began: Omunculus.conversation ? Time.began(Omunculus.conversation.created_at, Date.now()) : ""
      width: timeline.width
      height: timeline.count > 0 ? mark.implicitHeight + Theme.space.gap : 0
      visible: timeline.count > 0
      Kicker {
        id: mark
        width: parent.width
        // Short where the line would not fit.
        text: (width < 460 ? "Started" : "Start of the conversation") + (began !== "" ? Theme.type.meta.separator + began : "")
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

  // The entries above the view: an opened conversation lands at its end, and
  // this says that the history goes on above, and leads to its start.
  NewPill {
    id: earlier
    anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Theme.space.gap }
    above: true
    word: "EARLIER"
    tip: "Show the start of the conversation"
    count: root.revision < 0 || timeline.contentY <= timeline.originY + 4 ? 0 : Math.max(0, timeline.indexAt(1, timeline.contentY + 2))
    onClicked: {
      timeline.following = false
      timeline.positionViewAtBeginning()
    }
  }

  NewPill {
    id: newer
    anchors {
      horizontalCenter: parent.horizontalCenter
      bottom: parent.bottom
      bottomMargin: Theme.space.gap
    }
    count: root.below
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
