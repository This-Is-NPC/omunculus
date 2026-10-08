pragma ComponentBehavior: Bound
import QtQuick
import "focus.js" as Focus

// TimelineView is one thread of the conversation: what you and its agents
// said, and what each run did on a line below its words, live or read back. Like a chat, it sits on the bottom and grows upwards, and it
// follows new entries unless you scrolled up to read. From the keyboard, Tab
// reaches it on the newest entry: ↑/↓ and PgUp/PgDn move, Home/End go to
// either end, and Tab moves into the tools of the entry it is on.
Item {
  id: root

  // The thread shown: "" for the main one, or a work's.
  property string thread: ""
  readonly property ListModel model: Omunculus.thread(thread)
  property string emptyText: "SAY WHAT YOU NEED"
  // Counts changes to the entries, so each line knows again whether it
  // continues the turn before it.
  property int revision: 0

  Connections {
    target: root.model
    function onRowsInserted() { root.revision++ }
    function onRowsRemoved() { root.revision++ }
  }

  // The keyboard is on the timeline or in the entry it is on.
  readonly property bool keyboard: timeline.activeFocus || (timeline.currentItem !== null && Focus.within(Window.activeFocusItem, timeline.currentItem))

  // Whether the line at `index` is said by the speaker of the line just before
  // it: yours after yours, or the same agent's after its own.
  // A delegate may ask with its old index while the entries change under it.
  function continues(index) {
    if (index <= 0 || index >= timeline.model.count)
      return false
    const previous = timeline.model.get(index - 1)
    const current = timeline.model.get(index)
    return previous.who === current.who
  }

  ListView {
    id: timeline

    property bool following: true

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
    onContentHeightChanged: if (following) Qt.callLater(positionViewAtEnd)
    onCountChanged: if (following) Qt.callLater(positionViewAtEnd)

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
        currentIndex = count - 1
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

      // A new line slides in from its speaker's side.
      // What the conversation held before it opened is just there.
      transform: Translate { id: shift }
      ListView.onAdd: if (entry.fresh) arrive.start()
      ParallelAnimation {
        id: arrive
        NumberAnimation { target: entry; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
        NumberAnimation {
          target: shift
          property: "x"
          from: entry.mine ? 28 : -28
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
          stamp: entry.stamp
          recent: entry.index >= timeline.count - 4
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
          recent: entry.index >= timeline.count - 4
          continued: root.revision >= 0 && root.continues(entry.index)
        }
      }
    }
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
