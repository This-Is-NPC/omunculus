import QtQuick
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// MailLabel is the one status a thread shows, as a mail label: an icon and a
// word, "In progress" (a trace that runs), "Stuck" or "Cancelled". A thread
// without one says nothing.
Row {
  id: tag

  // "progress", "stuck", "cancelled" or "".
  property string kind
  readonly property color tone: kind === "progress" ? Theme.primary : kind === "stuck" ? Theme.error : Theme.dim

  visible: kind !== ""
  spacing: 6

  LoadingTrace {
    anchors.verticalCenter: parent.verticalCenter
    visible: tag.kind === "progress"
    width: 36
    height: 10
    running: visible
  }
  Icon {
    anchors.verticalCenter: parent.verticalCenter
    visible: tag.kind !== "progress"
    name: tag.kind === "stuck" ? "warning" : "close"
    size: 11
    color: tag.tone
  }
  Label {
    anchors.verticalCenter: parent.verticalCenter
    text: Mailbox.labels[tag.kind] || ""
    color: tag.tone
    font.pixelSize: 10
    font.letterSpacing: 1
  }
}
