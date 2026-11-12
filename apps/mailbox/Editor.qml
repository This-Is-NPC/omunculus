import QtQuick
import QtQuick.Controls.Basic as C
import "kit/ui"

// Editor is where a mail is written: several lines in a frame that takes the
// accent while it has the keyboard. It is as tall as its words, never under
// `minimumLines`, and never scrolls inside: the page or dialog around it does.
// Ctrl+Enter sends what it holds.
Item {
  id: editor

  property alias text: area.text
  property alias placeholderText: area.placeholderText
  // The least it shows, in lines.
  property int minimumLines: 6
  // The height its words take, padding included.
  readonly property real wordsHeight: area.contentHeight + 2 * area.padding

  signal submitted()

  function focusEntry() { area.forceActiveFocus() }

  // The text typed, trimmed; the editor is emptied once there is any.
  function take() {
    const value = area.text.trim()
    if (value !== "")
      area.text = ""
    return value
  }

  implicitHeight: Math.max(metrics.lineSpacing * minimumLines + 2 * area.padding, wordsHeight)

  InputFrame {
    anchors.fill: parent
    focused: area.activeFocus
  }

  FontMetrics { id: metrics; font: area.font }

  C.TextArea {
    id: area
    anchors.fill: parent
    wrapMode: TextEdit.Wrap
    font.family: Theme.fontFamily
    font.pixelSize: 13
    color: Theme.foreground
    placeholderTextColor: Theme.dim
    selectionColor: Theme.primary
    selectedTextColor: Theme.badgeForeground
    padding: 14
    background: null
    Keys.onPressed: event => {
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
        editor.submitted()
        event.accepted = true
      }
    }
  }
}
