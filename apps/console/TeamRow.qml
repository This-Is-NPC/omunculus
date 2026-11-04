pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// TeamRow is an exchange between agents, where it was asked: who asked whom
// and who decides, the question in its first three lines, and once answered
// who answered and what. It is open while it waits, and then DECIDE INSTEAD
// opens the request's card in place, so you can answer it yourself, and its
// close folds it back; choosing its line folds and unfolds the rest of the
// question and the answer.
Item {
  id: row

  // The request.
  required property string key
  property string stamp

  readonly property var asked: Omunculus.requests.find(item => item.id === key) || null
  readonly property var reply: Omunculus.replies[key] || null
  readonly property bool pending: !!asked && Requests.pending(asked)
  readonly property string by: asked ? Requests.label(asked.requester) : ""
  readonly property string to: asked ? Requests.label(asked.arbiter) : ""
  readonly property bool forYou: !!asked && Requests.human(asked.arbiter)
  readonly property string question: asked ? String(asked.reason || "") : ""
  readonly property string answer: reply ? String(reply.body || reply.option || "") : ""
  readonly property string summary: reply && reply.who !== "you" && forYou ? reply.who + " answered this for you"
    : by + " asked " + to + (pending ? "  ·  " + to + " decides" : asked && asked.status === "escalated" ? "  ·  passed up" : "")
  property bool open: pending
  property bool deciding: false

  implicitHeight: content.implicitHeight + Theme.space.row

  ColumnLayout {
    id: content
    width: row.width
    spacing: Theme.space.line

    Item {
      Layout.fillWidth: true
      implicitHeight: Theme.size.stackedRow
      activeFocusOnTab: true
      Accessible.role: Accessible.Button
      Accessible.name: row.summary
      Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
          row.open = !row.open
          event.accepted = true
        }
      }

      RowLayout {
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: Theme.space.tight
        Icon { name: "people"; size: 11; color: Theme.dim }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: row.summary
          color: pointer.containsMouse ? Theme.foreground : Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        Label { text: row.stamp; color: Theme.faint; font.pixelSize: Theme.type.stamp.size; font.letterSpacing: Theme.type.stamp.tracking }
        Icon { name: row.open ? "chevron-down" : "chevron-right"; size: 10; color: Theme.dim }
      }
      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.open = !row.open
      }
      FocusRing { anchors.margins: -2 }
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.leftMargin: Theme.space.block + Theme.space.line
      Layout.maximumWidth: 620
      spacing: Theme.space.tight

      // Folded, the first three lines of the question; open, all of it.
      Label {
        Layout.fillWidth: true
        visible: !row.open && row.question !== ""
        text: Omunculus.inline(row.question)
        color: Theme.dim
        font.pixelSize: 11
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
      Prose {
        Layout.fillWidth: true
        visible: row.open && row.question !== ""
        source: Omunculus.inline(row.question)
        color: Theme.dim
        font.pixelSize: 11
        wrapMode: Text.Wrap
      }

      Label {
        Layout.fillWidth: true
        visible: row.open && row.reply !== null
        text: "answered by " + (row.reply ? row.reply.who : "") + ":"
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
      Prose {
        Layout.fillWidth: true
        visible: row.open && row.answer !== ""
        source: Omunculus.inline(row.answer)
        color: Theme.foreground
        font.pixelSize: 11
        wrapMode: Text.Wrap
      }

      TraceButton {
        visible: row.open && row.pending && !row.deciding
        dense: true
        role: "progress"
        text: "DECIDE INSTEAD"
        tip: "answer it yourself, in place of " + row.to
        onClicked: row.deciding = true
      }
    }

    // The request's own card, to answer it in place of the agent that decides.
    Loader {
      Layout.fillWidth: true
      active: row.open && row.pending && row.deciding
      visible: active
      sourceComponent: RequestDecision {
        key: row.key
        stamp: row.stamp
        closable: true
        onClosed: row.deciding = false
      }
    }
  }
}
