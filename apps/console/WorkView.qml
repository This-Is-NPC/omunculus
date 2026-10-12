import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkView is one work on screen: what it is — its title, goal, agent,
// workflow stage and state, and the work it was handed down from — then its
// thread, where its agent says and does what it does, and a composer to write
// to that agent. Esc goes back.
ColumnLayout {
  id: view

  required property string work
  property bool compact: false

  readonly property var item: Omunculus.work(work)
  readonly property var parentWork: item ? Omunculus.work(item.parent_id || "") : null

  spacing: 14

  signal pendingChosen()

  function focusEntry() { composer.focusEntry() }

  SurfaceFrame {
    Layout.fillWidth: true
    implicitHeight: facts.implicitHeight + 24

    ColumnLayout {
      id: facts
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 14; rightMargin: 14 }
      spacing: 8

      RowLayout {
        Layout.fillWidth: true
        spacing: 10
        IconButton { Layout.alignment: Qt.AlignVCenter; name: "chevron-left"; tip: "back to the map  ·  esc"; onClicked: Omunculus.workId = "" }
        Dot { Layout.alignment: Qt.AlignVCenter; tone: Omunculus.stateTone(view.item ? view.item.state : ""); filled: view.item !== null && view.item.state !== "open"; size: 7 }
        Label {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          text: view.item ? view.item.title : ""
          font.pixelSize: 13
          elide: Text.ElideRight
        }
        Label { Layout.alignment: Qt.AlignVCenter; text: view.item ? String(view.item.state).toUpperCase() : ""; color: Omunculus.stateTone(view.item ? view.item.state : ""); font.pixelSize: 9; font.letterSpacing: 2 }
      }

      Label {
        Layout.fillWidth: true
        visible: view.item !== null && !!view.item.goal
        text: view.item ? Omunculus.inline(String(view.item.goal || "")) : ""
        textFormat: Text.MarkdownText
        color: Theme.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }

      Flow {
        Layout.fillWidth: true
        spacing: 18
        Row {
          spacing: 8
          Caption { anchors.verticalCenter: parent.verticalCenter; text: "AGENT" }
          Label { anchors.verticalCenter: parent.verticalCenter; text: view.item ? view.item.assignee || "—" : ""; color: Omunculus.toneOf(view.item ? view.item.assignee || "" : ""); font.pixelSize: 11 }
        }
        Row {
          visible: view.item !== null && !!view.item.stage
          spacing: 8
          Caption { anchors.verticalCenter: parent.verticalCenter; text: "STAGE" }
          Label { anchors.verticalCenter: parent.verticalCenter; text: view.item ? view.item.stage || "" : ""; font.pixelSize: 11 }
        }
        Row {
          visible: view.parentWork !== null
          spacing: 8
          Caption { anchors.verticalCenter: parent.verticalCenter; text: "FROM" }
          Label {
            anchors.verticalCenter: parent.verticalCenter
            text: view.parentWork ? view.parentWork.title : ""
            color: from.containsMouse ? Theme.primary : Theme.foreground
            font.pixelSize: 11
            font.underline: from.containsMouse
            MouseArea {
              id: from
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Omunculus.workId = view.parentWork.id
            }
          }
        }
      }
    }
  }

  TimelineView {
    Layout.fillWidth: true
    Layout.fillHeight: true
    thread: Omunculus.threadOf(view.work)
    emptyText: "NOTHING SAID HERE YET"
  }

  Composer {
    id: composer
    Layout.fillWidth: true
    compact: view.compact
    work: view.work
    onPendingChosen: view.pendingChosen()
  }
}
