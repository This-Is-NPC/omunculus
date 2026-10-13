import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
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
    // What the conversation shows: "chat", the "map" of its agents, or its
    // "log"; another conversation on screen starts on the chat.
    property string pane: "chat"
    Connections {
      target: Omunculus
      function onConversationIdChanged() { panel.pane = "chat" }
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
          section: panel.current === "history" ? "conversations"
            : panel.current !== "conversation" ? Omunculus.project
            : panel.pane === "map" ? "agents" : panel.pane === "log" ? "log" : Omunculus.title
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
            tip: panel.pane === "map" ? "back to the chat" : "the agents at work"
            highlighted: panel.pane === "map"
            count: Omunculus.pending
            onClicked: panel.pane = panel.pane === "map" ? "chat" : "map"
          }
          IconButton {
            visible: panel.current === "conversation"
            name: "list"
            tip: panel.pane === "log" ? "back to the chat" : "every event, as a log"
            highlighted: panel.pane === "log"
            onClicked: panel.pane = panel.pane === "log" ? "chat" : "log"
          }
          IconButton {
            name: "settings"
            tip: "settings"
            highlighted: Omunculus.settingsOpen
            onClicked: Omunculus.toggleSettings()
          }
          // Closing the conversation on screen goes back to the conversations;
          // its agents go on.
          IconButton {
            visible: panel.current === "conversation"
            name: "close"
            tip: "back to the conversations"
            onClicked: { panel.pane = "chat"; Omunculus.leave() }
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
              pane: panel.pane
              onPaneChosen: pane => panel.pane = pane
            }
          }
        }
      }

      ShortcutsDialog { id: shortcuts }
      CostDialog { id: cost }
      Shortcut { sequences: ["?", "F1"]; onActivated: shortcuts.open() }
    }
  }

  // The settings: a window of their own, made once and then shown or hidden,
  // since destroying a window makes Qt write its pipeline cache to disk.
  FloatingWindow {
    id: settings

    // A child of the main window, so Hyprland keeps it floating above it.
    parentWindow: panel
    title: "omunculus · settings"
    implicitWidth: Math.min(1400, screen ? screen.width - 96 : 1400)
    implicitHeight: Math.min(900, screen ? screen.height - 96 : 900)
    minimumSize: Qt.size(480, 360)
    color: Theme.background
    visible: Omunculus.settingsOpen
    onClosed: Omunculus.settingsOpen = false

    // Hyprland opens a child window centred on its parent, which can leave part
    // of it off the screen, so it is centred on its monitor once it opens.
    Connections {
      target: Hyprland
      function onRawEvent(event) {
        if (event.name !== "openwindow")
          return
        const [address, , , title] = event.parse(4)
        if (title === settings.title)
          Hyprland.dispatch(`hl.dsp.window.center({ window = "address:0x${address}" })`)
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 18

        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          section: "settings"
          StatusLine { message: Omunculus.message; error: Omunculus.messageIsError; maxWidth: Math.max(0, settings.width - 480) }
        }

        SettingsView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          active: settings.visible
        }
      }
    }
  }

  // `quickshell ipc --path apps/console call omunculus <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "omunculus"
    function newConversation(): void { Omunculus.createConversation() }
    function conversations(): void { if (Omunculus.conversationId === "") Omunculus.openHistory() }
    function settings(): void { Omunculus.openSettings() }
    function open(conversationId: string): void { Omunculus.open(conversationId) }
    function agents(): void { if (Omunculus.conversationId !== "") panel.pane = "map" }
    function log(): void { if (Omunculus.conversationId !== "") panel.pane = "log" }
    function send(message: string): void { Omunculus.send(message) }
  }
}
