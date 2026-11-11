import QtQuick
import QtQuick.Layouts
import "kit/ui"

// StartCard is a way in on the start screen: its name in tracked capitals,
// under it one line saying what is there, at the right the key that opens it
// and a chevron. The first is `primary`, filled in the accent: the one filled
// action of the screen.
Rectangle {
  id: card

  property string title
  property string detail
  // The key that opens it, as the screen shows it.
  property string key
  property bool primary: false

  signal clicked()

  readonly property color ink: primary ? Theme.readable(Theme.background, Theme.primary, Theme.foreground) : Theme.foreground
  readonly property color quiet: primary ? ink : Theme.dim

  function press() {
    if (enabled)
      clicked()
  }

  implicitHeight: body.implicitHeight + Theme.space.inset * 2
  color: primary ? Theme.primary : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.06) : "transparent"
  border.color: primary ? Theme.primary : pointer.containsMouse ? Theme.primary : Theme.line
  opacity: enabled ? 1 : 0.35
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: title + ", " + detail
  Keys.onReturnPressed: press()
  Keys.onSpacePressed: press()

  Behavior on color { ColorAnimation { duration: 150 } }
  Behavior on border.color { ColorAnimation { duration: 150 } }

  RowLayout {
    id: body
    anchors { fill: parent; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
    spacing: Theme.space.gap

    ColumnLayout {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      spacing: Theme.space.line
      Label {
        Layout.fillWidth: true
        text: card.title
        color: card.ink
        font.pixelSize: Theme.type.body.size
        font.bold: true
        font.letterSpacing: 3
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        text: card.detail
        color: card.quiet
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }
    ColumnLayout {
      Layout.alignment: Qt.AlignVCenter
      spacing: Theme.space.line
      Label {
        Layout.alignment: Qt.AlignRight
        text: card.key
        color: card.quiet
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
      }
      Icon { Layout.alignment: Qt.AlignRight; name: "chevron-right"; size: 14; color: card.ink }
    }
  }

  FocusRing { shown: card.activeFocus }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: card.press()
  }
}
