import QtQuick
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ThreadRail is the folder's list while its column is folded: only how many
// e-mails it holds, in a square the width of the rail, and, in the accent on
// its corner, how many of them are unread. A click opens the list again.
Item {
  id: rail

  readonly property var count: Mailbox.railCount(Mail.shown, Mail.seen)

  signal unfold()

  Rectangle {
    id: tab
    width: rail.width
    height: width
    color: pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
    border.color: pointer.containsMouse ? Theme.dim : Theme.line
    Accessible.role: Accessible.StaticText
    Accessible.name: rail.count.total + " e-mails, " + rail.count.unread + " unread"

    Label {
      anchors.centerIn: parent
      text: rail.count.total
      color: Theme.foreground
      font.pixelSize: 13
      font.bold: true
    }
    Rectangle {
      visible: rail.count.unread > 0
      anchors { right: parent.right; top: parent.top; margins: -5 }
      width: Math.max(height, tally.implicitWidth + 6)
      height: 14
      color: Theme.primary
      Label {
        id: tally
        anchors.centerIn: parent
        text: rail.count.unread
        color: Theme.badgeForeground
        font.pixelSize: 9
        font.bold: true
      }
    }
    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rail.unfold()
    }
    Hint { active: pointer.containsMouse; text: rail.count.total + (rail.count.total === 1 ? " e-mail" : " e-mails") + ", " + rail.count.unread + " unread" }
  }
}
