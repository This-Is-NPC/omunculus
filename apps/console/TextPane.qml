pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// TextPane is what a command printed, a line each, in a frame that scrolls
// with the wheel or a drag, and with ↑/↓ and PgUp/PgDn while it holds the
// keyboard. A long line wraps; `tone` colours a line, given it and where it
// is, as a diff's added and removed ones.
Rectangle {
  id: pane

  property string text
  property var tone: (line, index) => Theme.foreground

  readonly property var lines: text === "" ? [] : text.replace(/\n$/, "").split("\n")

  color: "transparent"
  border.color: Theme.line
  activeFocusOnTab: true

  Keys.onPressed: event => {
    const step = { [Qt.Key_PageDown]: list.height, [Qt.Key_PageUp]: -list.height, [Qt.Key_Down]: 40, [Qt.Key_Up]: -40 }[event.key]
    if (step === undefined)
      return
    list.contentY = Math.max(list.originY, Math.min(list.originY + list.contentHeight - list.height, list.contentY + step))
    event.accepted = true
  }

  ListView {
    id: list
    anchors { fill: parent; margins: 10 }
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: pane.lines
    delegate: Label {
      required property string modelData
      required property int index
      width: ListView.view.width
      // An empty line keeps its height.
      text: modelData === "" ? " " : modelData
      color: pane.tone(modelData, index)
      font.pixelSize: 11
      wrapMode: Text.WrapAtWordBoundaryOrAnywhere
    }
  }

  FocusRing {}
}
