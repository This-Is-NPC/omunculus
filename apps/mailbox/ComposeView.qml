import QtQuick
import QtQuick.Layouts

// ComposeView writes a new mail: what you need, in as many lines as it takes.
// Sending opens a conversation of its own and hands it to the root agent.
ColumnLayout {
  id: view

  spacing: 16

  function focusEntry() { body.focusEntry() }

  Label { text: "NEW MAIL"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 3 }
  Label {
    Layout.fillWidth: true
    text: "Say what you need. You hear back when it is done, or when a decision is yours."
    color: Theme.dim
    font.pixelSize: 12
    wrapMode: Text.Wrap
  }
  Editor {
    id: body
    Layout.fillWidth: true
    Layout.fillHeight: true
    placeholderText: "what you need"
    onSubmitted: Mail.send(body.take())
  }
  RowLayout {
    Layout.fillWidth: true
    spacing: 8
    Item { Layout.fillWidth: true }
    Button {
      role: "quiet"
      text: "DISCARD"
      onClicked: { body.text = ""; Mail.composing = false }
    }
    Button {
      role: "primary"
      icon: "send"
      text: "SEND"
      enabled: body.text.trim() !== "" && Mail.connected
      tip: "ctrl+enter"
      onClicked: Mail.send(body.take())
    }
  }
}
