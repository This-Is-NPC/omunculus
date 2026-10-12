pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "gui"

// Decision answers a request that waits on you: the questions it gathers from
// below, its options as buttons, and a field for an answer in your own words,
// which goes with an option or alone.
ColumnLayout {
  id: decision

  required property var entry
  required property string thread

  spacing: 10

  Repeater {
    model: decision.entry.origins
    delegate: Label {
      required property var modelData
      Layout.fillWidth: true
      text: "· " + modelData.part + ": " + String(modelData.reason).replace(/\s+/g, " ")
      color: Theme.dim
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }
  }

  Flow {
    Layout.fillWidth: true
    visible: decision.entry.options.length > 0
    spacing: 6
    Repeater {
      model: decision.entry.options
      delegate: TraceButton {
        required property string modelData
        dense: true
        role: modelData === "deny" || modelData === "cancel" ? "guarded" : "primary"
        text: modelData.replace(/_/g, " ").toUpperCase()
        tip: answer.text.trim() !== "" ? "with what you wrote" : ""
        onClicked: Mail.decide(decision.thread, decision.entry.key, modelData, answer.text)
      }
    }
  }

  Editor {
    id: answer
    Layout.fillWidth: true
    Layout.preferredHeight: 64
    placeholderText: decision.entry.options.length > 0 ? "a word with your choice, or an answer of your own" : "your answer"
    onSubmitted: Mail.decide(decision.thread, decision.entry.key, "", answer.text)
  }
  TraceButton {
    Layout.alignment: Qt.AlignRight
    dense: true
    role: "progress"
    icon: "send"
    text: "ANSWER"
    enabled: answer.text.trim() !== ""
    tip: "ctrl+enter"
    onClicked: Mail.decide(decision.thread, decision.entry.key, "", answer.text)
  }
}
