import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/ui"

ShellRoot {
  // The omunculus window. Without a conversation: start one, or read the
  // project's. With one: its pages down the left as a carousel, the one on
  // screen beside the bar of its commands, and the page under them.
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
    // The page of the conversation on screen, one of its view's pages;
    // another conversation on screen starts on the first.
    property string page: conversationView.pages[0]
    Connections {
      target: Omunculus
      function onConversationIdChanged() { panel.page = conversationView.pages[0] }
    }

    // Chooses a page by its place, round from either end, and gives it the
    // keyboard, so the carousel folds away.
    function choose(index) {
      const pages = conversationView.pages
      page = pages[(index + pages.length) % pages.length]
      rail.pinned = false
      Qt.callLater(conversationView.focusEntry)
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
          section: panel.current === "history" ? "conversations" : panel.current === "pick" ? "new conversation"
            : panel.current !== "conversation" ? Omunculus.project
            : Omunculus.title
          // With a conversation on screen, the page's bar gives the readout.
          StatusLine {
            message: panel.current === "conversation" ? "" : Omunculus.message
            error: Omunculus.messageIsError
            offline: panel.current !== "conversation" && !Omunculus.connected
            count: Omunculus.noticeCount
            maxWidth: Math.max(0, panel.width - 480)
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
                onClicked: Omunculus.startConversation()
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

          // Whom a new conversation is with.
          Stage {
            anchors.fill: parent
            shown: panel.current === "pick"
            AgentPicker {
              anchors.fill: parent
              focus: parent.shown
              onVisibleChanged: if (visible) forceActiveFocus()
              onPicked: name => Omunculus.createConversation(name)
              onBack: Omunculus.view = "start"
            }
          }

          // The conversation on screen: its pages, the bar of the one shown,
          // and the page. The keyboard starts in its composer.
          Stage {
            anchors.fill: parent
            shown: panel.current === "conversation"

            ConversationView {
              id: conversationView
              anchors { left: bar.left; right: parent.right; top: bar.bottom; topMargin: panel.short ? 10 : 16; bottom: parent.bottom }
              active: parent.shown
              compact: panel.compact
              short: panel.short
              page: panel.page
              onPageChosen: page => panel.page = page
              onCostWanted: cost.open()
            }

            TabRail {
              id: rail
              // Over the bar and the page while it unfolds.
              z: 1
              tabs: conversationView.pages.map(name => ({ name: name }))
              current: conversationView.pages.indexOf(panel.page)
              onChosen: index => panel.choose(index)
            }

            PageBar {
              id: bar
              anchors { left: parent.left; leftMargin: rail.foldedWidth + 16; right: parent.right }
              height: rail.headHeight
              commands: conversationView.commands
              section: rail.current
              title: panel.page
              message: Omunculus.message
              error: Omunculus.messageIsError
              offline: !Omunculus.connected
              notices: Omunculus.noticeCount
            }

            // 1 to 3, or Ctrl with them, choose a page (a field being written
            // keeps its digits); Ctrl+Tab and Ctrl+Shift+Tab turn the carousel.
            Repeater {
              model: conversationView.pages.length
              delegate: Item {
                required property int index
                Shortcut {
                  enabled: panel.current === "conversation" && !cost.visible && !shortcuts.visible
                  sequences: [String(index + 1), "Ctrl+" + (index + 1)]
                  onActivated: panel.choose(index)
                }
              }
            }
            Shortcut {
              enabled: panel.current === "conversation" && !cost.visible && !shortcuts.visible
              sequence: "Ctrl+Tab"
              onActivated: panel.choose(rail.current + 1)
            }
            Shortcut {
              enabled: panel.current === "conversation" && !cost.visible && !shortcuts.visible
              sequences: ["Ctrl+Shift+Tab", "Ctrl+Backtab"]
              onActivated: panel.choose(rail.current - 1)
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
    function newConversation(): void { Omunculus.startConversation() }
    function conversations(): void { if (Omunculus.conversationId === "") Omunculus.openHistory() }
    function open(conversationId: string): void { Omunculus.open(conversationId) }
    // A page of the conversation on screen, by its name.
    function page(name: string): void { if (Omunculus.conversationId !== "" && conversationView.pages.includes(name)) panel.page = name }
    function agents(): void { page("map") }
    function log(): void { page("log") }
    function send(message: string): void { Omunculus.send(message) }
  }
}
