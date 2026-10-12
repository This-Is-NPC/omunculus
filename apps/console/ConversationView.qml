import QtQuick
import QtQuick.Layouts

// ConversationView is a conversation on screen, in one of three places: the
// chat, yours with the root agent; the map of its agents at work, where
// everything that waits on you hangs from the agent that asked; or one work,
// what its agent said and did. The composer's pending button and the
// masthead lead to the map. Esc goes back from a work to the map, from the
// map to the chat, and from the chat to the conversations.
Item {
  id: view

  property bool active: false
  property bool compact: false
  property bool short: false
  property bool mapShown: false
  signal mapChosen(bool shown)

  function focusEntry() {
    if (Omunculus.workId !== "" && workStage.item)
      workStage.item.focusEntry()
    else if (!mapShown)
      mainComposer.focusEntry()
    else
      map.forceActiveFocus()
  }

  // Opens the map on what waits on you.
  function showPending() {
    Omunculus.workId = ""
    mapChosen(true)
    Qt.callLater(map.reveal)
  }

  focus: active
  onActiveChanged: if (active) focusEntry()
  Keys.onEscapePressed: {
    if (Omunculus.workId !== "")
      Omunculus.workId = ""
    else if (mapShown)
      mapChosen(false)
    else
      Omunculus.leave()
  }
  Connections {
    target: Omunculus
    function onWorkIdChanged() { Qt.callLater(view.focusEntry) }
  }
  onMapShownChanged: Qt.callLater(focusEntry)

  Stage {
    anchors.fill: parent
    shown: !view.mapShown && Omunculus.workId === ""

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
    shown: view.mapShown && Omunculus.workId === ""

    OrchestrationView {
      id: map
      anchors.fill: parent
      onChosen: work => {
        if (work === "")
          view.mapChosen(false)
        else
          Omunculus.workId = work
      }
    }
  }

  // The work opened, built anew for each one.
  Loader {
    id: workStage
    anchors.fill: parent
    active: Omunculus.workId !== ""
    sourceComponent: Stage {
      shown: true
      function focusEntry() { opened.focusEntry() }
      WorkView {
        id: opened
        anchors.fill: parent
        work: Omunculus.workId
        compact: view.compact
        onPendingChosen: view.showPending()
      }
    }
  }
}
