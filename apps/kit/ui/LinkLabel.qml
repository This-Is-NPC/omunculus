import QtQuick

// LinkLabel is a word pressed as a link: dim, lit on hover or focus, in the
// accent while `current`. The keyboard reaches it, and its hit area is larger
// than its letters.
DecodeLabel {
  id: link
  property bool current: false
  signal clicked()
  activeFocusOnTab: true
  Keys.onReturnPressed: clicked()
  Keys.onSpacePressed: clicked()
  color: current ? Theme.primary : pointer.containsMouse || activeFocus ? Theme.foreground : Theme.dim
  font.pixelSize: 11
  font.letterSpacing: 4
  MouseArea { id: pointer; anchors { fill: parent; margins: -12 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: link.clicked() }
  FocusRing { anchors.margins: -4 }
}
