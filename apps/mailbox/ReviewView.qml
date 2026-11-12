pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/ui"

// ReviewView reads one review as a message: its subject is what the actor
// wants to do, its body the arguments as lines, the text it holds and what
// each answer does, then APPROVE (the one filled action), EDIT and DENY.
// While an answer is on its way the buttons are off and SENDING shows. EDIT and DENY open the reply box under it, as a reply is written: EDIT
// holds the text to rewrite and sends `edit` with the new words; DENY takes an
// optional reason and sends `deny`.
Item {
  id: view

  required property var review
  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  // "edit" or "deny" while the reply box is open, else "".
  property string mode: ""
  // Whether Esc is the review's: it closes the reply box, or else the review.
  property bool escapes: true

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
      spacing: 10
      IconButton { visible: view.back; name: "chevron-left"; tip: "back to the list  esc"; onClicked: Mail.close() }
      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: 6
        Label {
          Layout.fillWidth: true
          text: view.review.summary
          font.pixelSize: 16
          font.bold: true
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
        Row {
          spacing: 6
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "spark"; size: 11; color: Theme.primary }
          Label {
            anchors.verticalCenter: parent.verticalCenter
            text: "REVIEW"
            color: Theme.primary
            font.pixelSize: 10
            font.letterSpacing: 1
          }
        }
      }
      Row {
        Layout.alignment: Qt.AlignTop
        spacing: 6
        IconButton { name: "chevron-up"; tip: "previous review  alt+↑"; onClicked: Mail.stepReview(-1) }
        IconButton { name: "chevron-down"; tip: "next review  alt+↓"; onClicked: Mail.stepReview(1) }
        IconButton { visible: !view.back; name: "close"; tip: "close the review  esc"; onClicked: Mail.close() }
      }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

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

        SurfaceFrame {
          id: card
          Layout.fillWidth: true
          Layout.preferredHeight: body.implicitHeight + 28
          variant: "outline"

          ColumnLayout {
            id: body
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 10

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
                text: (view.review.from.address !== "" ? "<" + view.review.from.address + ">  " : "") + "acted, for your review"
                color: Theme.dim
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Label { text: Mail.stamp(view.review.at); color: Theme.dim; font.pixelSize: 10 }
            }

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

            Label {
              Layout.fillWidth: true
              text: view.review.outcome
              color: Theme.dim
              font.pixelSize: 11
              wrapMode: Text.Wrap
            }

            Flow {
              Layout.fillWidth: true
              spacing: 8
              TraceButton {
                dense: true
                role: "primary"
                enabled: !view.sending
                filled: !view.writing
                icon: "check"
                text: "APPROVE"
                tip: "let the action go ahead as it is"
                onClicked: Mail.decide(view.review, "approve", "")
              }
              TraceButton {
                dense: true
                role: "action"
                enabled: !view.sending
                icon: "edit"
                text: "EDIT"
                tip: "rewrite the text, then send it in place of the held one"
                onClicked: view.start("edit")
              }
              TraceButton {
                dense: true
                role: "action"
                enabled: !view.sending
                icon: "close"
                text: "DENY"
                tip: "refuse the action, with a reason if you like"
                onClicked: view.start("deny")
              }
              Row {
                visible: view.sending
                height: Theme.size.control
                spacing: 6
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "send"; size: 12; color: Theme.primary }
                Label { anchors.verticalCenter: parent.verticalCenter; text: "SENDING…"; color: Theme.primary; font.pixelSize: 11; font.letterSpacing: 2 }
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
              text: view.mode === "edit" ? "Edit: the words go ahead in place of the held text" : "Deny: the reason is optional"
              color: Theme.dim
              font.pixelSize: 11
              wrapMode: Text.Wrap
            }
            Editor {
              id: editor
              Layout.fillWidth: true
              placeholderText: view.mode === "edit" ? "the edited text" : "why it is denied"
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
