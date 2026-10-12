pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// Decision is a request that waits on you: who asks, what for, the questions
// it gathers from below, its options as buttons, and a field for an answer in
// your own words, which goes with an option or alone.
SurfaceFrame {
  id: card

  required property var modelData
  property string mail: ""
  readonly property var request: modelData

  implicitHeight: content.implicitHeight + 28
  variant: "filled"
  tone: Theme.warning

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Icon { name: "warning"; size: 11; color: Theme.warning }
      Label { text: "YOUR DECISION"; color: Theme.warning; font.pixelSize: 10; font.letterSpacing: 3 }
      Item { Layout.fillWidth: true }
      Label { text: card.request.asker + "  ·  " + Mail.when(card.request.at); color: Theme.dim; font.pixelSize: 10 }
    }

    Label {
      Layout.fillWidth: true
      text: Mail.markdown(card.request.reason)
      textFormat: Text.MarkdownText
      linkColor: Theme.primary
      onLinkActivated: link => Qt.openUrlExternally(link)
      wrapMode: Text.Wrap
    }

    Repeater {
      model: card.request.origins
      delegate: Label {
        required property var modelData
        Layout.fillWidth: true
        text: "· " + modelData.part + ": " + String(modelData.reason || "").replace(/\s+/g, " ")
        color: Theme.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }

    Flow {
      Layout.fillWidth: true
      visible: card.request.options.length > 0
      spacing: 6
      Repeater {
        model: card.request.options
        delegate: Button {
          required property string modelData
          dense: true
          role: modelData === "deny" || modelData === "cancel" ? "action" : "primary"
          tone: modelData === "deny" || modelData === "cancel" ? Theme.error : Theme.primary
          text: modelData.replace(/_/g, " ").toUpperCase()
          tip: answer.text.trim() !== "" ? "with what you wrote" : ""
          onClicked: Mail.decide(card.mail, card.request.id, modelData, answer.text)
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Editor {
        id: answer
        Layout.fillWidth: true
        Layout.preferredHeight: 64
        placeholderText: card.request.options.length > 0 ? "a word with your choice, or an answer of your own" : "your answer"
        onSubmitted: Mail.decide(card.mail, card.request.id, "", answer.text)
      }
      Button {
        dense: true
        icon: "send"
        text: "ANSWER"
        enabled: answer.text.trim() !== ""
        tip: "ctrl+enter"
        onClicked: Mail.decide(card.mail, card.request.id, "", answer.text)
      }
    }
  }
}
