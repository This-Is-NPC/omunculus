pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Quickshell
import Quickshell.Io

ShellRoot {
  // The mailbox: the folders on the left, the mails of the one picked in the
  // middle, and on the right the mail open or the one being written.
  FloatingWindow {
    id: window

    title: "omunculus · mail"
    implicitWidth: 1180
    implicitHeight: 740
    minimumSize: Qt.size(720, 420)
    color: Theme.background

    onClosed: Qt.quit()

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      RowLayout {
        anchors.fill: parent
        spacing: 0

        // Folders.
        ColumnLayout {
          Layout.preferredWidth: 240
          Layout.maximumWidth: 240
          Layout.fillHeight: true
          spacing: 0

          RowLayout {
            Layout.margins: 20
            spacing: 10
            Label { text: "OMUNCULUS"; font.pixelSize: 14; font.bold: true; font.letterSpacing: 5 }
            Label { text: "╱"; color: Theme.primary }
            Label { text: "MAIL"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 3 }
          }

          Button {
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.bottomMargin: 16
            role: "primary"
            icon: "plus"
            text: "NEW MAIL"
            tip: "ctrl+n"
            enabled: Mail.connected
            onClicked: Mail.compose()
          }

          Folder { Layout.fillWidth: true; name: "inbox"; icon: "inbox"; label: "Inbox"; count: Mail.unread; tone: Mail.deciding > 0 ? Theme.warning : Theme.primary }
          Folder { Layout.fillWidth: true; name: "sent"; icon: "send"; label: "Sent"; count: Mail.working; tone: Theme.dim }

          Item { Layout.fillHeight: true }

          Label {
            Layout.fillWidth: true
            Layout.margins: 16
            text: Mail.message !== "" ? Mail.message
              : Mail.connected ? "project " + Mail.project : "the server does not answer"
            color: Mail.messageIsError || !Mail.connected ? Theme.warning : Theme.dim
            font.pixelSize: 10
            wrapMode: Text.Wrap
          }
        }

        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.line }

        // The mails of the folder.
        ColumnLayout {
          Layout.preferredWidth: Math.round(Math.min(380, Math.max(260, (window.width - 240) * 0.38)))
          Layout.maximumWidth: Layout.preferredWidth
          Layout.fillHeight: true
          spacing: 0

          Label {
            Layout.margins: 20
            Layout.bottomMargin: 14
            text: Mail.folder === "inbox" ? "INBOX" : "SENT"
            color: Theme.dim
            font.pixelSize: 10
            font.letterSpacing: 3
          }
          Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

          ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: Mail.shown
            boundsBehavior: Flickable.StopAtBounds
            C.ScrollBar.vertical: C.ScrollBar {}
            delegate: MailRow { width: list.width }
          }

          Label {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: Mail.shown.length === 0
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: Mail.folder === "inbox" ? "Nothing has come back yet." : "You have sent nothing yet."
            color: Theme.dim
            font.pixelSize: 12
          }
        }

        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.line }

        // The mail open, or the one being written.
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          ComposeView {
            id: compose
            anchors { fill: parent; margins: 24 }
            visible: Mail.composing
            onVisibleChanged: if (visible) Qt.callLater(compose.focusEntry)
          }

          Loader {
            anchors { fill: parent; margins: 24 }
            active: !Mail.composing && Mail.mail !== null
            sourceComponent: MailView { mail: Mail.mail }
          }

          Label {
            anchors.centerIn: parent
            visible: !Mail.composing && Mail.mail === null
            text: "Pick a mail, or write a new one."
            color: Theme.dim
            font.pixelSize: 12
          }
        }
      }

      Shortcut { sequence: "Ctrl+N"; onActivated: Mail.compose() }
      Shortcut { sequence: "Escape"; enabled: Mail.composing; onActivated: Mail.composing = false }
      // The next and the previous mail of the folder.
      Shortcut { sequence: "Alt+Down"; onActivated: window.step(1) }
      Shortcut { sequence: "Alt+Up"; onActivated: window.step(-1) }
    }

    function step(by) {
      const shown = Mail.shown
      if (shown.length === 0)
        return
      const at = shown.findIndex(mail => mail.id === Mail.selected)
      Mail.open(shown[Math.max(0, Math.min(shown.length - 1, at < 0 ? 0 : at + by))].id)
    }
  }

  // `quickshell ipc --path apps/mailbox call mailbox <function>`, e.g. from a shortcut.
  IpcHandler {
    target: "mailbox"
    function newMail(): void { Mail.compose() }
    function open(conversationId: string): void { Mail.open(conversationId) }
    function send(message: string): void { Mail.send(message) }
  }
}
