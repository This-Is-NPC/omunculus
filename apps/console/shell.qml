pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

ShellRoot {
  // The omunculus window. At the start: on a project, a new conversation,
  // its conversations, the board or the projects; on the registry alone, the
  // projects or the board. Entered: the pages of the level on screen down
  // the left — the registry's projects and board, a project's conversations
  // and board, or the chat, team, log and cost of the conversation open —
  // the one on screen beside the bar of its commands, and the page under
  // them; on a narrow window the rail is hidden and the bar's page switcher
  // lists the pages. The masthead names the way to the page, and, while a
  // project is open, says how many requests wait for you in the other
  // projects. Back from the first page entered is back to the start.
  FloatingWindow {
    id: panel

    title: "omunculus"
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(360, 480)
    color: Theme.background

    // The window's size class: "wide", "medium" or "narrow".
    readonly property string size: Breakpoints.size(width)
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

    // What the rail calls a page: the map is the team.
    function pageName(page) { return page === "map" ? "team" : page }

    // Chooses a page by its place, round from either end, and gives it the
    // keyboard, so the rail folds away.
    function choose(index) {
      const pages = pagesView.pages
      pagesView.go(pages[(index + pages.length) % pages.length])
      Qt.callLater(pagesView.focusEntry)
    }

    // The ways in at the start: on a project, a new conversation, its
    // conversations, the board and the projects; on the registry alone, the
    // projects and the board.
    readonly property var ways: {
      const projects = { key: "start-projects", page: "projects", text: "PROJECTS", icon: "folder" }
      const board = { key: "start-board", page: "board", text: "BOARD", icon: "board" }
      return Omunculus.registry ? [projects, board] : [
        { key: "start-new", page: "new", text: "NEW CONVERSATION", icon: "play" },
        { key: "start-history", page: "conversations", text: "CONVERSATIONS", icon: "list" },
        board, projects
      ]
    }

    // The way to the page on screen, as the masthead takes it: entered, the
    // pages'; at the start, the project, or nothing on the registry.
    readonly property var crumbs: started ? pagesView.crumbs : Omunculus.registry ? [] : [{ text: Omunculus.project }]

    // Whether a dialog holds the keyboard, so the keys of the pages wait.
    readonly property bool dialogOpen: shortcuts.visible || pagesView.dialogOpen

    onClosed: Qt.quit()

    Rectangle {
      id: frame
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      // When the keyboard is left on nothing — a dialog closed, a view changed —
      // the page on screen takes it back, unless text was being written a
      // moment ago: that text is not carried into another field, and the
      // keyboard waits on the sink, where typing only says so.
      readonly property Item focused: Window.activeFocusItem
      // Nothing, or only the window itself, has the keyboard.
      function lost(item) { return !item || !item.parent || item === panel.contentItem }
      onFocusedChanged: if (lost(focused)) Qt.callLater(() => {
        if (!lost(Window.activeFocusItem))
          return
        if (!Typing.idle)
          sink.forceActiveFocus()
        else
          panel.started ? pagesView.focusEntry() : start.forceActiveFocus()
      })

      // Whether the bare keys of navigation may act: an item to navigate has
      // the keyboard, and no text field saw a key for a second.
      readonly property bool bare: !lost(focused) && focused !== sink && Typing.idle

      // Printable keys no one took are not commands and not text.
      Keys.onPressed: event => {
        if (event.text >= " " && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          Omunculus.tell("Click a field to type", false)
          event.accepted = true
        }
      }
      Item { id: sink }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: panel.short ? Math.min(12, Breakpoints.margin(panel.width)) : Breakpoints.margin(panel.width)
        spacing: panel.short ? 10 : 18

        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          crumbs: panel.crumbs
          // Requests waiting for you in the other projects, while one is
          // open; it opens them, the waiting ones picked out.
          RowLayout {
            visible: panel.started && pagesView.level !== "registry" && Omunculus.elsewhere > 0
            spacing: 6
            Icon { name: "warning"; size: 10; color: Theme.warning }
            LinkLabel {
              value: Omunculus.elsewhere + (panel.width < 700 ? "" : " ELSEWHERE")
              color: Theme.warning
              font.pixelSize: 10
              font.letterSpacing: 2
              onClicked: pagesView.showProjects("waiting")
            }
          }
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
              if (!Typing.idle)
                return
              const at = panel.ways.findIndex(way => Shortcuts.keys(way.key).includes(event.text.toUpperCase()))
              if (at >= 0)
                (wayButtons.itemAt(at) as TraceButton).press()
            }

            Column {
              anchors.horizontalCenter: parent.horizontalCenter
              // Whole pixels, or the first button's top hairline is not drawn;
              // never past the view's edges on a short window.
              y: Math.round(Math.max(0, Math.min(parent.height - height, (parent.height - height) / 2 + Math.min(90, Math.max(0, parent.height / 6)))))
              spacing: 14
              // The first way in stands taller.
              Repeater {
                id: wayButtons
                model: panel.ways
                delegate: TraceButton {
                  required property var modelData
                  required property int index
                  // A delegate torn down has no parent.
                  anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                  implicitWidth: Math.min(260, panel.width - 40)
                  implicitHeight: index === 0 ? 48 : 44
                  role: "navigation"
                  icon: modelData.icon
                  text: modelData.text
                  enabled: Omunculus.connected
                  tip: Shortcuts.label(modelData.key)
                  onClicked: panel.enter(modelData.page)
                }
              }
              Item { width: 1; height: 6 }
              DecodeLabel {
                readonly property int count: Omunculus.boardProjects.length
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.max(0, panel.width - 40)
                value: !Omunculus.connected ? "The server does not answer"
                  : !Omunculus.registry ? "Project " + Omunculus.project + " · its agents wait for a word"
                  : count > 0 ? count + (count === 1 ? " project" : " projects") + " · pick one to talk with its agents"
                  : "Pick a project to talk with its agents"
                soft: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
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
              short: panel.short
            }

            TabRail {
              id: rail
              // Over the bar and the page while it unfolds, opaque.
              z: 1
              tabs: pagesView.pages.map(name => ({ name: panel.pageName(name) }))
              current: pagesView.tabIndex
              onChosen: index => panel.choose(index)
              onEscaped: pagesView.focusEntry()
            }

            PageBar {
              id: bar
              // No rail on a narrow window: the bar takes the whole width.
              anchors { left: parent.left; leftMargin: rail.visible ? rail.foldedWidth + 16 : 0; right: parent.right }
              height: rail.headHeight
              commands: pagesView.commands
              section: rail.current
              pages: rail.tabs
              current: rail.current
              pageSwitcher: true
              onPageChosen: index => panel.choose(index)
              message: Omunculus.message
              error: Omunculus.messageIsError
              offline: !Omunculus.connected
              notices: Omunculus.noticeCount
            }

            // The digit a page shows chooses it while a page is being navigated
            // (the picker of a new conversation keeps its digits); Ctrl with
            // it chooses it from a field being written too. Ctrl+Tab and
            // Ctrl+Shift+Tab go to the next or the previous page.
            Repeater {
              model: pagesView.pages.length
              delegate: Item {
                id: numbered
                required property int index
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen && frame.bare && !pagesView.digitsTaken
                  sequence: Shortcuts.keys("page")[numbered.index]
                  onActivated: panel.choose(numbered.index)
                }
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen
                  sequence: Shortcuts.keys("page-chord")[numbered.index]
                  onActivated: panel.choose(numbered.index)
                }
              }
            }
            // The chords of the page's commands, Alt+R to reply and the like,
            // and of the page's other chords, which a field being written
            // leaves to them. They have no bare key: what is typed never runs one.
            Repeater {
              model: pagesView.commands.filter(command => command.key && command.shown !== false && command.enabled !== false).concat(pagesView.chords)
              delegate: Item {
                id: keyed
                required property var modelData
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen
                  sequence: keyed.modelData.key
                  onActivated: keyed.modelData.run()
                }
              }
            }
            Shortcut {
              enabled: panel.started && !panel.dialogOpen
              sequences: Shortcuts.keys("next-page")
              onActivated: panel.choose(rail.current + 1)
            }
            Shortcut {
              enabled: panel.started && !panel.dialogOpen
              sequences: Shortcuts.keys("previous-page")
              onActivated: panel.choose(rail.current - 1)
            }
            Shortcut {
              enabled: panel.started && !panel.dialogOpen && Omunculus.project !== ""
              sequences: Shortcuts.keys("new-conversation")
              onActivated: pagesView.newConversation()
            }
          }
        }
      }

      ShortcutsDialog { id: shortcuts }
      // Logs the text drawn out of its place, when asked for.
      Loader {
        active: Quickshell.env("OMUNCULUS_TEXT_AUDIT") === "1"
        sourceComponent: TextAudit {}
      }
      // The projects, from anywhere, a field being written too.
      Shortcut {
        enabled: !panel.dialogOpen && Omunculus.connected
        sequences: Shortcuts.keys("projects")
        onActivated: panel.started ? pagesView.showProjects("") : panel.enter("projects")
      }
      Shortcut { enabled: frame.bare; sequence: "?"; onActivated: shortcuts.open() }
      Shortcut { sequence: "F1"; onActivated: shortcuts.open() }
    }
  }

  // `quickshell ipc --path apps/console call omunculus <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "omunculus"
    function newConversation(): void {
      if (Omunculus.project === "")
        return
      panel.started ? pagesView.newConversation() : panel.enter("new")
    }
    function conversations(): void { page("conversations") }
    function open(conversationId: string): void {
      if (Omunculus.project === "")
        return
      if (!panel.started)
        panel.enter("conversations")
      pagesView.openConversation(conversationId)
    }
    function projects(): void { page("projects") }
    // A project of the registry, by its id, at its conversations.
    function project(id: string): void {
      const place = Omunculus.boardProjects.find(item => item.id === id)
      if (!place)
        return
      if (!panel.started)
        panel.enter("projects")
      pagesView.openProject(place)
    }
    // A page by its name: projects, conversations or board, or, with a
    // conversation open, chat, map, log or cost.
    function page(name: string): void {
      if (!["projects", "conversations", "board"].includes(name) && !(pagesView.open && pagesView.inConversation.includes(name)))
        return
      if (name === "conversations" && Omunculus.project === "")
        return
      if (panel.started)
        pagesView.go(name)
      else
        panel.enter(name)
    }
    function start(): void { panel.started = false }
    // A work of the board, on its page.
    function work(id: string): void {
      const found = Omunculus.board.find(item => item.id === id)
      if (!found)
        return
      if (!panel.started)
        panel.enter("board")
      pagesView.showWork(found)
    }
    function agents(): void { page("map") }
    function log(): void { page("log") }
    function board(): void { page("board") }
    function back(): void { pagesView.back() }
    function send(message: string): void { Omunculus.send(message) }
  }
}
