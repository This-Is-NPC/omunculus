import QtQuick

Rectangle {
  id: button

  property string role: "navigation"
  property string text
  property string icon
  property string tip
  property bool dense: false
  property bool armed: false
  property bool busy: false
  property bool allowClickWhileBusy: false
  property color tone: role === "guarded" ? Theme.error : Theme.primary
  readonly property bool running: busy
  readonly property bool hovered: pointer.containsMouse
  readonly property color ink: armed ? Theme.readable(Theme.background, tone, Theme.foreground) : tone

  signal clicked()

  implicitWidth: Math.max(dense ? 72 : 150, content.implicitWidth + (dense ? 20 : 28))
  implicitHeight: dense ? 28 : 44
  activeFocusOnTab: true
  clip: true
  opacity: enabled ? 1 : 0.35
  color: armed ? tone : "transparent"
  border.color: Theme.line
  scale: pointer.pressed ? 0.97 : 1
  transform: Translate { id: departure }

  Behavior on color { ColorAnimation { duration: 180 } }
  Behavior on border.color { ColorAnimation { duration: 150 } }
  Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

  Keys.onReturnPressed: press()
  Keys.onSpacePressed: press()

  onArmedChanged: if (armed) guardNudge.restart()

  function press() {
    if (!enabled || (running && !allowClickWhileBusy))
      return
    if (role === "navigation") {
      if (depart.running)
        return
      depart.restart()
    }
    clicked()
  }

  function restartTrace() { trace.restart() }

  SequentialAnimation {
    id: depart
    NumberAnimation { target: departure; property: "x"; from: 0; to: 36; duration: 160; easing.type: Easing.OutCubic }
    PauseAnimation { duration: 120 }
    NumberAnimation { target: departure; property: "x"; to: 0; duration: 0 }
  }

  LoadingTrace {
    id: trace
    anchors { fill: parent; leftMargin: 12; rightMargin: 12; topMargin: 7; bottomMargin: 7 }
    running: button.running
    tone: button.tone
    backdrop: button.color
  }

  Row {
    id: content
    // Back once the trace has reached the end and gone.
    visible: !trace.visible
    anchors.centerIn: parent
    spacing: 10
    transform: Translate { id: contentShift }

    Icon {
      anchors.verticalCenter: parent.verticalCenter
      visible: button.icon.length > 0
      name: button.icon
      size: button.dense ? 12 : 14
      color: button.ink
    }
    DecodeLabel {
      anchors.verticalCenter: parent.verticalCenter
      value: button.text
      soft: true
      color: button.ink
      font.pixelSize: button.dense ? 10 : 11
      font.bold: button.armed
      font.letterSpacing: button.dense ? 1 : 1.4
    }
  }

  Rectangle {
    anchors { left: parent.left; bottom: parent.bottom }
    height: 2
    width: button.hovered && !button.running ? parent.width : 0
    color: button.ink
    Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: button.press()
  }

  GuardNudge { id: guardNudge; targetObject: contentShift }
  FocusRing { border.color: button.armed ? Theme.background : Theme.primary }
  Hint { visible: (button.hovered || button.activeFocus) && button.tip.length > 0; text: button.tip }
}
