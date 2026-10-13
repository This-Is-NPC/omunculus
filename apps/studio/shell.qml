import QtQuick
import QtQuick.Layouts
import Quickshell
import "kit/ui"

ShellRoot {
  // The studio: an overview of every project, each workspace a band across
  // the depth lanes, then screens that edit one item of the project at a time.
  FloatingWindow {
    id: window

    title: "omunculus · studio"
    implicitWidth: Math.min(1400, screen ? screen.width - 96 : 1400)
    implicitHeight: Math.min(900, screen ? screen.height - 96 : 900)
    minimumSize: Qt.size(480, 360)
    color: Theme.background

    onClosed: Qt.quit()

    Rectangle {
      anchors.fill: parent
      color: Theme.background
      border.color: Theme.line

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 18

        Masthead {
          Layout.fillWidth: true
          Layout.fillHeight: false
          section: Studio.project
          StatusLine {
            message: Studio.message
            error: Studio.messageIsError
            offline: !Studio.connected
            count: Studio.noticeCount
            maxWidth: Math.max(0, window.width - 480)
          }
        }

        SettingsView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          active: true
        }
      }
    }
  }
}
