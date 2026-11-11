pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/ui"

// ReviewList is the Pending folder: the reviews waiting on you, newest first,
// each a row with who acted, the time and what it would do. Empty,
// it says so.
Item {
  id: list

  // Puts the keyboard on the reviews.
  function enter() {
    view.forceActiveFocus()
    if (view.currentIndex < 0 && view.count > 0)
      view.currentIndex = 0
  }

  ListView {
    id: view
    anchors.fill: parent
    clip: true
    model: Mail.shownReviews
    spacing: 2
    boundsBehavior: Flickable.StopAtBounds
    keyNavigationEnabled: true
    currentIndex: -1
    highlightFollowsCurrentItem: false
    C.ScrollBar.vertical: C.ScrollBar {}

    delegate: Rectangle {
      id: row

      required property var modelData
      required property int index
      readonly property bool current: Mail.selectedReview === modelData.key

      width: view.width
      implicitHeight: lines.implicitHeight + 16
      color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
      border.color: current ? Theme.primary : Theme.line
      Behavior on color { ColorAnimation { duration: 120 } }
      Behavior on border.color { ColorAnimation { duration: 120 } }

      ColumnLayout {
        id: lines
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 14; topMargin: 8 }
        spacing: 3

        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Icon { name: "spark"; size: 11; color: Theme.primary }
          Label {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: row.modelData.from.name
            font.pixelSize: 12
            font.bold: true
            elide: Text.ElideRight
          }
          Label { text: Mail.when(row.modelData.at); color: Theme.primary; font.pixelSize: 10 }
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: row.modelData.summary
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { view.currentIndex = row.index; Mail.openReview(row.modelData.key) }
      }
    }

    Keys.onReturnPressed: if (currentIndex >= 0) Mail.openReview(Mail.shownReviews[currentIndex].key)
    onCurrentIndexChanged: if (activeFocus && currentIndex >= 0) Mail.openReview(Mail.shownReviews[currentIndex].key)
  }

  Label {
    anchors.centerIn: parent
    width: parent.width - 32
    visible: view.count === 0
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    text: !Mail.connected ? "THE SERVER DOES NOT ANSWER"
      : !Mail.primed ? "READING YOUR MAIL"
      : Mail.query !== "" ? "NO REVIEW MATCHES “" + Mail.query.toUpperCase() + "”"
      : "NOTHING WAITS FOR YOUR REVIEW"
    color: Theme.dim
    font.pixelSize: 11
    font.letterSpacing: 2
  }
}
