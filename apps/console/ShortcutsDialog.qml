pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ShortcutsDialog lists every key the window answers to, by where it works;
// ? or F1 opens it and the arrows or PgUp/PgDn scroll it.
ModalDialog {
  id: dialog

  maxWidth: 620
  height: Math.min(parent.height - 48, panel.implicitHeight)
  onOpened: scroll.forceActiveFocus()

  // [group, [[keys, what they do]…]]; keys are written as they are pressed.
  readonly property var groups: [
    ["everywhere", [
      ["Tab · Shift+Tab", "move between controls"],
      ["Enter · Space", "press the control"],
      ["1 · 2 · 3 · 4 · 5", "the pages: the conversations, the conversation, the map, the log, the board"],
      ["Ctrl+1 … Ctrl+5", "the same, from a field being written or the picker"],
      ["Ctrl+Tab · Ctrl+Shift+Tab", "the next or the previous page"],
      ["Esc", "let go of what the page holds, then back to where you were, at last the start"],
      ["Alt + a key of the bar", "the key, from a field being written"],
      ["? · F1", "these keys"]
    ]],
    ["start", [
      ["N · H · B", "a new conversation, the conversations, the board"]
    ]],
    ["conversations", [
      ["↑ · ↓", "choose"],
      ["Enter", "open"],
      ["N", "new conversation"],
      ["/", "search"]
    ]],
    ["new conversation", [
      ["← · → · ↑ · ↓", "choose whom it is with"],
      ["1 … 9 · Enter", "start it with them"]
    ]],
    ["conversation", [
      ["R", "answer the oldest request waiting on you"],
      ["M", "show the oldest note to you and mark it read"],
      ["N", "new conversation"]
    ]],
    ["map", [
      ["F", "the whole map in view"],
      ["R", "answer what the node picked asked"],
      ["E", "escalate what it asked you"],
      ["C", "leave it a note, without a run"],
      ["M", "mark its notes read"],
      ["W", "write to its agent"]
    ]],
    ["board", [
      ["← · → · ↑ · ↓", "move between the works, across and down the columns"],
      ["Enter · Space", "open the work on its conversation's map"],
      ["S · A · P", "by state, a lane per agent, a lane per project"],
      ["/", "filter the works"],
      ["Esc", "empty the filter, then back to the works"]
    ]],
    ["log", [
      ["/", "filter the events"],
      ["Esc", "empty the filter, then back to the rows"]
    ]],
    ["timeline", [
      ["↑ · ↓ · PgUp · PgDn", "move between entries"],
      ["Home · End", "first and last entry"],
      ["Tab", "the tools of the entry"]
    ]],
    ["composer", [
      ["Enter", "send, or leave the note"],
      ["Esc", "write to the agent rather than note"]
    ]],
    ["request", [
      ["Enter", "in its words: answer, or escalate when escalating"]
    ]]
  ]

  contentItem: DialogPanel {
    id: panel
    dialogOpen: dialog.visible
    implicitHeight: list.implicitHeight + 56
    index: "?"
    title: "keys"
    active: true

    ScrollPage {
      id: scroll
      anchors.fill: parent
      contentHeight: list.implicitHeight

      ColumnLayout {
        id: list
        width: scroll.width
        spacing: 14
        Repeater {
          model: dialog.groups
          delegate: ColumnLayout {
            id: group
            required property var modelData
            Layout.fillWidth: true
            spacing: 6
            Kicker { Layout.fillWidth: true; text: group.modelData[0] }
            Repeater {
              model: group.modelData[1]
              delegate: RowLayout {
                id: key
                required property var modelData
                Layout.fillWidth: true
                spacing: 14
                Label {
                  Layout.preferredWidth: 200
                  text: key.modelData[0]
                  color: Theme.primary
                  font.pixelSize: 11
                  font.letterSpacing: 1
                }
                Label {
                  Layout.fillWidth: true
                  text: key.modelData[1]
                  color: Theme.dim
                  font.pixelSize: 11
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }
      }
    }
  }
}
