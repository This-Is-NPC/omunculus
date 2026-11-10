pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "kit/ui"

ShellRoot {
  // The mailbox, an e-mail client: the masthead on top, whose notch sweeps
  // when the folder changes, then the folders (Inbox, Sent, Drafts, Archive),
  // the messages of the one picked and the thread open, parted by hairlines
  // that fade downwards, under a command bar whose actions follow where you
  // are. Each column is headed by its name and the arrow that folds it: the
  // folders to a rail, the list away, sliding to their width; a narrow window
  // shows one pane at a time. A new message is written in a dialog; a thread
  // is answered under its messages.
  FloatingWindow {
    id: window

    title: "omunculus · mail"
    implicitWidth: 1240
    implicitHeight: 780
    minimumSize: Qt.size(360, 420)
    color: Theme.background

    readonly property bool narrow: width < 760
    readonly property bool short: height < 560
    // Whether you folded the folders to a rail, and the threads away.
    property bool foldersFolded: width < 1100
    property bool listFolded: false
    readonly property bool reading: Mail.thread !== null

    onClosed: Qt.quit()

    function search() {
      listFolded = false
      Qt.callLater(() => searchBox.forceActiveFocus())
    }

    Connections {
      target: Mail
      function onComposeRequested(preset) { compose.start(preset) }
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: window.short ? 12 : 20
        spacing: window.short ? 10 : 16

        Masthead {
          Layout.fillWidth: true
          crumbs: [{ text: window.narrow && window.reading ? "thread" : Mail.folder }]
        }

        CommandBar {
          id: commands
          Layout.fillWidth: true
          place: window.reading ? "thread" : "list"
          narrow: window.narrow
          onCompose: Mail.compose()
        }

        // The one search box: in the command bar, or over the list on a narrow window.
        FilterBox {
          id: searchBox
          parent: window.narrow ? narrowSearch : commands.searchSlot
          anchors.fill: parent
          placeholderText: "search mail  /"
          onApplied: value => Mail.query = value.trim().toLowerCase()
          onLeave: threads.enter()
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 0

          // The folders, with their names, or folded to a rail of icons.
          Item {
            visible: !window.narrow
            Layout.fillHeight: true
            Layout.preferredWidth: window.foldersFolded ? 56 : 210
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            clip: true

            ColumnLayout {
              anchors { fill: parent; rightMargin: 12 }
              spacing: 4

              ColumnHead {
                Layout.fillWidth: true
                Layout.bottomMargin: 6
                title: "folders"
                folded: window.foldersFolded
                shortcut: "ctrl+b"
                onToggle: window.foldersFolded = !window.foldersFolded
              }
              FolderTab { Layout.fillWidth: true; rail: window.foldersFolded; name: "inbox"; icon: "import"; label: "Inbox"; count: Mail.unread }
              FolderTab { Layout.fillWidth: true; rail: window.foldersFolded; name: "sent"; icon: "send"; label: "Sent" }
              FolderTab { Layout.fillWidth: true; rail: window.foldersFolded; name: "drafts"; icon: "edit"; label: "Drafts"; count: Mail.drafts.length }
              FolderTab { Layout.fillWidth: true; rail: window.foldersFolded; name: "archive"; icon: "folder"; label: "Archive" }
              Item { Layout.fillHeight: true }
              Label {
                visible: !window.foldersFolded
                text: Mail.projects.length + (Mail.projects.length === 1 ? " PROJECT" : " PROJECTS")
                color: Theme.dim
                font.pixelSize: 9
                font.letterSpacing: 2
              }
            }
          }

          Divider { visible: !window.narrow }

          // The threads of the folder, found by the search and the projects.
          Item {
            visible: !window.narrow || !window.reading
            Layout.fillHeight: true
            Layout.fillWidth: window.narrow
            Layout.preferredWidth: window.narrow ? -1 : window.listFolded ? 0 : Math.round(Math.min(420, Math.max(300, window.width * 0.32)))
            Behavior on Layout.preferredWidth { enabled: !window.narrow; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            clip: true

            ColumnLayout {
              anchors { fill: parent; leftMargin: window.narrow ? 0 : 16; rightMargin: window.narrow ? 0 : 16 }
              spacing: 10

              ColumnHead {
                Layout.fillWidth: true
                visible: !window.narrow
                title: Mail.folder
                count: String(Mail.folder === "drafts" ? Mail.shownDrafts.length : Mail.shown.length)
                shortcut: "ctrl+l"
                onToggle: window.listFolded = true
              }
              RowLayout {
                Layout.fillWidth: true
                visible: window.narrow
                spacing: 4
                FolderTab { rail: true; name: "inbox"; icon: "import"; label: "Inbox"; count: Mail.unread }
                FolderTab { rail: true; name: "sent"; icon: "send"; label: "Sent" }
                FolderTab { rail: true; name: "drafts"; icon: "edit"; label: "Drafts"; count: Mail.drafts.length }
                FolderTab { rail: true; name: "archive"; icon: "folder"; label: "Archive" }
              }
              Item { id: narrowSearch; visible: window.narrow; Layout.fillWidth: true; Layout.preferredHeight: 30 }
              ProjectFilter { Layout.fillWidth: true }
              ThreadList {
                id: threads
                visible: Mail.folder !== "drafts"
                Layout.fillWidth: true
                Layout.fillHeight: true
                onCleared: searchBox.text = ""
              }
              DraftList {
                visible: Mail.folder === "drafts"
                Layout.fillWidth: true
                Layout.fillHeight: true
              }
            }
          }

          // The threads folded away leave their head's arrow, to unfold them,
          // over a rail of the threads, to move between them.
          ColumnLayout {
            visible: !window.narrow && window.listFolded
            Layout.fillHeight: true
            Layout.fillWidth: false
            Layout.preferredWidth: 44
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            spacing: 10
            ColumnHead {
              Layout.fillWidth: true
              title: Mail.folder
              folded: true
              shortcut: "ctrl+l"
              onToggle: window.listFolded = false
            }
            ThreadRail {
              Layout.fillWidth: true
              Layout.fillHeight: true
            }
          }

          Divider { visible: !window.narrow }

          // The thread open, sliding in as a Stage does each time another opens.
          Item {
            visible: !window.narrow || window.reading
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            Repeater {
              model: Mail.thread ? [Mail.selected] : []
              delegate: Item {
                id: page
                required property string modelData
                anchors.fill: parent
                opacity: 0
                transform: Translate { id: slide; x: 28 }
                Component.onCompleted: enter.start()
                ParallelAnimation {
                  id: enter
                  NumberAnimation { target: page; property: "opacity"; to: 1; duration: 220; easing.type: Easing.OutCubic }
                  NumberAnimation { target: slide; property: "x"; to: 0; duration: 280; easing.type: Easing.OutCubic }
                }
                ThreadView {
                  anchors { fill: parent; leftMargin: window.narrow ? 0 : 20 }
                  thread: Mail.threads[page.modelData] || Mail.blank
                  back: window.narrow
                  escapes: !searchBox.activeFocus && !compose.opened
                }
              }
            }

            Column {
              anchors.centerIn: parent
              visible: Mail.thread === null
              spacing: 14
              DecodeLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                value: "PICK A MESSAGE, OR WRITE A NEW ONE"
                soft: true
                color: Theme.dim
                font.pixelSize: 10
                font.letterSpacing: 3
              }
              Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "/ SEARCH   ·   CTRL+N COMPOSE   ·   ALT+↑↓ MOVE"
                color: Theme.line
                font.pixelSize: 10
                font.letterSpacing: 2
              }
            }
          }
        }
      }

      ComposeDialog { id: compose }
      // What the window tells, at its bottom right.
      ToastStack {
        anchors { right: parent.right; bottom: parent.bottom; margins: window.short ? 12 : 20 }
        width: Math.min(340, window.width - 40)
        maxHeight: window.height / 2
        notices: Mail.notices.items
        onDismissed: id => Mail.notices.dismiss(id)
      }

      Shortcut { sequence: "Ctrl+N"; onActivated: Mail.compose() }
      Shortcut { sequence: "/"; onActivated: window.search() }
      Shortcut { sequence: "Ctrl+B"; enabled: !window.narrow; onActivated: window.foldersFolded = !window.foldersFolded }
      Shortcut { sequence: "Ctrl+L"; enabled: !window.narrow; onActivated: window.listFolded = !window.listFolded }
      Shortcut { sequence: "Alt+Down"; onActivated: Mail.step(1) }
      Shortcut { sequence: "Alt+Up"; onActivated: Mail.step(-1) }
    }
  }

  // `quickshell ipc --path apps/mailbox call mailbox <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "mailbox"
    function compose(): void { Mail.compose() }
    function open(key: string): void { Mail.open(key) }
    function search(query: string): void { searchBox.text = query; window.search() }
    // "folders" or "list".
    function fold(pane: string): void { if (pane === "folders") window.foldersFolded = !window.foldersFolded; else window.listFolded = !window.listFolded }
    function reply(): void { Mail.replyRequested("") }
  }
}
