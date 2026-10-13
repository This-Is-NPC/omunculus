import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/ui"

ShellRoot {
  // The omunculus window. At the start: a new conversation, the project's
  // conversations or the board. Entered: the pages of the level on screen
  // down the left — the project's conversations and board, or the chat, map,
  // log and cost of the conversation open — the one on screen beside the bar
  // of its commands, and the page under them; back from the first page
  // entered is back to the start.
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

    // Whether the pages are entered, or the start is on screen.
    property bool started: false
    // Enters the pages at one; a new conversation begins with none open.
    function enter(page) {
      if (page === "new")
        Omunculus.close()
      pagesView.enter(page)
      started = true
    }

    // Chooses a page by its place, round from either end, and gives it the
    // keyboard, so the carousel folds away.
    function choose(index) {
      const pages = pagesView.pages
      pagesView.go(pages[(index + pages.length) % pages.length])
      rail.pinned = false
      Qt.callLater(pagesView.focusEntry)
    }

    // Whether a dialog holds the keyboard, so the keys of the pages wait.
    readonly property bool dialogOpen: shortcuts.visible || pagesView.dialogOpen

    onClosed: Qt.quit()

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      // When the keyboard is left on nothing — a dialog closed, a view changed —
      // the page on screen takes it back.
      readonly property Item focused: Window.activeFocusItem
      // Nothing, or only the window itself, has the keyboard.
      function lost(item) { return !item || !item.parent || item === panel.contentItem }
      onFocusedChanged: if (lost(focused)) Qt.callLater(() => {
        if (lost(Window.activeFocusItem))
          panel.started ? pagesView.focusEntry() : start.forceActiveFocus()
      })

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: panel.short ? 12 : 20
        spacing: panel.short ? 10 : 18

        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          section: panel.started ? pagesView.heading : Omunculus.project
          // Entered, the page's bar gives the readout.
          StatusLine {
            message: panel.started ? "" : Omunculus.message
            error: Omunculus.messageIsError
            offline: !panel.started && !Omunculus.connected
            count: Omunculus.noticeCount
            maxWidth: Math.max(0, panel.width - 480)
          }
        }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // Start: the ways in, and nothing else.
          Stage {
            id: start
            anchors.fill: parent
            shown: !panel.started
            focus: shown
            onShownChanged: if (shown) forceActiveFocus()
            Keys.onPressed: event => {
              if (event.key === Qt.Key_N)
                beginButton.press()
              else if (event.key === Qt.Key_H)
                historyButton.press()
              else if (event.key === Qt.Key_B)
                boardButton.press()
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
                onClicked: panel.enter("new")
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
                onClicked: panel.enter("conversations")
              }
              TraceButton {
                id: boardButton
                anchors.horizontalCenter: parent.horizontalCenter
                implicitWidth: Math.min(260, panel.width - 40)
                role: "navigation"
                icon: "board"
                text: "BOARD"
                enabled: Omunculus.connected
                tip: "b"
                onClicked: panel.enter("board")
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

          // Entered: the pages, the bar of the one shown, and the page.
          Stage {
            anchors.fill: parent
            shown: panel.started
            // Coming in, the page on screen takes the keyboard once it can.
            onVisibleChanged: if (visible) pagesView.focusEntry()

            PagesView {
              id: pagesView
              anchors { left: bar.left; right: parent.right; top: bar.bottom; topMargin: panel.short ? 10 : 16; bottom: parent.bottom }
              active: panel.started
              onStartWanted: panel.started = false
              compact: panel.compact
              short: panel.short
              }

            TabRail {
              id: rail
              // Over the bar and the page while it unfolds.
              z: 1
              tabs: pagesView.pages.map(name => ({ name: name }))
              current: pagesView.tabIndex
              onChosen: index => panel.choose(index)
            }

            PageBar {
              id: bar
              anchors { left: parent.left; leftMargin: rail.foldedWidth + 16; right: parent.right }
              height: rail.headHeight
              commands: pagesView.commands
              section: rail.current
              title: pagesView.title
              message: Omunculus.message
              error: Omunculus.messageIsError
              offline: !Omunculus.connected
              notices: Omunculus.noticeCount
            }

            // The digit a page shows, or Ctrl with it, chooses it (a field being written,
            // or the picker of a new conversation, keeps its digits); Ctrl+Tab
            // and Ctrl+Shift+Tab go to the next or the previous page.
            Repeater {
              model: pagesView.pages.length
              delegate: Item {
                required property int index
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen
                  sequences: pagesView.digitsTaken ? ["Ctrl+" + (index + 1)] : [String(index + 1), "Ctrl+" + (index + 1)]
                  onActivated: panel.choose(index)
                }
              }
            }
            // The keys of the page's commands, R to reply and the like, or
            // Alt with them, which a field being written leaves to them; the
            // field keeps the letters alone.
            Repeater {
              model: pagesView.commands.filter(command => command.key && command.shown !== false && command.enabled !== false)
              delegate: Item {
                id: keyed
                required property var modelData
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen
                  sequences: [keyed.modelData.key, "Alt+" + keyed.modelData.key]
                  onActivated: keyed.modelData.run()
                }
              }
            }
            Shortcut {
              enabled: panel.started && !panel.dialogOpen
              sequence: "Ctrl+Tab"
              onActivated: panel.choose(rail.current + 1)
            }
            Shortcut {
              enabled: panel.started && !panel.dialogOpen
              sequences: ["Ctrl+Shift+Tab", "Ctrl+Backtab"]
              onActivated: panel.choose(rail.current - 1)
            }
          }
        }
      }

      ShortcutsDialog { id: shortcuts }
      Shortcut { sequences: ["?", "F1"]; onActivated: shortcuts.open() }
    }
  }

  // `quickshell ipc --path apps/console call omunculus <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "omunculus"
    function newConversation(): void { panel.started ? pagesView.newConversation() : panel.enter("new") }
    function conversations(): void { page("conversations") }
    function open(conversationId: string): void {
      if (!panel.started)
        panel.enter("conversations")
      pagesView.openConversation(conversationId)
    }
    // A page by its name: conversations or board, or, with a conversation
    // open, chat, map, log or cost.
    function page(name: string): void {
      if (!["conversations", "board"].includes(name) && !(pagesView.open && pagesView.inConversation.includes(name)))
        return
      if (panel.started)
        pagesView.go(name)
      else
        panel.enter(name)
    }
    function start(): void { panel.started = false }
    function agents(): void { page("map") }
    function log(): void { page("log") }
    function board(): void { page("board") }
    function back(): void { pagesView.back() }
    function send(message: string): void { Omunculus.send(message) }
  }
}
