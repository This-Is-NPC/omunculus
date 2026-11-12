pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Pending.js" as Pending
import "kit/client/Tree.js" as Tree
import "kit/client/Time.js" as Time
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui/focus.js" as Focus
import "kit/ui"

// TimelineView is the chat: the conversation as a lineage stream, the rows of
// Tree.stream. What you and the agent you write to said come first, in time
// order; each work handed down hangs under them as a level of the hierarchy
// (LineageRow), with the stages of its workflow (StagePath), the requests it
// made (RequestDecision, TeamRow, attached by a connector from their level and
// answered in place), and what it handed down: a work, finished works folded
// into one line, or works that ran at once as lanes (ForkBlock). A chevron
// folds or unfolds a level; its arrow opens the work as a scope of its own:
// `scope` set to a work, the view shows only that branch, and in it each work's
// own thread, its runs with their tool calls and the notes its agents left.
// Like a chat, it sits on the bottom and grows upwards, and it follows new
// entries unless you scrolled up to read; then a pill counts what arrived out
// of view and leads back to it. A turn streaming taller than the view is held
// by its top, so its first words stay readable. The conversation opens, above
// its first entry, on a mark that says where it starts. From the keyboard, Tab
// reaches it on the newest row: up/down and PgUp/PgDn move, Home goes to the
// first and End back to the newest, and Tab moves into the tools of the row it
// is on. While an agent works, a live line at its end says who, from the agent
// you wrote to down to the one at work, what that one does, in a plain verb,
// and for how long, unless that agent's own turn streams here and says it.
Item {
  id: root

  // The work the view is kept to: "" for the whole conversation, whose words
  // come first, or a work, whose branch alone shows.
  property string scope: ""
  property string emptyText: ""
  // Whether requests show where they were made; beside the map they show on
  // the node that asked instead.
  property bool requestsShown: true
  // Whether this is the whole conversation, the dialogue.
  readonly property bool dialogue: scope === ""
  // The thread of the scope's own work, whose entries the live line reads.
  readonly property string thread: dialogue ? "" : Omunculus.threadOf(scope)
  readonly property ListModel model: Omunculus.thread(thread)
  // Counts the entries added or removed in any thread, and every change to
  // them, a turn streaming included.
  readonly property int revision: Omunculus.appended
  readonly property int changes: Omunculus.appended + Omunculus.edited
  // The column of a level, narrower on a phone, and where the first one
  // starts: the room the connector of a request crosses.
  readonly property real unit: Breakpoints.tight(width) ? Theme.size.mark : Theme.size.gutter
  readonly property real origin: Breakpoints.tight(width) ? unit : unit * 2
  // Folds and unfolds the person made, row key -> bool: a work's, "fold:<work>".
  property var opened: ({})
  // The rows, from Tree.stream, and the same by key.
  property var stream: []
  property var rowMap: ({})

  // How many rows lie below the view: the ones the NEW pill counts. A row
  // that draws nothing, an empty turn, is not news, and a thread that fits has
  // none.
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
  // The key of the streaming turn whose top the view holds, and of the one
  // you jumped to the end of, which it does not hold.
  property string held: ""
  property string released: ""
  // A work is wanted as a scope of its own.
  signal openWork(string work)
  // The log of a work is wanted ("" for the conversation's own).
  signal openLog(string work)

  // How an entry of a thread shows: "turn", "note" or "speech"; "none" for a
  // work, a stage or a request, which the lineage draws.
  function roleOf(kind) {
    return ["work", "mark", "request"].includes(kind) ? "none" : ["turn", "note"].includes(kind) ? kind : "speech"
  }

  // The entries of a thread that are said, as Tree.stream wants them. Yours,
  // still on its way, come last.
  function spoken(key) {
    const list = Omunculus.thread(key)
    const found = []
    for (let row = 0; row < list.count; row++) {
      const entry = list.get(row)
      const role = roleOf(entry.kind)
      if (role !== "none")
        found.push({ index: row, at: entry.pending ? Infinity : entry.at, who: entry.who, role: role })
    }
    return found
  }

  // Builds the rows again, once however much changed at once.
  function refresh() {
    const flat = Omunculus.progress ? Omunculus.progress.flat : []
    const counts = {}
    for (const node of flat) {
      const key = Omunculus.threadOf(node.work)
      counts[node.work] = key !== "" ? Omunculus.thread(key).count : 0
    }
    stream = Tree.stream({
      progress: Omunculus.progress, scope: scope, opened: opened, me: Omunculus.me, counts: counts, pause: pause,
      requests: requestsShown ? Omunculus.requests : [],
      dialogue: dialogue ? spoken("") : [],
      details: work => Omunculus.threadOf(work) === "" ? [] : spoken(Omunculus.threadOf(work))
    })
    const map = {}
    for (const row of stream)
      map[row.key] = row
    rowMap = map
    let at = 0
    for (; at < stream.length; at++) {
      const key = stream[at].key
      if (at < rows.count && rows.get(at).key === key)
        continue
      let found = -1
      for (let next = at + 1; next < rows.count && found < 0; next++) {
        if (rows.get(next).key === key)
          found = next
      }
      if (found >= 0)
        rows.move(found, at, 1)
      else
        rows.insert(at, { key: key, kind: stream[at].kind, fresh: Omunculus.loaded && !Omunculus.replaying })
    }
    if (rows.count > at)
      rows.remove(at, rows.count - at)
  }
  function later() { Qt.callLater(refresh) }

  ListModel { id: rows }

  Component.onCompleted: refresh()
  onScopeChanged: {
    rows.clear()
    timeline.following = true
    held = ""
    released = ""
    refresh()
  }
  onOpenedChanged: later()
  onRequestsShownChanged: later()
  Connections {
    target: Omunculus
    function onProgressChanged() { root.later() }
    function onRequestsChanged() { root.later() }
    function onAppendedChanged() { root.later() }
    function onMeChanged() { root.later() }
    // What the person sends or answers is seen at once, never as news.
    function onActed() { root.jump() }
  }

  // Folds or unfolds a level; a fold unfolds into its works.
  function toggle(key, now) {
    const next = Object.assign({}, opened)
    next[key] = now
    opened = next
  }

  // The row of the view showing `key`: a row's own key, a request's id or an
  // entry's key; -1 for none.
  function rowOf(key) {
    for (let row = 0; row < rows.count; row++) {
      const shown = stream[row]
      if (shown.key === key || shown.id === key || (shown.kind === "entry" && Omunculus.thread(shown.thread).get(shown.index).key === key))
        return row
    }
    return -1
  }

  // Brings the row of `key` into view, and stops following the end unless the
  // keyboard is inside a row, where the view stays as it is kept. A row that
  // takes the keyboard, or is taller than most of the view, starts at its top,
  // so a form shows its first questions.
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

  // The key of the newest note a work's agent left in the dialogue, or "".
  readonly property string newestNote: {
    if (revision < 0)
      return ""
    for (let row = stream.length - 1; row >= 0; row--) {
      if (stream[row].kind === "entry" && stream[row].role === "note" && stream[row].thread === "")
        return stream[row].key
    }
    return ""
  }
  // Whether the conversation's work is done: its closing note shows whole.
  readonly property bool finished: !!Omunculus.progress && Omunculus.progress.state === "done"
  // Goes to the end and follows it again, past a turn still streaming.
  function jump() {
    const newest = timeline.count > 0 ? timeline.itemAtIndex(timeline.count - 1) : null
    root.released = newest && newest.streaming ? newest.key : ""
    root.held = ""
    timeline.following = true
    if (timeline.currentIndex >= 0)
      timeline.currentIndex = timeline.count - 1
    timeline.positionViewAtEnd()
  }

  // Who works for this thread, as {chain, agent, doing, since, round}
  // (Progress.live); null when no one does, or while that agent's own turn
  // streams here and shows it. In the dialogue it is whoever works, down the
  // team, at every width.
  readonly property var working: {
    const front = Omunculus.agent || Omunculus.lastAgent
    const live = Progress.live(Omunculus.progress, scope, front)
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

  // The keyboard is inside a row, in a form being written, not on the list.
  readonly property bool inEntry: !timeline.activeFocus && Focus.within(Window.activeFocusItem, timeline.contentItem)

  // The keyboard is on the timeline or in the row it is on.
  readonly property bool keyboard: timeline.activeFocus || (timeline.currentItem !== null && Focus.within(Window.activeFocusItem, timeline.currentItem))

  // Seconds of silence after which a working team is said to have no news.
  readonly property int quiet: 600

  // Seconds of silence after which a speaker's next line starts a new turn.
  readonly property int pause: 120

  implicitHeight: timeline.contentHeight + timeline.edge

  ListView {
    id: timeline

    property bool following: true

    // Keeps the newest row in view: its end, or the top of a turn streaming
    // taller than the view.
    function follow() {
      if (!following)
        return
      const last = count - 1
      const entry = itemAtIndex(last)
      if (entry && entry.streaming && entry.key !== root.released && entry.height > root.height - topMargin - bottomMargin)
        root.held = entry.key
      const heldRow = root.held !== "" ? root.rowOf(root.held) : -1
      // A held row that fits shows whole, its bottom with it.
      const held = heldRow >= 0 ? itemAtIndex(heldRow) : null
      if (heldRow >= 0 && !(held && held.height <= root.height - topMargin - bottomMargin)) {
        positionViewAtIndex(heldRow, ListView.Beginning)
        // The row before it shows whole above it, never cut by the view.
        const before = heldRow > 0 ? itemAtIndex(heldRow - 1) : null
        if (before)
          contentY = Math.max(originY - topMargin, contentY - before.height)
      } else
        positionViewAtEnd()
    }

    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: newerBand }
    height: Math.min(root.height - earlierBand - newerBand, contentHeight + edge)
    clip: true
    // A row's outline never lies on the clip's edge, where a fractional scale
    // would cut it. Once the thread outgrows the view, each end has a band for
    // a pill, so a pill never covers a row; the band does not follow the
    // pill, whose count follows the view.
    readonly property bool scrolls: contentHeight + edge > Math.min(root.height, Window.height / 2)
    // The two pixels of a row's outline, one at each end.
    readonly property int edge: 2
    // The bands above and below the view hold the pills, so none covers a line.
    readonly property real earlierBand: scrolls ? earlier.height + Theme.space.gap + Theme.space.gap : 0
    readonly property real newerBand: scrolls ? newer.anchors.bottomMargin + newer.height + Theme.space.gap : 0
    topMargin: edge / 2
    bottomMargin: edge / 2
    spacing: 0
    model: rows
    header: root.dialogue ? startMark : null
    footer: workingRow
    // Only the person's own scrolling ends it, and the end is within a row:
    // the live row under the rows changes height as work goes on.
    onMovementEnded: following = contentHeight - (contentY + height) < Theme.size.control
    onContentHeightChanged: if (following) Qt.callLater(follow)
    onCountChanged: if (following) Qt.callLater(follow)

    // No row is current until the keyboard comes, so nothing pulls the view.
    currentIndex: -1
    activeFocusOnTab: true
    keyNavigationEnabled: true
    // Only the list itself taking the keyboard picks a row: a field inside
    // a row also makes the list's activeFocus true, and making a row
    // current would take the keyboard from that field.
    onActiveFocusChanged: if (activeFocus && Window.activeFocusItem === timeline && (currentIndex < 0 || currentIndex >= count)) currentIndex = count - 1
    onCurrentIndexChanged: if (!root.inEntry && currentIndex >= 0) following = currentIndex === count - 1
    // Rows beyond the view are kept for two views each way, so a form
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

    // Removed rows fade; what they leave behind closes up instead of jumping.
    remove: Transition {
      NumberAnimation { property: "opacity"; to: 0; duration: 140 }
    }
    displaced: Transition {
      NumberAnimation { property: "y"; duration: 180; easing.type: Easing.OutCubic }
    }

    delegate: Item {
      id: entry

      required property int index
      required property string key
      required property string kind
      required property bool fresh

      // The row as Tree.stream gave it, kept as it was while the view
      // builds the rows again, and for a said entry its record in the thread
      // it is in, read again whenever any thread changes; a blank one when it
      // is gone.
      property var row: null
      readonly property var record: row && row.kind === "entry" && root.changes >= 0 ? Omunculus.thread(row.thread).get(row.index) || blank : blank
      readonly property var blank: ({ key: "", who: "", text: "", mine: false, note: false, stamp: "", work: "", streaming: false, partial: "", steps: "[]", files: "[]", subject: "", pending: false })
      function adopt() {
        const next = root.rowMap[key]
        if (next)
          row = next
      }
      Component.onCompleted: adopt()
      Connections {
        target: root
        function onRowMapChanged() { entry.adopt() }
      }
      readonly property bool streaming: !!record && record.streaming
      readonly property bool mine: !!record && record.mine

      // Said words are set apart by a margin above each one, so one that draws
      // nothing leaves no gap; the levels of the hierarchy keep their lines whole.
      readonly property int gap: kind === "entry" && row && row.depth === 0 ? Theme.space.line : 0
      readonly property alias content: slot.item
      readonly property bool drawn: slot.status === Loader.Ready && slot.item.implicitHeight > 0
      readonly property bool selected: ListView.isCurrentItem && root.keyboard
      readonly property bool rises: kind !== "entry"

      width: timeline.width
      height: drawn ? slot.height + gap : 0
      // Not tied to the content's `visible`, which follows the page that holds
      // the thread: hidden, every row would measure 0 and the view fall to its top.
      clip: !drawn

      Loader {
        id: slot
        y: entry.gap
        width: entry.width
        sourceComponent: !entry.row ? null : ({
          work: work, fold: fold, fork: fork, stages: stages, ask: ask, team: ask, entry: entryRow
        })[entry.kind] || null

        FocusRing { shown: entry.selected; anchors.margins: 0 }
      }

      // A new row slides in from its speaker's side, a level or a request
      // rises from below. What the conversation held before it opened is just
      // there.
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

      // A work: its level.
      Component {
        id: work
        LineageRow {
          readonly property var node: entry.row.node
          readonly property var look: Tree.stateOf(node)
          width: entry.width
          depth: entry.row.depth
          rails: entry.row.rails
          last: entry.row.last
          stem: entry.row.stem
          unit: root.unit
          origin: root.origin
          agent: node.agent
          tone: Omunculus.toneOf(node.agent)
          title: node.title
          // Folded, what it handed down.
          meta: entry.row.kids > 0 && !entry.row.open ? Progress.below(Progress.kidsOf(node)) : ""
          state: look.state
          stateText: look.text
          folds: entry.row.kids > 0
          open: entry.row.open
          linked: node.work !== root.scope
          onToggled: root.toggle(node.work, !entry.row.open)
          onChosen: if (folds) root.toggle(node.work, !entry.row.open)
          onOpened: root.openWork(node.work)
        }
      }

      // Finished works gathered in one line.
      Component {
        id: fold
        LineageRow {
          readonly property var nodes: entry.row.nodes
          readonly property var last: nodes[nodes.length - 1]
          readonly property var look: Tree.stateOf(last)
          width: entry.width
          depth: entry.row.depth
          rails: entry.row.rails
          unit: root.unit
          origin: root.origin
          agent: Array.from(new Set(nodes.map(node => node.agent))).join(", ")
          tone: Omunculus.toneOf(last.agent)
          title: (nodes.length > 1 ? nodes.length + " folded" + Theme.type.meta.separator : "") + last.title
          meta: entry.row.entries + (entry.row.entries === 1 ? " entry" : " entries")
          state: look.state
          stateText: look.text
          folds: true
          linked: nodes.length === 1
          onToggled: root.toggle(entry.row.key, true)
          onChosen: root.toggle(entry.row.key, true)
          onOpened: root.openWork(last.work)
        }
      }

      // Works that ran at once.
      Component {
        id: fork
        ForkBlock {
          width: entry.width
          depth: entry.row.depth
          rails: entry.row.rails
          last: entry.row.last
          unit: root.unit
          origin: root.origin
          summary: entry.row.summary
          lanes: entry.row.nodes.map(node => ({
            work: node.work, agent: node.agent, tone: Omunculus.toneOf(node.agent), title: node.title,
            state: Tree.stateOf(node).state, stateText: Tree.stateOf(node).text
          }))
          onOpened: work => root.openWork(work)
        }
      }

      // A work's workflow, as a path.
      Component {
        id: stages
        Item {
          width: entry.width
          implicitHeight: path.implicitHeight + Theme.space.tight * 2
          Lifeline {
            depth: entry.row.depth
            rails: entry.row.rails
            line: entry.row.through ? "through" : "none"
            unit: root.unit
            origin: root.origin
          }
          StagePath {
            id: path
            x: root.origin + (entry.row.depth + 1) * root.unit
            y: Theme.space.tight
            width: parent.width - x - Theme.space.cell
            stages: entry.row.stages
          }
        }
      }

      // A request one of the works made, attached to it: the card that answers
      // it while it waits and, once settled, keeps your answer; between agents,
      // the exchange as a line.
      Component {
        id: ask
        Attached {
          readonly property var request: Omunculus.requests.find(item => item.id === entry.row.id) || null
          width: entry.width
          depth: entry.row.depth
          rails: entry.row.rails
          through: entry.row.through
          unit: root.unit
          origin: root.origin
          level: entry.row.level
          tone: entry.row.kind === "ask" ? Theme.warning : Theme.dim
          // The keyboard goes to the card's first field.
          function focusFirst() {
            if (inner.item && inner.item.focusFirst)
              inner.item.focusFirst()
          }
          Loader {
            id: inner
            width: parent ? parent.width : 0
            sourceComponent: entry.row.kind === "ask" ? card : exchange
          }
          Component {
            id: card
            RequestDecision {
              key: entry.row.id
              stamp: request ? Time.clock(request.created_at, Date.now()) : ""
              collapsible: true
            }
          }
          Component {
            id: exchange
            TeamRow {
              key: entry.row.id
              stamp: request ? Time.clock(request.created_at, Date.now()) : ""
              // In the chat it is history; a scope may decide it.
              decidable: !root.dialogue
            }
          }
        }
      }

      // Something said: yours, an agent's, a note, a run with its steps.
      Component {
        id: entryRow
        Item {
          readonly property real inset: entry.row.depth > 0 ? root.origin + (entry.row.depth + 1) * root.unit : 0
          readonly property alias content: words.item
          width: entry.width
          implicitHeight: words.item ? words.item.implicitHeight : 0
          Lifeline {
            visible: entry.row.depth > 0
            depth: entry.row.depth
            rails: entry.row.rails
            line: entry.row.through ? "through" : "none"
            unit: root.unit
            origin: root.origin
          }
          Loader {
            id: words
            x: parent.inset
            width: parent.width - x
            sourceComponent: ({ speech: speech, turn: turn, note: teamNote })[entry.row.role] || null
          }
        }
      }

      Component {
        id: speech
        SpeechTurn {
          width: parent ? parent.width : 0
          who: entry.record.who
          text: entry.record.text
          mine: entry.record.mine
          pending: entry.record.pending
          note: entry.record.note
          stamp: entry.record.stamp
          files: entry.record.files
          subject: entry.record.subject
          continued: entry.row.continued
        }
      }

      Component {
        id: teamNote
        TeamNote {
          width: parent ? parent.width : 0
          who: entry.record.who
          text: entry.record.text
          stamp: entry.record.stamp
          unfolded: root.finished && entry.row.key === root.newestNote
          result: root.finished && entry.row.key === root.newestNote
        }
      }

      Component {
        id: turn
        AgentTurn {
          width: parent ? parent.width : 0
          run: entry.record.key
          who: entry.record.who
          text: entry.record.text
          partial: entry.record.partial
          streaming: entry.record.streaming
          // The dialogue has the words only: the steps of a run are a scope's.
          steps: root.dialogue ? "[]" : entry.record.steps
          files: entry.record.files
          stamp: entry.record.stamp
          continued: entry.row.continued
          work: entry.record.work
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
