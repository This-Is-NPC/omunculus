pragma ComponentBehavior: Bound
import QtQuick
import "focus.js" as Focus
import "kit/ui"

// TimelineView is one thread of the conversation: what you and its agents
// said, and what each run did on a line below its words, live or read back.
// Like a chat, it sits on the bottom and grows upwards, and it follows new
// entries unless you scrolled up to read; then a pill counts what arrived out
// of view and leads back to it. A turn streaming taller than the view is held
// by its top, so its first words stay readable. From the keyboard, Tab reaches
// it on the newest entry: ↑/↓ and PgUp/PgDn move, Home goes to the first and
// End back to the newest, and Tab moves into the tools of the entry it is on.
Item {
  id: root

  // The thread shown: "" for the main one, or a work's.
  property string thread: ""
  readonly property ListModel model: Omunculus.thread(thread)
  property string emptyText: "SAY WHAT YOU NEED"
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

  // Counts a new entry when the view is away from the end; speech has no key.
  function arrived(key) {
    if (timeline.following || (key !== "" && root.seen[key]))
      return
    if (key !== "")
      root.seen[key] = true
    root.unseen++
  }

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
    return previous.who === current.who && current.at - previous.at < root.pause
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
      if (entry && entry.key !== "" && entry.key === root.held)
        positionViewAtIndex(last, ListView.Beginning)
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
    spacing: 4
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

    delegate: Loader {
      id: entry

      required property int index
      required property string kind
      required property string key
      required property string who
      required property string text
      required property bool mine
      required property string stamp
      required property real at
      required property bool streaming
      required property string partial
      required property string steps
      required property bool fresh

      width: timeline.width
      sourceComponent: kind === "turn" ? turn : speech
      readonly property bool selected: ListView.isCurrentItem && root.keyboard

      FocusRing { shown: entry.selected; anchors.margins: 0 }

      // A new line slides in from its speaker's side. What the conversation
      // held before it opened is just there.
      transform: Translate { id: shift }
      ListView.onAdd: if (entry.fresh) arrive.start()
      ParallelAnimation {
        id: arrive
        NumberAnimation { target: entry; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
        NumberAnimation { target: shift; property: "x"; from: entry.mine ? 28 : -28; to: 0; duration: 300; easing.type: Easing.OutCubic }
      }

      Component {
        id: speech
        SpeechTurn {
          width: entry.width
          who: entry.who
          text: entry.text
          mine: entry.mine
          stamp: entry.stamp
          continued: root.revision >= 0 && root.continues(entry.index)
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
          at: entry.at
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
    color: Theme.line
    font.pixelSize: 11
    font.letterSpacing: 3
  }
}
