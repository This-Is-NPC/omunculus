import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/ui"

ShellRoot {
  // The omunculus window. Without a conversation: start one, or read the
  // project's. With one: whether agents work in it, its timeline, and a
  // composer to write to it.
  FloatingWindow {
    id: panel

    title: "omunculus"
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(240, 320)
    color: Theme.background

    // Below this width, controls drop their labels and keep their icons.
    readonly property bool compact: width < 560
    // Below this height, the window keeps its room for the conversation: tighter
    // margins, and the targets of the composer only as the one picked.
    readonly property bool short: height < 560
    // Whether the conversation shows the map of its agents rather than the
    // chat; another conversation on screen starts on the chat.
    property bool map: false
    Connections {
      target: Omunculus
      function onConversationIdChanged() { panel.map = false }
    }

    readonly property string current: Omunculus.conversationId !== "" ? "conversation" : Omunculus.view

    onClosed: Qt.quit()

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      // When the keyboard is left on nothing — a dialog closed, a view changed —
      // a conversation puts it back in its composer.
      readonly property Item focused: Window.activeFocusItem
      // Nothing, or only the window itself, has the keyboard.
      function lost(item) { return !item || !item.parent || item === panel.contentItem }
      onFocusedChanged: if (lost(focused)) Qt.callLater(() => {
        if (panel.current === "conversation" && lost(Window.activeFocusItem))
          conversationView.focusEntry()
      })

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: panel.short ? 12 : 20
        spacing: panel.short ? 10 : 18

        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          section: panel.current !== "conversation" ? (panel.current === "history" ? "conversations" : Omunculus.project)
            : Omunculus.workId !== "" ? (Omunculus.work(Omunculus.workId) || {}).title || "work"
            : panel.map ? "agents" : Omunculus.title
          StatusLine { message: Omunculus.message; error: Omunculus.messageIsError; maxWidth: Math.max(0, panel.width - 480) }
          IconButton {
            visible: panel.current === "conversation"
            name: "cost"
            tip: "what this conversation cost"
            onClicked: cost.open()
          }
          IconButton {
            visible: panel.current === "conversation"
            name: "map"
            tip: panel.map || Omunculus.workId !== "" ? "back to the chat" : "the agents at work"
            highlighted: panel.map || Omunculus.workId !== ""
            onClicked: {
              const leaving = panel.map || Omunculus.workId !== ""
              Omunculus.workId = ""
              panel.map = !leaving
            }
          }
          // Closing the conversation on screen goes back to the conversations;
          // its agents go on.
          IconButton {
            visible: panel.current === "conversation"
            name: "close"
            tip: "back to the conversations"
            onClicked: { panel.map = false; Omunculus.leave() }
          }
        }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // Start: one way forward, and the way back to what was said.
          Stage {
            anchors.fill: parent
            shown: panel.current === "start"
            focus: shown
            onShownChanged: if (shown) forceActiveFocus()
            Keys.onPressed: event => {
              if (event.key === Qt.Key_N)
                beginButton.press()
              else if (event.key === Qt.Key_H)
                historyButton.press()
            }

            Column {
              anchors.horizontalCenter: parent.horizontalCenter
              // Whole pixels, or the first button's top hairline is not drawn;
              // never past the view's edges on a short window.
              y: Math.round(Math.max(0, Math.min(parent.height - height, (parent.height - height) / 2 + Math.min(90, Math.max(0, parent.height / 6)))))
              spacing: 14
              TraceButton {
                id: beginButton
                anchors.horizontalCenter: parent.horizontalCenter
                implicitWidth: Math.min(260, panel.width - 40)
                implicitHeight: 48
                role: "navigation"
                icon: "play"
                text: "NEW CONVERSATION"
                enabled: Omunculus.connected
                tip: "n"
                onClicked: Omunculus.createConversation()
              }
              TraceButton {
                id: historyButton
                anchors.horizontalCenter: parent.horizontalCenter
                implicitWidth: Math.min(260, panel.width - 40)
                role: "navigation"
                icon: "list"
                text: "CONVERSATIONS"
                enabled: Omunculus.connected
                tip: "h"
                onClicked: Omunculus.openHistory()
              }
              Item { width: 1; height: 6 }
              DecodeLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.max(0, panel.width - 40)
                value: Omunculus.connected ? "Project " + Omunculus.project + " · its agents wait for a word"
                  : "The server does not answer"
                soft: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                color: Omunculus.connected ? Theme.dim : Theme.warning
                font.pixelSize: 10
                font.letterSpacing: 2
              }
            }
          }

          Stage {
            anchors.fill: parent
            shown: panel.current === "history"
            HistoryView { anchors.fill: parent; active: parent.shown }
          }

          // The conversation on screen. The keyboard starts in its composer.
          Stage {
            anchors.fill: parent
            shown: panel.current === "conversation"
            ConversationView {
              id: conversationView
              anchors.fill: parent
              active: parent.shown
              compact: panel.compact
              short: panel.short
              mapShown: panel.map
              onMapChosen: shown => panel.map = shown
            }
          }
        }
      }

      ShortcutsDialog { id: shortcuts }
      CostDialog { id: cost }
      Shortcut { sequences: ["?", "F1"]; onActivated: shortcuts.open() }
    }
  }

  // `quickshell ipc --path apps/console call omunculus <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "omunculus"
    function newConversation(): void { Omunculus.createConversation() }
    function conversations(): void { if (Omunculus.conversationId === "") Omunculus.openHistory() }
    function open(conversationId: string): void { Omunculus.open(conversationId) }
    function openWork(workId: string): void { Omunculus.workId = workId }
    function send(message: string): void { Omunculus.send(message) }
  }
}
