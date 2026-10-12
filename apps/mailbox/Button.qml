import QtQuick

// Button is the mailbox's button: a hairline outline that, as "primary", is
// washed in the accent; "quiet" drops the outline. Its underline grows on hover.
Rectangle {
  id: button

  property string text
  property string icon
  property string tip
  property string role: "action"
  property bool dense: false
  property color tone: Theme.primary
  readonly property bool hovered: pointer.containsMouse

  signal clicked()

  implicitWidth: Math.max(dense ? 64 : 120, content.implicitWidth + (dense ? 20 : 28))
  implicitHeight: dense ? 28 : 38
  activeFocusOnTab: true
  opacity: enabled ? 1 : 0.35
  color: role === "primary" ? Qt.alpha(tone, hovered ? 0.14 : 0.08) : hovered ? Qt.alpha(tone, 0.06) : "transparent"
  border.color: role === "primary" ? tone : role === "quiet" ? "transparent" : Theme.line
  scale: pointer.pressed ? 0.97 : 1

  Behavior on color { ColorAnimation { duration: 150 } }
  Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

  function press() { if (enabled) clicked() }
  Keys.onReturnPressed: press()
  Keys.onSpacePressed: press()

  Row {
    id: content
    anchors.centerIn: parent
    spacing: 8
    Icon {
      anchors.verticalCenter: parent.verticalCenter
      visible: button.icon !== ""
      name: button.icon
      size: button.dense ? 11 : 13
      color: button.tone
    }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      visible: button.text !== ""
      text: button.text
      color: button.tone
      font.pixelSize: button.dense ? 10 : 11
      font.letterSpacing: 1.4
    }
  }

  Rectangle {
    anchors { left: parent.left; bottom: parent.bottom }
    height: 2
    width: button.hovered ? parent.width : 0
    color: button.tone
    Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: button.press()
  }
  FocusRing {}
  Hint { visible: (button.hovered || button.activeFocus) && button.tip !== ""; text: button.tip }
}
