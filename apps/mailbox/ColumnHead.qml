import QtQuick
import QtQuick.Layouts
import "gui"

// ColumnHead heads one column of the window, as eco's panels are headed: the
// column's name, dim and tracked, its count beside it, and at its right edge
// the arrow that folds the column. Folded, only the arrow that unfolds it
// shows, centred.
Item {
  id: head

  property string title
  property string count: ""
  property bool folded: false
  property string what: title.toLowerCase()
  property string shortcut

  signal toggle()

  implicitHeight: 28

  RowLayout {
    anchors.fill: parent
    visible: !head.folded
    spacing: 8
    DecodeLabel {
      value: head.title.toUpperCase()
      soft: true
      color: Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 3
    }
    Label { text: head.count; color: Theme.dim; font.pixelSize: 10; visible: head.count !== "" }
    Item { Layout.fillWidth: true }
    IconButton { name: "chevron-left"; tip: "fold the " + head.what + "  " + head.shortcut; onClicked: head.toggle() }
  }

  IconButton {
    visible: head.folded
    anchors.horizontalCenter: parent.horizontalCenter
    name: "chevron-right"
    tip: "unfold the " + head.what + "  " + head.shortcut
    onClicked: head.toggle()
  }
}
