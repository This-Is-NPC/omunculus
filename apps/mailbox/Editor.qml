import QtQuick
import QtQuick.Controls.Basic as C
import "kit/ui"

// Editor is where a mail is written: several lines in a frame that takes the
// accent while it has the keyboard. Ctrl+Enter sends what it holds.
C.ScrollView {
  id: editor

  property alias text: area.text
  property alias placeholderText: area.placeholderText
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

  clip: true
  background: InputFrame { focused: area.activeFocus }

  C.TextArea {
    id: area
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
