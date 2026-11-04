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
// bubble, and what the team asked among itself is one muted line, the lines of
// a stretch gathered under "Team activity". A question for you that arrives
// while the view follows is held by its top.
Item {
  id: root

  // The thread shown: "" for the main one, or a work's.
  property string thread: ""
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
  // The activity of the conversation, or null before it is wired in.
  readonly property var activity: Omunculus.activity || null
  // The requests no other request gathers; the rest are its climb.
  readonly property var contained: Requests.contained(Omunculus.requests)
  // Which stretches of team rows the person opened (true) or closed (false), by first key.
  property var opened: ({})

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

  // Brings the entry of `key` into view, and stops following the end.
  function reveal(key) {
    const row = rowOf(key)
    if (row < 0)
      return
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
  // another gathers; "turn" and "speech" for the rest of the thread.
  function roleAt(row) {
    const entry = model.get(row)
    if (!entry)
      return "none"
    if (entry.kind !== "request")
      return entry.kind === "turn" ? "turn" : "speech"
    const request = Omunculus.requests.find(item => item.id === entry.key)
    if (!request || contained.has(entry.key))
      return "none"
    if (Requests.pending(request) && Requests.human(request.arbiter))
      return "card"
    const answer = Omunculus.replies[entry.key]
    return answer && answer.who === "you" ? "answer" : "team"
  }

  // The stretch of team rows around `row`: where it starts, how many rows it
  // has, which of them this is, and whether the team is still at work in it.
  function stretch(row) {
    if (revision < 0 || row < 0 || row >= model.count)
      return null
    let first = row
    let last = row
    for (let at = row - 1; at >= 0 && ["team", "none"].includes(roleAt(at)); at--)
      if (roleAt(at) === "team") first = at
    for (let at = row + 1; at < model.count && ["team", "none"].includes(roleAt(at)); at++)
      if (roleAt(at) === "team") last = at
    let size = 0
    let place = 0
    for (let at = first; at <= last; at++) {
      if (roleAt(at) !== "team")
        continue
      size++
      if (at < row) place++
    }
    let live = !!activity && activity.state === "working"
    for (let at = last + 1; live && at < model.count; at++)
      live = roleAt(at) === "none"
    return { first: model.get(first).key, size: size, place: place, live: live, span: model.get(last).at - model.get(first).at }
  }

  // The header of a stretch: while the team works, for how long; after, how long it did.
  function stretchTitle(group) {
    const minutes = Math.round(group.span / 60)
    if (group.live)
      return "Team is working  " + Math.floor(Math.max(0, group.span) / 60) + ":" + String(Math.floor(Math.max(0, group.span) % 60)).padStart(2, "0")
    return (minutes < 1 ? "Worked under a minute" : "Worked " + minutes + " min") + "  ·  Team activity (" + group.size + " steps)"
  }

  // Whether the row at `place` of a stretch shows: all when opened, none when
  // closed, and by default the last three while the team works.
  function stretchShows(group) {
    const choice = opened[group.first]
    return choice !== undefined ? choice : group.live && group.size - group.place <= 3
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
    opened = ({})
  }

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
    return previous.kind !== "request" && current.kind !== "request"
      && previous.who === current.who && current.at - previous.at < root.pause
  }

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
    onActiveFocusChanged: if (activeFocus && (currentIndex < 0 || currentIndex >= count)) currentIndex = count - 1
    onCurrentIndexChanged: following = currentIndex === count - 1
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

      width: timeline.width
      height: drawn ? slot.height + gap : 0
      visible: drawn

      Loader {
        id: slot
        y: entry.gap
        width: entry.width
        sourceComponent: ({ card: request, answer: answer, team: team, turn: turn, speech: speech })[entry.role] || null

        FocusRing { shown: entry.selected; anchors.margins: 0 }
      }

      // A new line slides in from its speaker's side, a request rises from
      // below. What the conversation held before it opened is just there.
      transform: Translate { id: shift }
      ListView.onAdd: if (entry.fresh) arrive.start()
      ParallelAnimation {
        id: arrive
        NumberAnimation { target: entry; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
        NumberAnimation {
          target: shift
          property: entry.kind === "request" ? "y" : "x"
          from: entry.kind === "request" ? 16 : entry.mine ? 28 : -28
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
        Column {
          id: stretched
          readonly property var group: root.stretch(entry.index)
          readonly property var asked: Omunculus.requests.find(item => item.id === entry.key) || null
          readonly property var reply: Omunculus.replies[entry.key] || null
          readonly property string by: asked ? Requests.label(asked.requester) : ""
          readonly property string to: asked ? Requests.label(asked.arbiter) : ""
          readonly property string work: asked ? (Omunculus.work(asked.work_id || "") || { title: "" }).title : ""
          readonly property bool forYou: !!asked && Requests.human(asked.arbiter)
          width: entry.width
          spacing: 2

          Item {
            visible: !!stretched.group && stretched.group.place === 0
            width: parent.width
            height: visible ? 24 : 0
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Icon { anchors.verticalCenter: parent.verticalCenter; name: stretched.group && root.stretchShows(stretched.group) ? "chevron-down" : "chevron-right"; size: 10; color: Theme.dim }
              Label { anchors.verticalCenter: parent.verticalCenter; text: stretched.group ? root.stretchTitle(stretched.group) : ""; color: Theme.dim; font.pixelSize: 11 }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                const next = Object.assign({}, root.opened)
                next[stretched.group.first] = !root.stretchShows(stretched.group)
                root.opened = next
              }
            }
          }

          TeamRow {
            visible: !!stretched.group && root.stretchShows(stretched.group)
            width: parent.width
            height: visible ? implicitHeight : 0
            summary: stretched.reply && stretched.reply.who !== "you" && stretched.forYou
              ? stretched.reply.who.toUpperCase() + " answered this for you: " + stretched.reply.body
              : stretched.by.toUpperCase() + " asked " + stretched.to.toUpperCase() + (stretched.work !== "" ? " about " + stretched.work : "")
                + (stretched.reply ? "  -  answered by " + stretched.reply.who.toUpperCase() : "")
            question: stretched.asked ? String(stretched.asked.reason || "") : ""
            answer: stretched.reply ? stretched.reply.body : ""
            stamp: entry.stamp
            // An open question the agent above decides can still be answered by you.
            RequestDecision {
              visible: !!stretched.asked && Requests.pending(stretched.asked)
              width: parent.width
              key: entry.key
              stamp: entry.stamp
            }
          }
        }
      }

      Component {
        id: turn
        AgentTurn {
          width: entry.width
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

  // A cut line reads as continuing.
  Rectangle {
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: 16
    visible: !timeline.atYBeginning
    gradient: Gradient {
      GradientStop { position: 0; color: Theme.background }
      GradientStop { position: 1; color: Qt.alpha(Theme.background, 0) }
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
