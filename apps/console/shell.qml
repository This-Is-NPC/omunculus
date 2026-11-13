pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/client/Projects.js" as Projects
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

ShellRoot {
  // The omunculus window. At the start: on a project, a new conversation,
  // its conversations, the board or the projects; on the registry alone, the
  // projects or the board. Entered: on the registry and a project, the pages
  // of the level down the left — the registry's projects and board, a
  // project's conversations and board — the one on screen beside the bar of
  // its commands, and the page under them; on a narrow window the rail is
  // hidden and the bar's page switcher lists the pages. In a conversation,
  // its pages under its own head and tabs (PagesView), with no rail and no
  // bar: the masthead's buttons open its cost, its menu of rarer actions and
  // close it, back to the list. The masthead names the way to the page; while
  // a project is open, a notice says how many conversations need you in the
  // other projects, and in a conversation, how many notes to you are unread.
  // Back from the first page entered is back to the start.
  FloatingWindow {
    id: panel

    title: "omunculus"
    implicitWidth: 1080
    // 3 : 2.
    implicitHeight: implicitWidth * 2 / 3
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
    // Enters the pages at a project's conversations; BACK returns to the start.
    function enterProject(place, chip) {
      pagesView.enterProject(place, chip)
      started = true
    }

    // The window's margin, and the room between its masthead and the rest.
    readonly property int margin: short ? Theme.space.pageShort : Theme.space.page
    readonly property int section: short ? Theme.space.sectionShort : Theme.space.section

    // The counts of the notices put away, -1 for none; a notice shows again
    // once its count changes.
    property int elsewhereKept: -1
    property int notesKept: -1

    // The ways in at the start, each a card with a line of what is there: on a
    // project, a new conversation, its conversations, the board, its jobs and the
    // projects; on the registry alone, the projects and the board.
    readonly property var ways: {
      const row = Omunculus.projectRows.find(item => item.id === Omunculus.project) || null
      const count = Omunculus.boardProjects.length
      const projects = { page: "projects", text: "PROJECTS", detail: Omunculus.registry
        ? (count > 0 ? count + (count === 1 ? " project" : " projects") + Theme.type.meta.separator + "open one to see its conversations" : "None yet" + Theme.type.meta.separator + "add the first")
        : "Switch to another project" }
      const board = { page: "board", text: "BOARD", detail: Omunculus.registry ? "The works of every project, by state" : "The works of this project, by state" }
      const jobs = Omunculus.jobs.items
      const jobsWay = { page: "jobs", text: "JOBS", detail: !Omunculus.jobs.loaded ? "Messages sent on a schedule"
        : jobs.length === 0 ? "None yet" + Theme.type.meta.separator + "schedule the first"
        : jobs.length + (jobs.length === 1 ? " job" : " jobs") + Theme.type.meta.separator + jobs.filter(job => job.state === "active").length + " active" }
      return Omunculus.registry ? [projects, board] : [
        { page: "new", text: "NEW CONVERSATION", detail: Omunculus.startAgent !== "" ? "Say what you need; it goes to " + Omunculus.startAgent + " unless you choose another" : "Say what you need and choose who gets it" },
        { page: "conversations", text: "CONVERSATIONS", detail: !row || row.reading ? "Reading the conversations…" : Projects.meta(row, "", 80, Theme.type.meta.separator) },
        board, jobsWay, projects
      ]
    }

    // The way to the page on screen, as the masthead takes it: entered, the
    // pages'; at the start, the project, or, on the registry, whether the
    // server answers.
    readonly property var crumbs: started ? pagesView.crumbs
      : Omunculus.registry ? [{ text: !Omunculus.connected ? "offline" : Projects.reading(Omunculus.projectRows) ? "reading" : "ready" }] : [{ text: Omunculus.project }]

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
        anchors.margins: panel.margin
        spacing: panel.section

        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          tight: panel.short
          home: panel.started
          onHomeClicked: panel.started = false
          crumbs: panel.crumbs
          // Requests waiting for you in the other projects, while one is
          // open; it opens them, the waiting ones picked out.
          NoticeChip {
            readonly property int count: Omunculus.elsewhere
            shown: panel.started && pagesView.level !== "registry" && count > 0 && panel.elsewhereKept < 0
            text: count + (panel.size === "narrow" ? " ELSEWHERE" : " NEED YOU ELSEWHERE")
            tip: "the projects where conversations need you"
            closeTip: "put it away until it changes"
            onOpened: pagesView.showProjects("waiting")
            onDismissed: panel.elsewhereKept = count
            onCountChanged: panel.elsewhereKept = -1
          }
          // The notes to you of the conversation open, unread; it shows the
          // oldest and marks it read.
          NoticeChip {
            readonly property int count: Omunculus.unread.length
            shown: panel.started && pagesView.inside && count > 0 && panel.notesKept < 0
            text: count + (count === 1 ? " NOTE" : " NOTES")
            tip: "show the oldest note to you and mark it read  " + Shortcuts.label("mark-read")
            closeTip: "put it away until another comes"
            onOpened: pagesView.readNote()
            onDismissed: panel.notesKept = count
            onCountChanged: panel.notesKept = -1
          }
          // Keys are for a keyboard: a narrow window, a phone, has no use for them.
          IconButton {
            visible: !panel.started && panel.size !== "narrow"
            name: "info"
            tip: "the keys  " + Shortcuts.label("help")
            onClicked: shortcuts.open()
          }
          ActionMenu {
            visible: panel.started && pagesView.inside
            tip: "more"
            items: pagesView.more
            onChosen: id => pagesView.more.find(item => item.id === id).run()
          }
          IconButton {
            visible: panel.started && pagesView.inside
            name: "close"
            tip: pagesView.fresh ? "close it, back to choosing whom to talk with" : "close it, back to the conversations"
            onClicked: pagesView.leave()
          }
        }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // Start: the ways in, centred, and under them what the server
          // holds: the projects, or the project, and the conversations that
          // need you in each, read while the start is on screen too.
          Stage {
            id: start
            anchors.fill: parent
            shown: !panel.started
            focus: shown
            // After the pages let the registry go.
            onShownChanged: if (shown) {
              forceActiveFocus()
              Qt.callLater(() => Omunculus.watchRegistry(true))
            }
            Component.onCompleted: Omunculus.watchRegistry(true)
            Keys.onPressed: event => {
              if (!Typing.idle)
                return
              const at = Shortcuts.keys("start-way").indexOf(event.text)
              if (at >= 0 && at < panel.ways.length)
                (wayCards.itemAt(at) as StartCard).press()
            }
            Keys.onReturnPressed: (wayCards.itemAt(0) as StartCard).press()

            Column {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.min(panel.size === "narrow" ? 560 : 760, panel.width - 2 * panel.margin)
              // Whole pixels, or the first card's top hairline is not drawn;
              // never past the view's top on a short window.
              y: Math.round(Math.max(0, (parent.height - height) / 2))
              spacing: panel.short ? Theme.space.blockShort : Theme.space.block
              Label {
                visible: !Omunculus.registry
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: Omunculus.project.toUpperCase()
                color: Theme.dim
                elide: Text.ElideRight
                font.pixelSize: Theme.type.meta.size
                font.letterSpacing: Theme.type.meta.tracking
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "What now?"
                font.pixelSize: Theme.type.input.size
                font.bold: true
              }
              // The first way in is the main one, and the only one filled; two
              // by two where there is room.
              Grid {
                id: ways
                width: parent.width
                columns: panel.size === "narrow" ? 1 : 2
                spacing: Theme.space.gap
                Repeater {
                  id: wayCards
                  model: panel.ways
                  delegate: StartCard {
                    required property var modelData
                    required property int index
                    width: (ways.width - (ways.columns - 1) * ways.spacing) / ways.columns
                    primary: index === 0
                    title: modelData.text
                    detail: modelData.detail
                    key: String(index + 1).padStart(2, "0")
                    enabled: Omunculus.connected
                    onClicked: panel.enter(modelData.page)
                  }
                }
              }
              DecodeLabel {
                width: parent.width
                value: !Omunculus.connected ? "The server does not answer"
                  : panel.size === "narrow" ? "Tap a way in."
                  : "Press 1 to " + panel.ways.length + ", or click. Enter opens the first."
                soft: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Omunculus.connected ? Theme.faint : Theme.warning
                font.pixelSize: Theme.type.meta.size
                font.letterSpacing: Theme.type.meta.tracking
              }
              // The projects where conversations need you, most first, each
              // a way into its conversations; none is said before every
              // project is read.
              Column {
                readonly property var needing: Omunculus.connected ? Omunculus.projectRows.filter(row => row.needsYou > 0) : []
                readonly property bool reading: Omunculus.connected && Projects.reading(Omunculus.projectRows)
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.max(0, panel.width - 2 * panel.margin)
                spacing: Theme.space.line
                DecodeLabel {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: parent.reading
                  value: "reading what waits for you…"
                  soft: true
                  color: Theme.dim
                  font.pixelSize: Theme.type.meta.size
                  font.letterSpacing: Theme.type.meta.tracking
                }
                Repeater {
                  model: parent.reading ? [] : parent.needing
                  delegate: LinkLabel {
                    id: need
                    required property var modelData
                    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                    width: Math.min(implicitWidth, parent ? parent.width : implicitWidth)
                    value: need.modelData.id + " · " + need.modelData.needsYou + (need.modelData.needsYou === 1 ? " needs you" : " need you")
                    soft: true
                    elide: Text.ElideRight
                    color: over.hovered || activeFocus ? Theme.foreground : Theme.warning
                    font.pixelSize: Theme.type.meta.size
                    font.letterSpacing: Theme.type.meta.tracking
                    onClicked: {
                      panel.enterProject({ id: need.modelData.id, socket: need.modelData.socket }, "needs-you")
                    }
                    HoverHandler { id: over }
                  }
                }
              }
            }
          }

          // Entered: the pages, the rail and the bar of the one shown over a
          // project's or the registry's, and the page.
          Stage {
            anchors.fill: parent
            shown: panel.started
            // Coming in, the page on screen takes the keyboard once it can.
            onVisibleChanged: if (visible) pagesView.focusEntry()

            PagesView {
              id: pagesView
              // Beside the rail and under the bar, while they are there.
              anchors {
                fill: parent
                leftMargin: chrome.visible ? bar.x : 0
                topMargin: chrome.visible ? bar.height + panel.section : 0
              }
              active: panel.started
              onStartWanted: panel.started = false
              short: panel.short
            }

            Item {
              id: chrome
              anchors.fill: parent
              visible: !pagesView.inside

              TabRail {
                id: rail
                // Over the bar and the page while it unfolds, opaque.
                z: 1
                tabs: pagesView.pages.map(name => ({ name: name }))
                current: pagesView.tabIndex
                onChosen: index => pagesView.choose(index)
                onEscaped: pagesView.focusEntry()
              }

              PageBar {
                id: bar
                // No rail on a narrow window: the bar takes the whole width.
                anchors { left: parent.left; leftMargin: rail.visible ? rail.foldedWidth + Theme.space.section : 0; right: parent.right }
                height: rail.headHeight
                commands: pagesView.commands
                readout: pagesView.readout
                section: rail.current
                pages: rail.tabs
                current: rail.current
                pageSwitcher: true
                onPageChosen: index => pagesView.choose(index)
              }
            }

            // The digit a page shows chooses it while a page is being navigated;
            // Ctrl with it chooses it from a field being written too. Ctrl+Tab and
            // Ctrl+Shift+Tab go to the next or the previous page.
            Repeater {
              model: pagesView.pages.length
              delegate: Item {
                id: numbered
                required property int index
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen && frame.bare
                  sequence: Shortcuts.keys("page")[numbered.index]
                  onActivated: pagesView.choose(numbered.index)
                }
                Shortcut {
                  enabled: panel.started && !panel.dialogOpen
                  sequence: Shortcuts.keys("page-chord")[numbered.index]
                  onActivated: pagesView.choose(numbered.index)
                }
              }
            }
            // The chords of the page's commands and of its other chords, Alt+R
            // to answer and the like, which a
            // field being written leaves to them. They have no bare key: what
            // is typed never runs one.
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
              onActivated: pagesView.choose(pagesView.tabIndex + 1)
            }
            Shortcut {
              enabled: panel.started && !panel.dialogOpen
              sequences: Shortcuts.keys("previous-page")
              onActivated: pagesView.choose(pagesView.tabIndex - 1)
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
      // What the window tells, at its bottom right, above the composer.
      ToastStack {
        anchors { right: parent.right; bottom: parent.bottom; margins: panel.margin; bottomMargin: panel.margin + (panel.started ? pagesView.bottomRoom : 0) }
        width: Math.min(340, panel.width - 2 * panel.margin)
        maxHeight: panel.height / 2
        notices: Omunculus.notices.items
        onDismissed: id => Omunculus.notices.dismiss(id)
      }
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
    function jobs(): void { page("jobs") }
    // A job of the project, by its name, on its page, and the window asked to come forward.
    function job(name: string): void {
      if (Omunculus.project === "")
        return
      if (!panel.started)
        panel.enter("jobs")
      pagesView.showJob({ name: name })
      panel.contentItem.Window.window.requestActivate()
    }
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
      if (panel.started)
        pagesView.openProject(place)
      else
        panel.enterProject(place)
    }
    // A page by its name: projects, conversations, board or jobs, or, with a
    // conversation open, chat, tree, log, cost or artifacts.
    function page(name: string): void {
      if (!["projects", "conversations", "board", "jobs"].includes(name) && !(pagesView.open && pagesView.inConversation.includes(name)))
        return
      if (["conversations", "jobs"].includes(name) && Omunculus.project === "")
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
    function tree(): void { page("tree") }
    function log(): void { page("log") }
    function board(): void { page("board") }
    function back(): void { pagesView.back() }
    function send(message: string): void { Omunculus.send(message) }
  }
}
