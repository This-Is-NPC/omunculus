pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// TeamNote is a note a work's agent left on its work, where it was left: its
// agent named in its tone, "noted", and the text in a line or two, dim. It is
// the team's news, not a message to you: only the front agent talks to the
// client. A long note unfolds by choosing its line, or is unfolded by the
// thread, once the work is done. Its text is Prose: an address in it is a link.
Item {
  id: note

  required property string who
  required property string text
  property string stamp

  // Unfolded by the thread; `chosen` flips it, the person's own fold.
  property bool unfolded: false
  property bool chosen: false
  readonly property bool open: unfolded !== chosen
  readonly property bool long: words.truncated || open && words.lineCount > 2

  implicitHeight: content.implicitHeight + Theme.space.row

  ColumnLayout {
    id: content
    width: note.width
    spacing: Theme.space.line

    Item {
      Layout.fillWidth: true
      implicitHeight: Theme.size.stackedRow
      activeFocusOnTab: note.long
      Accessible.role: Accessible.Button
      Accessible.name: note.who + " noted: " + note.text
      Keys.onPressed: event => {
        if (note.long && [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
          note.chosen = !note.chosen
          event.accepted = true
        }
      }

      RowLayout {
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: Theme.space.tight
        Icon { name: "edit"; size: 11; color: Theme.dim }
        Label { text: note.who; color: Omunculus.toneOf(note.who); font.pixelSize: 11 }
        Label { Layout.fillWidth: true; text: "noted"; color: Theme.dim; font.pixelSize: 11 }
        Label { text: note.stamp; color: Theme.faint; font.pixelSize: Theme.type.stamp.size; font.letterSpacing: Theme.type.stamp.tracking }
        Icon { visible: note.long; name: note.open ? "chevron-down" : "chevron-right"; size: 10; color: Theme.dim }
      }
      MouseArea {
        anchors.fill: parent
        enabled: note.long
        cursorShape: note.long ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: note.chosen = !note.chosen
      }
      FocusRing { anchors.margins: -2 }
    }

    Prose {
      id: words
      Layout.fillWidth: true
      Layout.leftMargin: Theme.space.block + Theme.space.line
      Layout.maximumWidth: 620
      source: Omunculus.inline(note.text)
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
      maximumLineCount: note.open ? 1000 : 2
      elide: Text.ElideRight
    }
  }
}
