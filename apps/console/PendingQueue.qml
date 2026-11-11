pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Pending.js" as Pending
import "kit/client/Time.js" as Time
import "kit/ui"

// PendingQueue is everything that waits on you, in one place, over any page:
// a panel on the right of the window, the whole window when it is narrow. Its
// items are the three kinds, QUESTION, DECISION and PERMISSION, oldest first,
// each a RequestDecision with its actions grouped inside it. Acting on one
// removes it from the queue and leaves a sentence in the chat. Esc, the close
// button and a click outside close it, and so does answering the last one: it
// is never open with nothing in it.
FocusScope {
  id: queue

  // The requests waiting on you, oldest first, as [{id, at}].
  property var items: []
  property bool shown: false
  signal closed()

  // Puts the keyboard on the first item's first field or main action; the
  // panel itself when there is none, so Esc closes it and Tab goes in.
  function focusFirst() {
    const first = list.count > 0 ? list.itemAt(0) as RequestDecision : null
    if (!first) {
      panel.forceActiveFocus()
      return
    }
    first.focusFirst()
    // The question is read from its top, whatever the focus scrolled to.
    Qt.callLater(() => scroller.scrollTo(0))
  }

  visible: shown && items.length > 0
  onShownChanged: if (shown) Qt.callLater(focusFirst)

  Rectangle {
    anchors.fill: parent
    color: Qt.alpha(Theme.background, 0.7)
    MouseArea {
      anchors.fill: parent
      onClicked: queue.closed()
    }
  }

  Rectangle {
    id: panel
    anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
    width: Math.min(560, parent.width)
    color: Theme.background
    border.color: Theme.line
    focus: true
    activeFocusOnTab: true
    Keys.onEscapePressed: queue.closed()

    // A click on the panel does not reach the window behind.
    MouseArea { anchors.fill: parent }

    ColumnLayout {
      anchors { fill: parent; margins: Theme.space.inset }
      spacing: Theme.space.gap

      RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.gap
        Icon { name: "warning"; size: 14; color: Theme.warning }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: "PENDING" + Theme.type.meta.separator + queue.items.length
          color: Theme.warning
          font.pixelSize: Theme.type.kicker.size
          font.letterSpacing: Theme.type.kicker.tracking
          elide: Text.ElideRight
        }
        IconButton {
          name: "close"
          tip: "close the pending list  Esc"
          onClicked: queue.closed()
        }
      }

      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: "Oldest first, answer in any order. Each one names what it unblocks."
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
      }

      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.line
      }

      ScrollPage {
        id: scroller
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: column.implicitHeight

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Theme.space.gap
          Repeater {
            id: list
            model: queue.items
            delegate: RequestDecision {
              required property var modelData
              Layout.fillWidth: true
              key: modelData.id
              stamp: Time.clock(modelData.at, Date.now())
            }
          }
        }
      }
    }
  }
}
