import QtQuick

// FocusRing outlines the control the keyboard is on, apart from its own border,
// so it shows whatever state the control is in: a hairline of the foreground ink,
// drawn inside the control so no container clips it. It is not the accent, which
// stays the mark of the current page, a chosen chip or the main action.
Rectangle {
  property bool shown: parent.activeFocus
  anchors.fill: parent
  anchors.margins: 2
  z: 1
  color: "transparent"
  border.color: Theme.foreground
  border.width: 1
  opacity: shown ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 110 } }
}
