import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ProgressSheet holds the progress tree, in the form its place asks for:
// "dock", a column beside the chat, its header PROGRESS and a close button;
// "card", under the strip, no header, as tall as the tree up to
// `maximumHeight`; "sheet", over the whole page, its header ‹ CHAT, PROGRESS
// and a close button, and Esc closes it. The tree scrolls inside.
Rectangle {
  id: sheet

  property string mode: "dock"
  property var progress: null
  // The card's tallest; the dock and the sheet fill what they are given.
  property real maximumHeight: Infinity

  signal closed()
  signal answer(string id)
  signal openThread(string work)
  signal openLog(string work)
  signal openMap(string work)
  // Esc in the dock or the card: the keyboard goes back to the composer.
  signal escaped()

  readonly property bool card: mode === "card"

  // Puts the keyboard on the tree's first row that does something.
  function focusTree() { tree.forceActiveFocus(); tree.move(-1, 1) }

  color: Theme.background
  border.color: Theme.line
  implicitHeight: Math.min(maximumHeight, (header.visible ? header.implicitHeight + column.spacing : 0) + tree.implicitHeight + Theme.space.insetTop * 2)
  Keys.onEscapePressed: mode === "sheet" ? closed() : escaped()

  ColumnLayout {
    id: column
    anchors { fill: parent; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset; topMargin: Theme.space.insetTop; bottomMargin: Theme.space.insetTop }
    spacing: Theme.space.tight

    RowLayout {
      id: header
      Layout.fillWidth: true
      visible: !sheet.card
      spacing: Theme.space.gap
      TraceButton {
        visible: sheet.mode === "sheet"
        role: "navigation"
        dense: true
        icon: "chevron-left"
        text: "CHAT"
        onClicked: sheet.closed()
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        horizontalAlignment: sheet.mode === "sheet" ? Text.AlignHCenter : Text.AlignLeft
        text: "PROGRESS"
        color: Theme.dim
        font.pixelSize: Theme.type.kicker.size
        font.letterSpacing: Theme.type.kicker.tracking
        elide: Text.ElideRight
      }
      IconButton {
        name: "close"
        tip: "close the progress"
        onClicked: sheet.closed()
      }
    }

    ScrollPage {
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentHeight: tree.implicitHeight

      ProgressTree {
        id: tree
        width: parent.width
        progress: sheet.progress
        onAnswer: id => sheet.answer(id)
        onOpenThread: work => sheet.openThread(work)
        onOpenLog: work => sheet.openLog(work)
        onOpenMap: work => sheet.openMap(work)
        onEscaped: sheet.mode === "sheet" ? sheet.closed() : sheet.escaped()
      }
    }
  }
}
