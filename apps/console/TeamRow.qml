pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// TeamRow is an exchange between agents, where it was asked: a system row of
// who asked whom and who decides, each agent named in its tone, the people
// mark in the rows' mark column; under it, quoted in an outlined frame, the
// question in its first three lines, and once answered who answered and what. It is open while it waits (in the chat it stays folded, as history), and then DECIDE INSTEAD
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
  readonly property bool forYou: !!asked && Requests.forYou(asked, Omunculus.me)
  readonly property string question: asked ? String(asked.reason || "") : ""
  readonly property string answer: reply ? String(reply.body || reply.option || "") : ""
  // The summary line as its parts, each {text, agent} with the agent it names.
  readonly property var parts: reply && reply.who !== "you" && forYou ? [{ text: reply.who, agent: reply.who }, { text: " answered this for you" }]
    : [{ text: by, agent: by }, { text: " asked " }, { text: to, agent: to }]
      .concat(pending ? [{ text: "  ·  " }, { text: to, agent: to }, { text: " decides" }] : asked && asked.status === "escalated" ? [{ text: "  ·  passed up" }] : [])
  readonly property string summary: parts.map(part => part.text).join("")
  // Whether it offers to be decided in your place.
  property bool decidable: true
  property bool open: pending && decidable
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
        Item {
          Layout.preferredWidth: Theme.size.mark - Theme.space.tight
          Layout.preferredHeight: Theme.type.log.size
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "people"; size: Theme.type.log.size; color: Theme.dim }
        }
        // Each agent named in its tone, the words between them dim.
        RowLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          spacing: 0
          Repeater {
            model: row.parts
            delegate: Label {
              required property var modelData
              required property int index
              Layout.fillWidth: index === row.parts.length - 1
              Layout.minimumWidth: 0
              text: modelData.text
              color: modelData.agent ? Omunculus.toneOf(modelData.agent) : pointer.containsMouse ? Theme.foreground : Theme.dim
              font.pixelSize: Theme.type.log.size
              elide: Text.ElideRight
            }
          }
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

    SurfaceFrame {
      Layout.fillWidth: true
      Layout.leftMargin: Theme.size.mark
      Layout.maximumWidth: 620
      visible: row.question !== "" || (row.open && row.reply !== null)
      implicitHeight: quoted.implicitHeight + Theme.space.insetTop + Theme.space.inset
      variant: "outline"

      ColumnLayout {
        id: quoted
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
        spacing: Theme.space.tight

        // Folded, the first three lines of the question; open, all of it.
        Label {
          Layout.fillWidth: true
          visible: !row.open && row.question !== ""
          text: Omunculus.inline(row.question)
          color: Theme.foreground
          font.pixelSize: Theme.type.body.size
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
        Prose {
          Layout.fillWidth: true
          visible: row.open && row.question !== ""
          source: Omunculus.inline(row.question)
          color: Theme.foreground
          font.pixelSize: Theme.type.body.size
          wrapMode: Text.Wrap
        }

        Label {
          Layout.fillWidth: true
          visible: row.open && row.reply !== null
          text: "answered by " + (row.reply ? row.reply.who : "") + ":"
          color: Theme.dim
          font.pixelSize: Theme.type.log.size
          elide: Text.ElideRight
        }
        Prose {
          Layout.fillWidth: true
          visible: row.open && row.answer !== ""
          source: Omunculus.inline(row.answer)
          color: Theme.foreground
          font.pixelSize: Theme.type.body.size
          wrapMode: Text.Wrap
        }

        TraceButton {
          visible: row.decidable && row.open && row.pending && !row.deciding
          dense: true
          role: "progress"
          text: "DECIDE INSTEAD"
          tip: "answer it yourself, in place of " + row.to
          onClicked: row.deciding = true
        }
      }
    }

    // The request's own card, to answer it in place of the agent that decides.
    Loader {
      Layout.fillWidth: true
      active: row.decidable && row.open && row.pending && row.deciding
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
