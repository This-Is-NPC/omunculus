pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Decision answers a request that waits on you: its options and those of the
// decisions it gathers from below as buttons, and a
// field for an answer in your own words, which goes with an option or alone.
// Deny and cancel ask to be pressed twice. The entry's head holds the ANSWER
// of a request with no option, which sends what is written, or, with nothing
// written, takes you to the box.
ColumnLayout {
  id: decision

  required property var entry
  required property string thread
  required property string project
  // How many decisions it offers; none, it asks for words.
  readonly property int choices: entry.choices.length

  // The box took the keyboard.
  signal reveal()

  // Sends what is written, or takes you to the box while nothing is.
  function submit() {
    if (answer.text.trim() === "")
      answer.focusEntry()
    else
      Mail.decide(thread, entry.key, "", answer.text)
  }

  spacing: 10

  // Each decision as buttons: the request's own options, then those of the
  // decisions it gathers from below, each under its part name when there are
  // several.
  Repeater {
    model: decision.entry.choices
    delegate: ColumnLayout {
      id: choice
      required property var modelData
      Layout.fillWidth: true
      spacing: 4
      Label {
        // Never an agent's name: the thread's agent is the only one you know.
        visible: decision.entry.choices.length > 1 && choice.modelData.part !== "" && !Mail.isAgent(decision.project, choice.modelData.part)
        text: choice.modelData.part.replace(/_/g, " ").toUpperCase()
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 1.5
      }
      Flow {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
          model: choice.modelData.options
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
                Mail.decide(decision.thread, decision.entry.key, modelData, answer.text, choice.modelData.path)
              }
            }
            Timer { id: disarm; interval: 3000; onTriggered: option.armed = false }
          }
        }
      }
    }
  }

  Editor {
    id: answer
    Layout.fillWidth: true
    // It grows with its words, so the card holds no scroll box of its own.
    Layout.preferredHeight: Math.max(64, answer.wordsHeight)
    placeholderText: decision.entry.choices.length > 0 ? "a word with your choice, or an answer of your own" : "your answer"
    onSubmitted: Mail.decide(decision.thread, decision.entry.key, "", answer.text)
    onActiveFocusChanged: if (activeFocus) decision.reveal()
  }
  // With options, the box is a word with a choice: ANSWER sends it alone.
  TraceButton {
    Layout.alignment: Qt.AlignRight
    visible: decision.choices > 0
    dense: true
    role: "progress"
    icon: "enter"
    text: "ANSWER"
    enabled: answer.text.trim() !== ""
    tip: "ctrl+enter"
    onClicked: decision.submit()
  }
}
