import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ConversationView is a conversation on screen, one of its pages at a time,
// all reading the one conversation the window holds: the conversation, yours
// with the root agent, where every request shows where it was made; the map
// of its agents at work, where the node picked opens beside it; and the log,
// every event a row. Each page gives the commands of its bar. The composer's
// pending button opens the map on what waits on you. Esc closes what a page
// has picked, then goes back to the conversations.
Item {
  id: view

  property bool active: false
  property bool compact: false
  property bool short: false
  // The page on screen, one of `pages`.
  property string page: "conversation"
  signal pageChosen(string page)
  signal costWanted()

  // The pages, in their order.
  readonly property var pages: ["conversation", "map", "log"]

  // The commands of the page on screen, as the PageBar takes them.
  readonly property var commands: {
    const back = { text: "CONVERSATIONS", short: "BACK", icon: "chevron-left", role: "navigation", tip: "back to the conversations  esc", run: () => Omunculus.leave() }
    if (page === "map")
      return [
        back,
        { text: "FIT", icon: "map", tip: "the whole map in view  f", run: () => agents.fit() },
        { text: Omunculus.pending + " PENDING", short: String(Omunculus.pending), icon: "warning", tone: Theme.warning, tip: "pick what waits on you",
          shown: Omunculus.pending > 0, run: () => agents.pickPending() }
      ]
    if (page === "log")
      return [
        back,
        { text: "FILTER", tip: "filter the events  /", run: () => log.focusFilter() },
        { text: log.picked ? "COPY EVENT" : "COPY LOG", short: "COPY", icon: "copy", tip: log.picked ? "copy the event picked" : "copy the events shown",
          enabled: log.picked !== null || log.rows.length > 0, run: () => log.copy() }
      ]
    return [
      back,
      { text: "NEW CONVERSATION", short: "NEW", icon: "plus", tip: "start another conversation", run: () => { Omunculus.leave(); Omunculus.startConversation() } },
      { text: "COST", icon: "cost", tip: "what this conversation cost", run: () => view.costWanted() }
    ]
  }

  function focusEntry() {
    if (page === "map")
      agents.forceActiveFocus()
    else if (page === "log")
      log.forceActiveFocus()
    else
      mainComposer.focusEntry()
  }

  // Opens the map on what waits on you.
  function showPending() {
    pageChosen("map")
    agents.pickPending()
  }

  focus: active
  onActiveChanged: if (active) focusEntry()
  Keys.onEscapePressed: Omunculus.leave()
  onPageChanged: Qt.callLater(focusEntry)
  Connections {
    target: Omunculus
    function onConversationIdChanged() { agents.picked = null; log.picked = null }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "conversation"

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
    shown: view.page === "map"

    AgentsView {
      id: agents
      anchors.fill: parent
      focus: view.page === "map"
      onLeave: Omunculus.leave()
    }
  }

  Stage {
    anchors.fill: parent
    shown: view.page === "log"

    LogView {
      id: log
      anchors.fill: parent
      focus: view.page === "log"
      onLeave: Omunculus.leave()
    }
  }
}
