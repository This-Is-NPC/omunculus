import QtQuick
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// MailLabel is the one status a thread shows, as a mail label: a small
// outlined pill with a still icon and a word, "In progress", "Stuck" or
// "Cancelled", or JOB beside a job's message. A thread without one says nothing.
Rectangle {
  id: tag

  // "progress", "stuck", "cancelled", "job" or "".
  property string kind
  readonly property color tone: kind === "progress" ? Theme.primary : kind === "stuck" ? Theme.error : Theme.dim

  visible: kind !== ""
  implicitWidth: content.implicitWidth + 14
  implicitHeight: 20
  color: Qt.alpha(tone, 0.08)
  border.color: Qt.alpha(tone, 0.6)

  Row {
    id: content
    anchors.centerIn: parent
    spacing: 5
    Icon {
      anchors.verticalCenter: parent.verticalCenter
      name: tag.kind === "progress" ? "spark" : tag.kind === "stuck" ? "warning" : tag.kind === "job" ? "clock" : "close"
      size: 10
      color: tag.tone
    }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      text: Mailbox.labels[tag.kind] || ""
      color: tag.tone
      font.pixelSize: 10
      font.letterSpacing: 0.5
    }
  }
}
