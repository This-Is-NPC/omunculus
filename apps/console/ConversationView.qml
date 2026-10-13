import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ConversationView is a conversation on screen, in one of three panes: the
// chat, yours with the root agent, where every request shows where it was
// made; the map of its agents at work, where the node picked opens beside it;
// or the log, every event a row. The composer's pending button opens the map
// on what waits on you. Esc closes what is picked, leaves the map or the log
// for the chat, and the chat for the conversations.
Item {
  id: view

  property bool active: false
  property bool compact: false
  property bool short: false
  // "chat", "map" or "log".
  property string pane: "chat"
  signal paneChosen(string pane)

  function focusEntry() {
    if (pane === "map")
      agents.forceActiveFocus()
    else if (pane === "log")
      log.forceActiveFocus()
    else
      mainComposer.focusEntry()
  }

  // Opens the map on what waits on you.
  function showPending() {
    paneChosen("map")
    agents.pickPending()
  }

  focus: active
  onActiveChanged: if (active) focusEntry()
  Keys.onEscapePressed: Omunculus.leave()
  onPaneChanged: Qt.callLater(focusEntry)
  Connections {
    target: Omunculus
    function onConversationIdChanged() { agents.picked = null; log.picked = null }
  }

  Stage {
    anchors.fill: parent
    shown: view.pane === "chat"

    ColumnLayout {
      anchors.fill: parent
      spacing: view.short ? 10 : 14

      TimelineView {
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
    shown: view.pane === "map"

    AgentsView {
      id: agents
      anchors.fill: parent
      focus: view.pane === "map"
      onLeave: view.paneChosen("chat")
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.pane === "log"

    LogView {
      id: log
      anchors.fill: parent
      focus: view.pane === "log"
      onLeave: view.paneChosen("chat")
    }
  }
}
