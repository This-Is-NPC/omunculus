import QtQuick
import QtQuick.Layouts
import "kit/ui"

// A state as an icon and its word, the same in every progress view.
RowLayout {
  id: mark
  property string state
  property string word
  property string clock
  property bool showWord: true
  readonly property var look: ({
    "working": { icon: "spark", word: "Working", tone: Theme.primary },
    "needs-you": { icon: "warning", word: "Needs you", tone: Theme.warning },
    "waiting": { icon: "people", word: "Waiting", tone: Theme.dim },
    "stopped": { icon: "warning", word: "Stopped", tone: Theme.warning },
    "failed": { icon: "close", word: "Failed", tone: Theme.error },
    "done": { icon: "check", word: "Done", tone: Theme.success },
    "cancelled": { icon: "close", word: "Cancelled", tone: Theme.dim },
    "up-next": { icon: "more", word: "Up next", tone: Theme.dim }
  })[state] || { icon: "more", word: "", tone: Theme.primary }
  readonly property color tone: look.tone
  spacing: 4
  Icon { Layout.alignment: Qt.AlignVCenter; name: mark.look.icon; size: 12; color: mark.tone }
  Label {
    visible: mark.showWord
    Layout.alignment: Qt.AlignVCenter
    Layout.minimumWidth: 0
    Layout.fillWidth: true
    text: (mark.word || mark.look.word) + (mark.clock !== "" ? " " + mark.clock : "")
    color: mark.tone
    font.pixelSize: 11
    elide: Text.ElideRight
  }
}
