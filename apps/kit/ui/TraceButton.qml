import QtQuick
import "Breakpoints.js" as Breakpoints

// TraceButton is a view's button. Its role says what pressing it does:
// "navigation" leaves for another view and slides away; "primary" is the
// view's main action, outlined and washed in the accent; "guarded" takes the
// error tone; any other ("progress", "action") stays in place. `filled`
// draws it solid in its tone, as a bar's main action is. It is never wider
// than `maximumWidth`, its caption eliding instead.
Rectangle {
  id: button

  property string role: "navigation"
  property string text
  property string icon
  property string tip
  property bool dense: false
  property bool armed: false
  property bool filled: false
  property bool busy: false
  property real maximumWidth: Breakpoints.room(parent)
  property color tone: role === "guarded" ? Theme.error : Theme.primary
  readonly property bool primary: role === "primary"
  readonly property bool running: busy
  readonly property bool hovered: pointer.containsMouse
  readonly property color ink: armed || filled ? Theme.readable(Theme.background, tone, Theme.foreground) : tone

  signal clicked()

  // Room on each side of the centred content.
  readonly property real side: dense ? 10 : 14
  readonly property real iconRoom: icon ? (dense ? 12 : 14) + content.spacing : 0
  implicitWidth: Math.max(dense ? 72 : 150, iconRoom + caption.implicitWidth + 2 * side)
  implicitHeight: dense ? Breakpoints.target(Window.width) : 44
  // The width, not the implicit width, is bounded: what sizes itself from the
  // button's implicit width never depends on its own.
  width: Math.min(implicitWidth, maximumWidth)
  activeFocusOnTab: true
  opacity: enabled ? 1 : 0.35
  color: armed || filled ? tone : (primary ? Qt.alpha(tone, 0.08) : "transparent")
  border.color: primary || filled ? tone : Theme.line
  scale: pointer.pressed ? 0.97 : 1
  transform: Translate { id: departure }

  Behavior on color { ColorAnimation { duration: 180 } }
  Behavior on border.color { ColorAnimation { duration: 150 } }
  Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

  Keys.onReturnPressed: press()
  Keys.onSpacePressed: press()
  Keys.onEscapePressed: event => { event.accepted = hint.visible; hint.dismiss() }

  onArmedChanged: if (armed) guardNudge.restart()

  function press() {
    if (!enabled || running)
      return
    hint.dismiss()
    if (role === "navigation") {
      if (depart.running)
        return
      depart.restart()
    }
    clicked()
  }

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

  // The content moves within the button, cut at its edges; the button
  // itself is not, so its hit area may reach past them.
  Item {
    anchors.fill: parent
    clip: true
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
        id: caption
        anchors.verticalCenter: parent.verticalCenter
        // Elided before it reaches the key or the edges.
        width: Math.min(implicitWidth, button.width - 2 * button.side - button.iconRoom)
        elide: Text.ElideRight
        value: button.text
        soft: true
        color: button.ink
        font.pixelSize: button.dense ? 10 : 11
        font.bold: button.armed
        font.letterSpacing: button.dense ? 1 : 1.4
      }
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
    anchors { fill: parent; margins: -4 }
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPressed: hint.dismiss()
    onClicked: button.press()
  }

  GuardNudge { id: guardNudge; targetObject: contentShift }
  FocusRing { border.color: button.armed ? Theme.background : Theme.primary }
  Hint { id: hint; active: button.hovered || button.activeFocus; text: button.tip }
}
