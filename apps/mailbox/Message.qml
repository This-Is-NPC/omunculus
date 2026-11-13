pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints

// Message is one e-mail of a thread, as a mail client stacks them: folded, a
// line with who wrote, the start of the text and the time; open, its header
// (from, to, date), its text, the files it carries, each a chip that saves
// the file to the downloads directory and opens it, and Reply, Forward and,
// only when the thread has several counterparts, Reply all. A message a job delivers has the JOB badge beside its sender and a link that opens the job in the console. The latest message's Reply is the screen's solid action unless that message is your own.
SurfaceFrame {
  id: mail

  required property var message
  required property string thread
  required property string project
  property bool expanded: true
  // Whether it is the thread's latest message.
  property bool latest: false
  // Whether the thread has more than one counterpart, so Reply all differs from Reply.
  property bool several: false


  readonly property bool agent: !message.mine
  // The latest message is the one the screen's solid action answers, unless it
  // is your own.
  readonly property bool answerable: latest && !message.mine

  signal toggled()
  signal replyTo(bool all)
  signal forwardIt()

  implicitHeight: body.implicitHeight + (expanded ? 28 : 20)
  variant: "outline"
  clip: true
  Behavior on implicitHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  ColumnLayout {
    id: body
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14; topMargin: mail.expanded ? 14 : 10 }
    spacing: 10

    Item {
      Layout.fillWidth: true
      implicitHeight: Math.max(head.implicitHeight, Breakpoints.target(Window.width))
      MouseArea {
        anchors.fill: parent
        anchors.margins: -6
        cursorShape: Qt.PointingHandCursor
        onClicked: mail.toggled()
      }
      RowLayout {
        id: head
        anchors { left: parent.left; right: parent.right }
        spacing: 8
        Portrait {
          visible: mail.agent && !mail.message.from.job
          Layout.preferredWidth: 20
          Layout.preferredHeight: 20
          agent: mail.message.from.agent || "?"
          source: Mail.imageOf(mail.project, mail.message.from.agent || "")
          tone: Mail.toneOf(mail.project, mail.message.from.agent || "")
        }
        Label {
          text: mail.message.from.name
          color: mail.agent ? Theme.foreground : Theme.dim
          font.pixelSize: 12
          font.bold: true
        }
        MailLabel { visible: !!mail.message.from.job; kind: "job" }
        Label {
          visible: mail.expanded
          Layout.fillWidth: true
          text: (mail.message.from.address !== "" ? "<" + mail.message.from.address + ">  " : "") + "to " + (mail.message.to.me ? "me" : mail.message.to.name)
          color: Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        Label {
          Layout.fillWidth: true
          visible: !mail.expanded
          text: mail.message.text.replace(/\s+/g, " ") + (mail.message.files.length > 0 ? "  [" + mail.message.files.length + (mail.message.files.length === 1 ? " file]" : " files]") : "")
          color: Theme.dim
          font.pixelSize: 12
          elide: Text.ElideRight
        }
        LoadingTrace {
          visible: mail.message.open
          Layout.preferredWidth: 36
          Layout.preferredHeight: 10
          running: visible
        }
        // The full date gives the address its room on a narrow window.
        Label {
          text: mail.expanded && Breakpoints.size(Window.width) !== "narrow" ? Mail.stamp(mail.message.at) : Mail.when(mail.message.at)
          color: Theme.dim
          font.pixelSize: 10
        }
      }
    }

    Prose {
      Layout.fillWidth: true
      visible: mail.expanded && mail.message.text !== ""
      plain: mail.message.mine
      source: mail.message.text
      color: Theme.foreground
      font.pixelSize: 13
      lineHeight: 1.25
      wrapMode: Text.Wrap
    }

    LinkLabel {
      visible: mail.expanded && !!mail.message.job
      Layout.minimumHeight: Breakpoints.target(Window.width)
      value: "VIEW JOB IN THE CONSOLE"
      onClicked: Mail.openJob(mail.thread)
    }

    Flow {
      Layout.fillWidth: true
      visible: mail.expanded && mail.message.files.length > 0
      spacing: 6
      Repeater {
        model: mail.message.files
        delegate: FileChip {
          required property var modelData
          file: modelData
          onClicked: Mail.openAttachment(mail.thread, modelData)
        }
      }
    }

    Flow {
      Layout.fillWidth: true
      visible: mail.expanded
      spacing: 8
      TraceButton {
        dense: true
        role: mail.answerable ? "primary" : "action"
        filled: mail.answerable
        icon: "enter"
        text: "REPLY"
        tip: "reply  ctrl+r"
        onClicked: mail.replyTo(false)
      }
      TraceButton {
        visible: mail.several
        dense: true
        role: "action"
        text: "REPLY ALL"
        tip: "reply to everyone on the thread"
        onClicked: mail.replyTo(true)
      }
      TraceButton {
        dense: true
        role: "action"
        text: "FORWARD"
        tip: "start a new message with this one"
        onClicked: mail.forwardIt()
      }
    }
  }
}
