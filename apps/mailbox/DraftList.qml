pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic as C
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// DraftList is the Drafts folder: what was left unsent, newest first. A draft
// opens in the compose window; its x discards it.
Item {
  id: list

  ListView {
    anchors.fill: parent
    clip: true
    spacing: 2
    model: Mail.shownDrafts
    boundsBehavior: Flickable.StopAtBounds
    C.ScrollBar.vertical: C.ScrollBar {}

    delegate: Rectangle {
      id: item
      required property var modelData
      width: ListView.view.width
      height: 54
      color: pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
      border.color: Theme.line

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Mail.compose({ draft: item.modelData })
      }
      Column {
        anchors { left: parent.left; right: discard.left; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 8 }
        spacing: 3
        Label {
          width: parent.width
          text: "To: " + (item.modelData.agent !== "" ? Mailbox.person(item.modelData.agent, item.modelData.project).name : "(no recipient)")
            + "  ·  " + (item.modelData.subject || "(no subject)")
          font.pixelSize: 12
          elide: Text.ElideRight
        }
        Label {
          width: parent.width
          text: Mailbox.oneLine(item.modelData.body)
          color: Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
      }
      IconButton {
        id: discard
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        name: "close"
        tip: "discard the draft"
        onClicked: Mail.discardDraft(item.modelData.id)
      }
    }
  }

  Label {
    anchors.centerIn: parent
    visible: Mail.shownDrafts.length === 0
    text: "NO DRAFTS"
    color: Theme.dim
    font.pixelSize: 11
    font.letterSpacing: 2
  }
}
