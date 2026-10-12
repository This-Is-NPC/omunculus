import QtQuick

// InputFrame is the outline every text input sits in: a faint fill and a
// hairline that, while the input has focus, takes the accent at two pixels.
Rectangle {
  property bool focused: false
  implicitWidth: 160
  color: Qt.alpha(Theme.foreground, 0.015)
  border.color: focused ? Theme.primary : Theme.line
  border.width: focused ? 2 : 1
  Behavior on border.color { ColorAnimation { duration: 150 } }
}
