pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/client/Jobs.js" as Jobs
import "kit/ui"

// ReviewView reads one review as a card, bordered in the warning tone, or a job
// an agent proposes (`review.kind` "job"), which it tells by the schedule in
// words, the next fires and the estimate instead of a level and a held text, and
// whose EDIT sends back what to change: who
// acted with its level (depth marks, "level 3, under project-manager"), what it wants to do and the text it holds, then APPROVE (the one
// filled action), EDIT and DENY. DETAILS shows the arguments as lines and what
// each answer does. While an answer is on its way the buttons are off and SENDING shows. EDIT and DENY open the reply box under it, as a reply is written: EDIT
// holds the text to rewrite and sends `edit` with the new words; DENY takes an
// optional reason and sends `deny`.
Item {
  id: view

  required property var review
  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  // Whether the action's arguments show under the card's buttons.
  property bool details: false
  // "edit" or "deny" while the reply box is open, else "".
  property string mode: ""
  // Whether Esc is the review's: it closes the reply box, or else the review.
  property bool escapes: true

  readonly property bool proposal: review.kind === "job"
  readonly property bool writing: mode !== ""
  readonly property bool sending: Mail.answering[review.key] !== undefined

  function start(option) {
    mode = option
    Qt.callLater(() => {
      if (option === "edit" && editor.text === "")
        editor.text = view.review.text
      editor.focusEntry()
    })
  }

  function send() {
    const words = editor.take()
    if (mode === "edit" && words === "")
      return
    Mail.decide(review, mode, words)
    mode = ""
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 14

    RowLayout {
      Layout.fillWidth: true
      spacing: 6
      IconButton { visible: view.back; name: "chevron-left"; tip: "back to the list  esc"; onClicked: Mail.close() }
      Item { Layout.fillWidth: true }
      IconButton { name: "chevron-up"; tip: "previous review  alt+↑"; onClicked: Mail.stepReview(-1) }
      IconButton { name: "chevron-down"; tip: "next review  alt+↓"; onClicked: Mail.stepReview(1) }
      IconButton { visible: !view.back; name: "close"; tip: "close the review  esc"; onClicked: Mail.close() }
    }

    ScrollPage {
      id: scroll
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentWidth: width
      contentHeight: stack.implicitHeight
      C.ScrollBar.vertical: C.ScrollBar {}

      ColumnLayout {
        id: stack
        width: scroll.width
        spacing: 14

        // The review as a card, bordered in the warning tone while it waits for you.
        Rectangle {
          id: card
          Layout.alignment: Qt.AlignHCenter
          Layout.preferredWidth: Math.min(560, stack.width)
          Layout.preferredHeight: body.implicitHeight + 40
          color: Theme.highlight
          border.color: Theme.warning

          ColumnLayout {
            id: body
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
            spacing: 12

            RowLayout {
              Layout.fillWidth: true
              spacing: 6
              Icon { name: view.proposal ? "clock" : "search"; size: 12; color: Theme.primary }
              Label { text: view.proposal ? "JOB PROPOSAL" : "REVIEW"; color: Theme.primary; font.pixelSize: 10; font.letterSpacing: 3 }
              Item { Layout.fillWidth: true }
              Icon { name: "warning"; size: 12; color: Theme.warning }
              Label { text: "WAITING FOR YOU"; color: Theme.warning; font.pixelSize: 10; font.letterSpacing: 3 }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 8
              Portrait {
                visible: view.review.from.agent !== ""
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                agent: view.review.from.agent || "?"
                source: Mail.imageOf(view.review.project, view.review.from.agent)
                tone: Mail.toneOf(view.review.project, view.review.from.agent)
              }
              Label { text: view.review.from.name; font.pixelSize: 12; font.bold: true }
              Label {
                Layout.fillWidth: true
                text: view.review.from.address !== "" ? "<" + view.review.from.address + ">" : ""
                color: Theme.dim
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Label { text: Mail.stamp(view.review.at); color: Theme.dim; font.pixelSize: 10 }
            }

            RowLayout {
              Layout.fillWidth: true
              visible: !view.proposal
              spacing: 6
              Row {
                spacing: 3
                Repeater {
                  model: view.review.level + 1
                  delegate: Rectangle {
                    required property int index
                    width: 6
                    height: 6
                    radius: 3
                    color: index === view.review.level ? Theme.primary : Theme.dim
                  }
                }
              }
              Label {
                Layout.fillWidth: true
                text: "level " + view.review.level + (view.review.under ? ", under " + view.review.under.agent : "")
                color: Theme.dim
                font.pixelSize: 10
                elide: Text.ElideRight
              }
            }

            Label {
              Layout.fillWidth: true
              text: view.review.summary
              font.pixelSize: 15
              font.bold: true
              wrapMode: Text.Wrap
            }

            ColumnLayout {
              Layout.fillWidth: true
              visible: view.proposal
              spacing: 10
              Prose {
                Layout.fillWidth: true
                visible: view.proposal && view.review.job.why !== ""
                source: view.proposal ? view.review.job.why : ""
                color: Theme.foreground
                font.pixelSize: 13
                lineHeight: 1.25
                wrapMode: Text.Wrap
              }
              Repeater {
                model: view.proposal ? [
                  { name: "SCHEDULE", value: Jobs.when(view.review.job.schedule) + "  ·  " + view.review.job.timezone },
                  { name: "NEXT FIRES", value: Mail.nextFires(view.review) },
                  { name: "ESTIMATE", value: Mail.estimate(view.review) }
                ] : []
                delegate: ColumnLayout {
                  id: fact
                  required property var modelData
                  Layout.fillWidth: true
                  spacing: 2
                  Label { text: fact.modelData.name; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 2 }
                  Label { Layout.fillWidth: true; text: fact.modelData.value; font.pixelSize: 13; wrapMode: Text.Wrap }
                }
              }
            }

            Flow {
              Layout.fillWidth: true
              visible: view.review.files.length > 0
              spacing: 8
              Repeater {
                model: view.review.files
                delegate: FileChip {
                  required property var modelData
                  file: modelData
                  enabled: false
                }
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              visible: view.review.text !== ""
              spacing: 4
              Label { text: "HELD TEXT"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 2 }
              Prose {
                Layout.fillWidth: true
                plain: true
                source: view.review.text
                color: Theme.foreground
                font.pixelSize: 13
                lineHeight: 1.25
                wrapMode: Text.Wrap
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              visible: view.details
              spacing: 10
              Repeater {
                model: view.review.args
                delegate: ColumnLayout {
                  id: line
                  required property var modelData
                  Layout.fillWidth: true
                  spacing: 2
                  Label { text: line.modelData.name.toUpperCase(); color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 2 }
                  Prose {
                    Layout.fillWidth: true
                    source: line.modelData.value
                    color: Theme.foreground
                    font.pixelSize: 13
                    lineHeight: 1.25
                    wrapMode: Text.Wrap
                  }
                }
              }
              Label {
                Layout.fillWidth: true
                text: view.review.outcome
                color: Theme.dim
                font.pixelSize: 11
                wrapMode: Text.Wrap
              }
            }

            Flow {
              Layout.fillWidth: true
              spacing: 8
              TraceButton {
                dense: true
                role: "primary"
                enabled: !view.sending
                filled: !view.writing
                text: "APPROVE"
                tip: "let the action go ahead as it is"
                onClicked: Mail.decide(view.review, "approve", "")
              }
              TraceButton {
                dense: true
                role: "action"
                enabled: !view.sending
                text: "EDIT"
                tip: view.proposal ? "say what to change; nothing is created yet" : "rewrite the text, then send it in place of the held one"
                onClicked: view.start("edit")
              }
              TraceButton {
                dense: true
                role: "action"
                enabled: !view.sending
                text: "DENY"
                tip: view.proposal ? "drop the proposal, with a reason if you like" : "refuse the action, with a reason if you like"
                onClicked: view.start("deny")
              }
              Row {
                visible: view.sending
                height: Theme.size.control
                spacing: 6
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "send"; size: 12; color: Theme.primary }
                Label { anchors.verticalCenter: parent.verticalCenter; text: "SENDING…"; color: Theme.primary; font.pixelSize: 11; font.letterSpacing: 2 }
              }
              Chip {
                icon: view.details ? "chevron-up" : "chevron-down"
                text: "DETAILS"
                tip: view.proposal ? "the job's fields and what each answer does" : "the action's arguments and what each answer does"
                onClicked: view.details = !view.details
              }
            }
          }
        }

        SurfaceFrame {
          Layout.fillWidth: true
          visible: view.writing
          Layout.preferredHeight: writing.implicitHeight + 28
          variant: "outline"
          active: true

          ColumnLayout {
            id: writing
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 10

            Label {
              Layout.fillWidth: true
              text: view.mode === "edit"
                ? (view.proposal ? "Edit: say what to change; nothing is created" : "Edit: the words go ahead in place of the held text")
                : "Deny: the reason is optional"
              color: Theme.dim
              font.pixelSize: 11
              wrapMode: Text.Wrap
            }
            Editor {
              id: editor
              Layout.fillWidth: true
              placeholderText: view.mode === "edit" ? (view.proposal ? "what to change" : "the edited text") : "why it is denied"
              onSubmitted: view.send()
            }
            MailFooter {
              attachable: false
              sendable: view.mode === "deny" || editor.text.trim() !== ""
              onDiscarded: view.mode = ""
              onSent: view.send()
            }
          }
        }
      }
    }
  }

  Shortcut {
    sequence: "Escape"
    enabled: view.escapes
    onActivated: view.writing ? view.mode = "" : Mail.close()
  }
}
