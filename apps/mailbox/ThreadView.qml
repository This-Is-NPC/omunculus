pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/ui"

// ThreadView reads one thread like a mail thread: its subject, its agent and
// project, then its messages, the last ones open and the earlier ones folded
// to a line each; a long thread hides its middle behind one fold. Below,
// your reply to its agent.
ColumnLayout {
  id: view

  required property var thread
  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  // Entry key -> whether you opened (true) or folded (false) it.
  property var toggled: ({})
  property bool showAll: false

  readonly property var entries: thread.entries
  // Long threads show their first message, a fold, and their last four.
  readonly property int hidden: showAll || entries.length <= 6 ? 0 : entries.length - 5
  readonly property var visibleEntries: hidden === 0 ? entries : [entries[0]].concat(entries.slice(entries.length - 4))

  spacing: 14

  function isOpen(entry) {
    if (entry.kind === "request" && entry.open)
      return true
    if (toggled[entry.key] !== undefined)
      return toggled[entry.key]
    return entries.findIndex(other => other.key === entry.key) >= entries.length - 2
  }

  function toggle(entry) {
    toggled = Object.assign({}, toggled, { [entry.key]: !isOpen(entry) })
  }

  // The newest message in view once the thread opens.
  function toEnd() {
    scroll.contentItem.contentY = Math.max(0, scroll.contentItem.contentHeight - scroll.availableHeight)
  }
  Component.onCompleted: Qt.callLater(toEnd)
  onThreadChanged: Qt.callLater(toEnd)

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    IconButton { visible: view.back; name: "chevron-left"; tip: "back to the list"; onClicked: Mail.close() }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 4
      Label {
        Layout.fillWidth: true
        text: view.thread.subject
        font.pixelSize: 16
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
      RowLayout {
        spacing: 8
        Label { text: "with " + view.thread.agent; color: Theme.dim; font.pixelSize: 11 }
        ProjectTag { name: view.thread.project }
        ThreadState { thread: view.thread }
      }
    }
  }

  Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

  C.ScrollView {
    id: scroll
    Layout.fillWidth: true
    Layout.fillHeight: true
    clip: true
    contentWidth: availableWidth

    ColumnLayout {
      width: scroll.availableWidth
      spacing: 8

      Repeater {
        model: view.visibleEntries
        delegate: ColumnLayout {
          id: slot
          required property var modelData
          required property int index
          Layout.fillWidth: true
          spacing: 8

          Entry {
            Layout.fillWidth: true
            entry: slot.modelData
            thread: view.thread.key
            expanded: view.isOpen(slot.modelData)
            MouseArea {
              anchors { left: parent.left; right: parent.right; top: parent.top }
              height: 36
              cursorShape: Qt.PointingHandCursor
              enabled: !(slot.modelData.kind === "request" && slot.modelData.open)
              onClicked: view.toggle(slot.modelData)
            }
          }

          // The fold of a long thread's middle, after its first message.
          Rectangle {
            Layout.fillWidth: true
            visible: slot.index === 0 && view.hidden > 0
            implicitHeight: 30
            color: "transparent"
            border.color: Theme.line
            Label {
              anchors.centerIn: parent
              text: view.hidden + " earlier messages"
              color: Theme.primary
              font.pixelSize: 11
              font.letterSpacing: 1
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: view.showAll = true }
          }
        }
      }
    }
  }

  FilePicker { id: files; Layout.fillWidth: true }

  RowLayout {
    Layout.fillWidth: true
    spacing: 8
    Editor {
      id: reply
      Layout.fillWidth: true
      Layout.preferredHeight: 72
      placeholderText: "reply to " + view.thread.agent
      onSubmitted: Mail.reply(view.thread.key, reply.take(), files.take())
    }
    TraceButton {
      Layout.alignment: Qt.AlignBottom
      dense: true
      role: "primary"
      icon: "send"
      text: "SEND"
      enabled: reply.text.trim() !== ""
      tip: "ctrl+enter"
      onClicked: Mail.reply(view.thread.key, reply.take(), files.take())
    }
  }
}
