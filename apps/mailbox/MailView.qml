pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "gui"

// MailView reads one mail: its subject, what you wrote and what came back, in
// order. Below, what the mail waits for: the agents, while they work; you, on
// a decision; or nothing, and a reply sends it back to them.
ColumnLayout {
  id: view

  required property var mail

  spacing: 16

  ColumnLayout {
    Layout.fillWidth: true
    spacing: 6
    StateMark { state: view.mail.state }
    Label {
      Layout.fillWidth: true
      text: view.mail.subject
      font.pixelSize: 17
      font.bold: true
      wrapMode: Text.Wrap
    }
  }

  C.ScrollView {
    id: scroll
    Layout.fillWidth: true
    Layout.fillHeight: true
    clip: true
    contentWidth: availableWidth

    ColumnLayout {
      width: scroll.availableWidth
      spacing: 22

      Repeater {
        model: view.mail.letters
        delegate: Letter { Layout.fillWidth: true }
      }

      Repeater {
        model: view.mail.decisions
        delegate: Decision { Layout.fillWidth: true; mail: view.mail.id }
      }

      // While the agents work: only that they do.
      RowLayout {
        Layout.fillWidth: true
        visible: view.mail.state === "working"
        spacing: 12
        Repeater {
          model: 3
          delegate: Rectangle {
            required property int index
            implicitWidth: 6
            implicitHeight: 6
            color: Theme.primary
            SequentialAnimation on opacity {
              running: view.mail.state === "working"
              loops: Animation.Infinite
              PauseAnimation { duration: index * 200 }
              NumberAnimation { to: 0.15; duration: 500 }
              NumberAnimation { to: 1; duration: 500 }
              PauseAnimation { duration: (2 - index) * 200 }
            }
          }
        }
        Label {
          Layout.fillWidth: true
          text: "Your agents are working on it. The answer arrives here when they finish."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
    }
  }

  RowLayout {
    Layout.fillWidth: true
    visible: view.mail.state === "done"
    spacing: 8
    Editor {
      id: reply
      Layout.fillWidth: true
      Layout.preferredHeight: 84
      placeholderText: "reply, and the agents take it up again"
      onSubmitted: Mail.reply(view.mail.id, reply.take())
    }
    TraceButton {
      Layout.alignment: Qt.AlignBottom
      role: "primary"
      icon: "send"
      text: "REPLY"
      enabled: reply.text.trim() !== ""
      tip: "ctrl+enter"
      onClicked: Mail.reply(view.mail.id, reply.take())
    }
  }
}
