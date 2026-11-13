import QtQuick
import QtQuick.Layouts

// StateMark is a state as an icon and its word, the one status grammar of
// every view: `state` is a Progress state (working, needs-you, waiting,
// stopped, failed, done, cancelled, up-next, idle), `text` the words when not
// the state's own ("WAITING FOR designer"), `clock` a time after them. The
// state's own words are the ones of `Progress.word`.
RowLayout {
  id: mark
  property string state
  property string clock
  // Its words, when not the state's own ("designer working").
  property string text
  property bool showWord: true
  readonly property var look: ({
    "working": { icon: "spark", word: "Working", tone: Theme.primary },
    "needs-you": { icon: "warning", word: "Needs you", tone: Theme.warning },
    "waiting": { icon: "people", word: "Waiting", tone: Theme.dim },
    "stopped": { icon: "warning", word: "Stopped", tone: Theme.warning },
    "failed": { icon: "close", word: "Failed", tone: Theme.error },
    "done": { icon: "check", word: "Done", tone: Theme.success },
    "cancelled": { icon: "close", word: "Cancelled", tone: Theme.dim },
    "up-next": { icon: "more", word: "Up next", tone: Theme.dim },
    "idle": { icon: "people", word: "", tone: Theme.dim }
  })[state] || { icon: "more", word: "", tone: Theme.primary }
  readonly property color tone: look.tone
  // The words' font, to measure them.
  readonly property alias font: word.font
  spacing: Theme.space.line
  Icon { Layout.alignment: Qt.AlignVCenter; name: mark.look.icon; size: 12; color: mark.tone }
  Label {
    id: word
    visible: mark.showWord
    Layout.alignment: Qt.AlignVCenter
    Layout.minimumWidth: 0
    Layout.fillWidth: true
    text: (mark.text !== "" ? mark.text : mark.look.word) + (mark.clock !== "" ? " " + mark.clock : "")
    color: mark.tone
    font.pixelSize: 11
    elide: Text.ElideRight
  }
}
