pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// CommandBar is the bar beside the carousel's head: the commands of the
// section on screen, which slide in when the section changes, and at its end
// the studio's readout.
Rectangle {
  id: bar

  // [{text, icon, tip, role, run, shown}], in order.
  property var commands: []
  // Changes when the section does, so the commands arrive again.
  property int section: 0

  color: Qt.alpha(Theme.background, 0.9)
  border.color: Theme.line

  onSectionChanged: arrive.restart()

  RowLayout {
    anchors { fill: parent; leftMargin: 8; rightMargin: 12 }
    spacing: 6

    Row {
      id: contextual
      Layout.alignment: Qt.AlignVCenter
      spacing: 6
      transform: Translate { id: shift }

      Repeater {
        model: bar.commands.filter(command => command.shown !== false)
        delegate: TraceButton {
          required property var modelData
          dense: true
          role: modelData.role || "progress"
          icon: modelData.icon || ""
          text: modelData.text
          tip: modelData.tip || ""
          enabled: modelData.enabled !== false
          onClicked: modelData.run()
        }
      }
    }

    ParallelAnimation {
      id: arrive
      NumberAnimation { target: contextual; property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
      NumberAnimation { target: shift; property: "x"; from: 16; to: 0; duration: 260; easing.type: Easing.OutCubic }
    }

    Item { Layout.fillWidth: true }

    StatusLine {
      Layout.alignment: Qt.AlignVCenter
      message: Studio.message
      error: Studio.messageIsError
      offline: !Studio.connected
      count: Studio.noticeCount
      maxWidth: Math.max(0, bar.width - contextual.width - 80)
    }
  }
}
