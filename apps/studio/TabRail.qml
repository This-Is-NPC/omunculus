pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// TabRail is the studio's sections as a carousel down the left edge: the one
// on screen sits at the top, stretched to the rail's width beside the command
// bar, its name decoding; the others follow in order below it, the ones
// before it coming round after the last. Choosing one turns the carousel
// until it is at the top.
Item {
  id: rail

  // [{name}], in order.
  required property var tabs
  property int current: 0
  // The height of the stretched tab, which the command bar shares.
  property real headHeight: 44

  signal chosen(int index)

  readonly property real tabHeight: 34
  readonly property real gap: 10

  implicitWidth: 260

  Repeater {
    model: rail.tabs
    delegate: Rectangle {
      id: tab
      required property var modelData
      required property int index
      // Its place in the carousel: 0 at the top.
      readonly property int slot: (index - rail.current + rail.tabs.length) % rail.tabs.length
      readonly property bool head: slot === 0
      readonly property color tone: head ? Theme.primary : pointer.containsMouse ? Theme.foreground : Theme.dim

      y: head ? 0 : rail.headHeight + rail.gap + (slot - 1) * (rail.tabHeight + rail.gap)
      width: head ? rail.width : 168
      height: head ? rail.headHeight : rail.tabHeight
      Behavior on y { NumberAnimation { duration: 360; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

      color: head ? Qt.tint(Theme.background, Qt.alpha(Theme.primary, 0.08)) : Theme.background
      border.color: head ? Qt.alpha(Theme.primary, 0.7) : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.35) : Theme.line
      // Further down, the carousel's names fade.
      readonly property real fade: head ? 1 : Math.max(0.4, 1 - (slot - 1) * 0.09)

      onHeadChanged: if (head) title.replay()

      Row {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: tab.head ? 16 : 12 }
        spacing: 10
        opacity: tab.fade
        Behavior on opacity { NumberAnimation { duration: 300 } }
        Label {
          anchors.verticalCenter: parent.verticalCenter
          text: String(tab.index + 1).padStart(2, "0")
          color: tab.head ? Theme.primary : Theme.line
          font.pixelSize: 10
          font.letterSpacing: 2
        }
        DecodeLabel {
          id: title
          anchors.verticalCenter: parent.verticalCenter
          value: tab.modelData.name.toUpperCase()
          color: tab.tone
          font.pixelSize: tab.head ? 13 : 10
          font.letterSpacing: tab.head ? 4 : 3
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: rail.chosen(tab.index)
      }
    }
  }
}
