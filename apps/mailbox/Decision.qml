pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Decision answers a request that waits on you: the questions it gathers from
// below, its options as buttons, and a field for an answer in your own words,
// which goes with an option or alone. Deny and cancel ask to be pressed twice.
ColumnLayout {
  id: decision

  required property var entry
  required property string thread

  spacing: 10

  Repeater {
    model: decision.entry.origins
    delegate: Prose {
      required property var modelData
      Layout.fillWidth: true
      source: "· " + modelData.part + ": " + String(modelData.reason).replace(/\s+/g, " ")
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
        id: option
        required property string modelData
        readonly property bool guarded: modelData === "deny" || modelData === "cancel"
        dense: true
        role: guarded ? "guarded" : "primary"
        text: armed ? "CONFIRM " + modelData.toUpperCase() : modelData.replace(/_/g, " ").toUpperCase()
        tip: armed ? "press again to confirm" : answer.text.trim() !== "" ? "with what you wrote" : ""
        // A guarded answer is armed by the first press and given by the second.
        onClicked: {
          if (guarded && !armed) {
            armed = true
            disarm.restart()
          } else {
            Mail.decide(decision.thread, decision.entry.key, modelData, answer.text)
          }
        }
        Timer { id: disarm; interval: 3000; onTriggered: option.armed = false }
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
    icon: "enter"
    text: "ANSWER"
    enabled: answer.text.trim() !== ""
    tip: "ctrl+enter"
    onClicked: Mail.decide(decision.thread, decision.entry.key, "", answer.text)
  }
}
