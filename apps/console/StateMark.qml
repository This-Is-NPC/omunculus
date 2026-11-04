import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui"

// A state as an icon and its word, the same in every progress view.
RowLayout {
  id: mark
  property string state
  property string clock
  property bool showWord: true
  readonly property var look: ({
    "working": { icon: "spark", tone: Theme.primary },
    "needs-you": { icon: "warning", tone: Theme.warning },
    "waiting": { icon: "people", tone: Theme.dim },
    "stopped": { icon: "warning", tone: Theme.warning },
    "failed": { icon: "close", tone: Theme.error },
    "done": { icon: "check", tone: Theme.success },
    "cancelled": { icon: "close", tone: Theme.dim },
    "up-next": { icon: "more", tone: Theme.dim }
  })[state] || { icon: "more", tone: Theme.primary }
  readonly property color tone: look.tone
  spacing: 4
  Icon { Layout.alignment: Qt.AlignVCenter; name: mark.look.icon; size: 12; color: mark.tone }
  Label {
    visible: mark.showWord
    Layout.alignment: Qt.AlignVCenter
    Layout.minimumWidth: 0
    Layout.fillWidth: true
    text: Progress.word(mark.state) + (mark.clock !== "" ? " " + mark.clock : "")
    color: mark.tone
    font.pixelSize: 11
    elide: Text.ElideRight
  }
}
