import QtQuick
import QtQuick.Controls.Basic as C

// TextBox is a one-line input with a full outline that takes the accent on focus;
// `dense` makes it a list row's height; `invalid` outlines it in the error colour.
C.TextField {
  id: box
  property bool dense: false
  property bool invalid: false
  font.family: Theme.fontFamily
  font.pixelSize: dense ? 12 : 13
  color: Theme.foreground
  placeholderTextColor: Theme.dim
  selectionColor: Theme.primary
  selectedTextColor: Theme.badgeForeground
  leftPadding: dense ? Theme.space.gap : Theme.space.inset
  rightPadding: dense ? Theme.space.gap : Theme.space.inset
  // Marks that text is being written, and leaves the key to the box.
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: Typing.mark()
  topPadding: Theme.space.tight
  bottomPadding: Theme.space.tight
  background: InputFrame {
    implicitHeight: box.dense ? 30 : Theme.size.control
    focused: box.activeFocus
    invalid: box.invalid
  }
}
