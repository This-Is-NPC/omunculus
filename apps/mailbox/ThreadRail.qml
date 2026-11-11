pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ThreadRail is the threads of the folder while their column is folded: each
// its agent's portrait, a dot at its
// corner while unread, the thread on screen washed and outlined in the
// accent; its agent, subject and label are the tip. A click opens a thread; with the keyboard on the rail, Up and Down
// open the one before or after, as Alt+Up and Alt+Down do anywhere.
ListView {
  id: rail

  clip: true
  spacing: 6
  model: Mail.shown
  activeFocusOnTab: true
  boundsBehavior: Flickable.StopAtBounds
  readonly property int selectedIndex: Mail.shown.findIndex(thread => thread.key === Mail.selected)
  onSelectedIndexChanged: if (selectedIndex >= 0) positionViewAtIndex(selectedIndex, ListView.Contain)

  Keys.onUpPressed: Mail.step(-1)
  Keys.onDownPressed: Mail.step(1)

  delegate: Rectangle {
    id: tab

    required property var modelData
    required property int index
    readonly property bool current: Mail.selected === modelData.key

    width: rail.width
    height: width
    color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
    border.color: current ? Theme.primary : pointer.containsMouse ? Theme.dim : Theme.line
    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }

    Portrait {
      anchors { fill: parent; margins: 4 }
      agent: tab.modelData.agent || "?"
      source: Mail.imageOf(tab.modelData.project, tab.modelData.agent)
      tone: Mail.toneOf(tab.modelData.project, tab.modelData.agent)
    }
    Dot {
      anchors { right: parent.right; top: parent.top; margins: -2 }
      size: 8
      tone: Theme.primary
      border.color: Theme.background
      opacity: Mail.isUnread(tab.modelData) ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140 } }
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { rail.forceActiveFocus(); Mail.open(tab.modelData.key) }
    }
    FocusRing { shown: rail.activeFocus && (tab.current || (rail.selectedIndex < 0 && tab.index === 0)) }
    Hint {
      active: pointer.containsMouse || (rail.activeFocus && tab.current)
      text: tab.modelData.agent + " · " + tab.modelData.subject + (tab.modelData.label !== "" ? "\n" + Mailbox.labels[tab.modelData.label] : "")
    }
  }
}
