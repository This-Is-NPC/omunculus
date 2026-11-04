pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// TeamRow is one thing the team did among itself, on one muted line: who
// asked whom, and what came of it. Choosing it opens the question and the
// answer below; what it is given as children shows there too.
Item {
  id: row

  // The line, the question asked and the answer to it, if any.
  property string summary
  property string question
  property string answer
  property string stamp
  property bool open: false
  default property alias more: extra.data

  readonly property bool expandable: question !== "" || answer !== "" || extra.children.length > 0

  implicitHeight: head.height + (open ? details.height + 4 : 0) + 2

  Item {
    id: head
    width: Math.min(row.width, line.implicitWidth + 18)
    height: 22
    Row {
      id: line
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6
      Icon { anchors.verticalCenter: parent.verticalCenter; name: "people"; size: 11; color: Theme.dim }
      Label { anchors.verticalCenter: parent.verticalCenter; text: "TEAM"; color: Theme.dim; font.pixelSize: 11; font.letterSpacing: 1.5 }
      Label {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, row.width - 120)
        text: row.summary
        color: pointer.containsMouse ? Theme.foreground : Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
      Label { anchors.verticalCenter: parent.verticalCenter; text: row.stamp; color: Theme.dim; font.pixelSize: 11 }
      Icon { visible: row.expandable; anchors.verticalCenter: parent.verticalCenter; name: row.open ? "chevron-down" : "chevron-right"; size: 10; color: Theme.dim }
    }
    MouseArea {
      id: pointer
      anchors.fill: parent
      enabled: row.expandable
      hoverEnabled: true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: row.open = !row.open
    }
  }

  Column {
    id: details
    visible: row.open
    y: head.height + 4
    x: 17
    width: Math.min(620, row.width - 17)
    spacing: 6
    Prose {
      visible: row.question !== ""
      width: parent.width
      source: Omunculus.inline(row.question)
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
    Prose {
      visible: row.answer !== ""
      width: parent.width
      source: Omunculus.inline(row.answer)
      color: Theme.foreground
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
    Item {
      id: extra
      width: parent.width
      height: childrenRect.height
    }
  }
}
