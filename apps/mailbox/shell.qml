pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Quickshell
import Quickshell.Io
import "gui"

ShellRoot {
  // The mailbox: the folders, the threads of the one picked, and the thread
  // open or the one being written. Wide, all three side by side; narrower, the
  // folders become a rail of icons; narrow, one pane at a time, the folders
  // in a bar on top.
  FloatingWindow {
    id: window

    title: "omunculus · mail"
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(360, 420)
    color: Theme.background

    readonly property bool narrow: width < 760
    readonly property bool rail: !narrow && width < 1100
    // On a narrow window, the pane shown: the thread or new thread when there
    // is one, else the list.
    readonly property bool reading: Mail.composing || Mail.thread !== null

    onClosed: Qt.quit()

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Narrow: the folders as a bar on top.
        RowLayout {
          Layout.fillWidth: true
          Layout.margins: 10
          visible: window.narrow && !window.reading
          spacing: 6
          Label { text: "MAIL"; font.bold: true; font.letterSpacing: 4; Layout.rightMargin: 6 }
          Folder { rail: true; name: "all"; icon: "import"; label: "All threads"; count: Mail.unread }
          Folder { rail: true; name: "waiting"; icon: "warning"; label: "Waiting for you"; count: Mail.waiting; tone: Theme.warning }
          Folder { rail: true; name: "working"; icon: "spark"; label: "Working"; count: Mail.working; tone: Theme.dim }
          Item { Layout.fillWidth: true }
          IconButton { name: "plus"; tip: "new thread"; enabled: Mail.connected; onClicked: Mail.compose() }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line; visible: window.narrow && !window.reading }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 0

          // Wide: the folders with their names; narrower: a rail of icons.
          ColumnLayout {
            visible: !window.narrow
            Layout.preferredWidth: window.rail ? 56 : 230
            Layout.maximumWidth: Layout.preferredWidth
            Layout.fillHeight: true
            spacing: 2

            RowLayout {
              Layout.margins: 18
              visible: !window.rail
              spacing: 10
              Label { text: "OMUNCULUS"; font.pixelSize: 14; font.bold: true; font.letterSpacing: 5 }
              Label { text: "╱"; color: Theme.primary }
              Label { text: "MAIL"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 3 }
            }
            TraceButton {
              visible: !window.rail
              Layout.fillWidth: true
              Layout.leftMargin: 14
              Layout.rightMargin: 14
              Layout.bottomMargin: 14
              role: "primary"
              icon: "plus"
              text: "NEW THREAD"
              tip: "ctrl+n"
              enabled: Mail.connected
              onClicked: Mail.compose()
            }
            IconButton {
              visible: window.rail
              Layout.alignment: Qt.AlignHCenter
              Layout.topMargin: 14
              Layout.bottomMargin: 14
              name: "plus"
              tip: "new thread"
              enabled: Mail.connected
              onClicked: Mail.compose()
            }

            Folder { Layout.fillWidth: true; rail: window.rail; name: "all"; icon: "import"; label: "All threads"; count: Mail.unread }
            Folder { Layout.fillWidth: true; rail: window.rail; name: "waiting"; icon: "warning"; label: "Waiting for you"; count: Mail.waiting; tone: Theme.warning }
            Folder { Layout.fillWidth: true; rail: window.rail; name: "working"; icon: "spark"; label: "Working"; count: Mail.working; tone: Theme.dim }

            Item { Layout.fillHeight: true }

            Label {
              Layout.fillWidth: true
              Layout.margins: 14
              visible: !window.rail
              text: Mail.message !== "" ? Mail.message : Mail.connected ? Mail.projects.length + " projects" : "the server does not answer"
              color: Mail.messageIsError || !Mail.connected ? Theme.warning : Theme.dim
              font.pixelSize: 10
              wrapMode: Text.Wrap
            }
          }

          Rectangle { visible: !window.narrow; Layout.fillHeight: true; implicitWidth: 1; color: Theme.line }

          // The threads of the folder.
          ColumnLayout {
            visible: !window.narrow || !window.reading
            Layout.fillWidth: window.narrow
            Layout.preferredWidth: window.narrow ? -1 : Math.round(Math.min(400, Math.max(280, window.width * 0.32)))
            Layout.maximumWidth: window.narrow ? Number.POSITIVE_INFINITY : Layout.preferredWidth
            Layout.fillHeight: true
            spacing: 0

            ColumnLayout {
              Layout.fillWidth: true
              Layout.margins: 16
              Layout.bottomMargin: 12
              spacing: 10
              Label {
                text: ({ all: "ALL THREADS", waiting: "WAITING FOR YOU", working: "WORKING" })[Mail.folder]
                color: Theme.dim
                font.pixelSize: 10
                font.letterSpacing: 3
              }
              ProjectFilter { Layout.fillWidth: true }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

            ListView {
              id: list
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: Mail.shown.length > 0
              clip: true
              model: Mail.shown
              boundsBehavior: Flickable.StopAtBounds
              C.ScrollBar.vertical: C.ScrollBar {}
              delegate: ThreadRow { width: list.width }
            }

            Label {
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: Mail.shown.length === 0
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              wrapMode: Text.Wrap
              text: !Mail.connected ? "The server does not answer."
                : Mail.folder === "waiting" ? "Nothing waits for you."
                : Mail.folder === "working" ? "No agent is working."
                : "No threads yet. Start one with an agent."
              color: Theme.dim
              font.pixelSize: 12
            }
          }

          Rectangle { visible: !window.narrow; Layout.fillHeight: true; implicitWidth: 1; color: Theme.line }

          // The thread open, or the one being written.
          Item {
            visible: !window.narrow || window.reading
            Layout.fillWidth: true
            Layout.fillHeight: true

            ComposeView {
              id: compose
              anchors { fill: parent; margins: window.narrow ? 12 : 22 }
              visible: Mail.composing
              back: window.narrow
              onVisibleChanged: if (visible) Qt.callLater(compose.focusEntry)
            }

            Loader {
              anchors { fill: parent; margins: window.narrow ? 12 : 22 }
              active: !Mail.composing && Mail.thread !== null
              sourceComponent: ThreadView { thread: Mail.thread; back: window.narrow }
            }

            Label {
              anchors.centerIn: parent
              visible: !Mail.composing && Mail.thread === null
              text: "Pick a thread, or start a new one."
              color: Theme.dim
              font.pixelSize: 12
            }
          }
        }
      }

      Shortcut { sequence: "Ctrl+N"; onActivated: Mail.compose() }
      Shortcut { sequence: "Escape"; enabled: window.reading; onActivated: Mail.close() }
      // The next and the previous thread of the list.
      Shortcut { sequence: "Alt+Down"; onActivated: window.step(1) }
      Shortcut { sequence: "Alt+Up"; onActivated: window.step(-1) }
    }

    function step(by) {
      const shown = Mail.shown
      if (shown.length === 0)
        return
      const at = shown.findIndex(thread => thread.key === Mail.selected)
      Mail.open(shown[Math.max(0, Math.min(shown.length - 1, at < 0 ? 0 : at + by))].key)
    }
  }

  // `quickshell ipc --path apps/mailbox call mailbox <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "mailbox"
    function newThread(): void { Mail.compose() }
    function open(key: string): void { Mail.open(key) }
  }
}
