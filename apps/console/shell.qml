import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/ui"

ShellRoot {
  // The omunculus window: its pages down the left as a carousel — the
  // conversations, the conversation, the map, the log and the board — the one
  // on screen beside the bar of its commands, and the page under them.
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

    // Chooses a page by its place, round from either end, and gives it the
    // keyboard, so the carousel folds away.
    function choose(index) {
      const pages = pagesView.pages
      pagesView.go(pages[(index + pages.length) % pages.length])
      rail.pinned = false
      Qt.callLater(pagesView.focusEntry)
    }

    // Whether a dialog holds the keyboard, so the keys of the pages wait.
    readonly property bool dialogOpen: cost.visible || shortcuts.visible || pagesView.dialogOpen

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
          pagesView.focusEntry()
      })

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: panel.short ? 12 : 20
        spacing: panel.short ? 10 : 18

        // The page's bar gives the readout.
        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          section: pagesView.heading
        }

        // The pages, the bar of the one shown, and the page.
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          PagesView {
            id: pagesView
            anchors { left: bar.left; right: parent.right; top: bar.bottom; topMargin: panel.short ? 10 : 16; bottom: parent.bottom }
            active: true
            compact: panel.compact
            short: panel.short
            onCostWanted: cost.open()
          }

          TabRail {
            id: rail
            // Over the bar and the page while it unfolds.
            z: 1
            tabs: pagesView.pages.map(name => ({ name: name }))
            current: pagesView.pages.indexOf(pagesView.page)
            onChosen: index => panel.choose(index)
          }

          PageBar {
            id: bar
            anchors { left: parent.left; leftMargin: rail.foldedWidth + 16; right: parent.right }
            height: rail.headHeight
            commands: pagesView.commands
            section: rail.current
            title: pagesView.page
            message: Omunculus.message
            error: Omunculus.messageIsError
            offline: !Omunculus.connected
            notices: Omunculus.noticeCount
          }

          // 1 to 5, or Ctrl with them, choose a page (a field being written,
          // or the picker of a new conversation, keeps its digits); Ctrl+Tab
          // and Ctrl+Shift+Tab turn the carousel.
          Repeater {
            model: pagesView.pages.length
            delegate: Item {
              required property int index
              Shortcut {
                enabled: !panel.dialogOpen
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
                enabled: !panel.dialogOpen
                sequences: [keyed.modelData.key, "Alt+" + keyed.modelData.key]
                onActivated: keyed.modelData.run()
              }
            }
          }
          Shortcut {
            enabled: !panel.dialogOpen
            sequence: "Ctrl+Tab"
            onActivated: panel.choose(rail.current + 1)
          }
          Shortcut {
            enabled: !panel.dialogOpen
            sequences: ["Ctrl+Shift+Tab", "Ctrl+Backtab"]
            onActivated: panel.choose(rail.current - 1)
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
    function newConversation(): void { pagesView.newConversation() }
    function conversations(): void { pagesView.go("conversations") }
    function open(conversationId: string): void { pagesView.openConversation(conversationId) }
    // A page by its name: conversations, conversation, map, log or board.
    function page(name: string): void { if (pagesView.pages.includes(name)) pagesView.go(name) }
    function agents(): void { page("map") }
    function log(): void { page("log") }
    function board(): void { page("board") }
    function back(): void { pagesView.back() }
    function send(message: string): void { Omunculus.send(message) }
  }
}
