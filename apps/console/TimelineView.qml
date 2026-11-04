pragma ComponentBehavior: Bound
import QtQuick
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
// work handed down is a SubWorkBlock where it was, which unfolds into its own
// thread nested here. A question for you that arrives while the view follows
// is held by its top. Its implicit height is its entries', for a thread nested
// in a block.
Item {
  id: root

  // The thread shown: "" for the main one, or a work's.
  property string thread: ""
  // How deep this thread is nested in sub-work blocks: 0 for a page's own.
  property int nesting: 0
  readonly property ListModel model: Omunculus.thread(thread)
  property string emptyText: "SAY WHAT YOU NEED"
  // Whether requests show where they were made; beside the map they show on
  // the node that asked instead.
  property bool requestsShown: true
  // Counts changes to the entries, so each line knows again whether it
  // continues the turn before it.
  property int revision: 0

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
  // the keyboard is inside an entry, where the view stays as it is kept.
  function reveal(key) {
    const row = rowOf(key)
    if (row < 0)
      return
    if (!inEntry)
      timeline.following = false
    timeline.positionViewAtIndex(row, ListView.Center)
  }

  // The card of the newest question for you, once its entry exists.
  function cardItem() {
    const row = newestCard !== "" ? rowOf(newestCard) : -1
    const entry = row >= 0 ? timeline.itemAtIndex(row) : null
    return entry ? entry.content : null
  }

  // Brings the newest question into view and puts the keyboard in its words.
  function focusCard() {
    if (newestCard === "")
      return
    reveal(newestCard)
    Qt.callLater(() => {
      const card = cardItem()
      if (!card)
        return
      if (card.kind === "needs-you")
        card.focusWords()
      else
        card.focusDecision()
    })
  }

  // Whether the keyboard is inside the card of a question.
  function cardFocused() {
    const card = cardItem()
    return !!card && Focus.within(Window.activeFocusItem, card)
  }

  // How the entry at `row` shows: "card" for a request waiting on you,
  // "answer" for one you answered, "team" for the rest, "none" for one
  // another gathers; "turn", "work" and "speech" for the rest of the thread.
  function roleAt(row) {
    const entry = model.get(row)
    if (!entry)
      return "none"
    if (entry.kind !== "request")
      return ["turn", "work"].includes(entry.kind) ? entry.kind : "speech"
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
  onNewestCardChanged: {
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
      for (let row = first; row <= last; row++) {
        const entry = root.model.get(row)
        if (entry.streaming)
          root.streams[entry.key] = true
        root.arrived(entry.key)
      }
    }
    function onRowsRemoved() { root.revision++ }
  }

  // Another thread on screen starts at its end.
  onModelChanged: {
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
    return !["request", "work"].includes(previous.kind) && !["request", "work"].includes(current.kind)
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
      if (heldRow >= 0)
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

      // Entries are set apart by a margin above each one, so one that draws
      // nothing leaves no gap.
      readonly property int gap: 4
      readonly property string role: root.revision >= 0 && kind === "request" && root.requestsShown ? root.roleAt(index) : kind
      readonly property alias content: slot.item
      readonly property bool drawn: !!slot.item && slot.item.visible && slot.item.implicitHeight > 0
      readonly property bool selected: ListView.isCurrentItem && root.keyboard
      readonly property bool rises: kind === "request" || kind === "work"

      width: timeline.width
      height: drawn ? slot.height + gap : 0
      // Not `visible: drawn`: an item's visible follows its parent's, so the
      // entry would never see its content shown.
      clip: !drawn

      Loader {
        id: slot
        y: entry.gap
        width: entry.width
        sourceComponent: ({ card: request, answer: answer, team: team, turn: turn, work: handed, speech: speech })[entry.role] || null

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
          asker: asked ? Requests.label(asked.requester) : ""
          question: asked ? String(asked.reason || "") : ""
          body: reply ? reply.body || reply.option : ""
          stamp: entry.stamp
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
        }
      }
    }
  }

  NewPill {
    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 10 }
    count: root.unseen
    onClicked: root.jump()
  }

  Label {
    anchors.centerIn: parent
    visible: timeline.count === 0
    text: root.emptyText
    color: Theme.dim
    font.pixelSize: 11
    font.letterSpacing: 2
  }
}
