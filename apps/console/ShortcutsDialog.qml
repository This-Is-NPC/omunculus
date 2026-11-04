pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui"

// ShortcutsDialog lists every key the window answers to, by where it works,
// each key beside what it does, or above it in a dialog under 480 px wide;
// ? or F1 opens it and the arrows or PgUp/PgDn scroll it.
ModalDialog {
  id: dialog

  maxWidth: 620
  height: Math.min(parent.height - 48, panel.implicitHeight)
  onOpened: scroll.forceActiveFocus()

  // [group, [[keys, what they do]…]]; keys are written as they are pressed.
  // Those with a key of the table are read from it; the others are the keys
  // of the controls themselves. Nothing that sends, answers, grants, denies,
  // escalates, reverts, deletes or cancels has a key of its own.
  readonly property var groups: [
    ["everywhere", [
      ["Tab · Shift+Tab", "move between controls"],
      ["Enter · Space", "press the control"]
    ].concat(Shortcuts.rows("everywhere"), [
      ["Alt + a key of the bar", "the key, from a field being written"]
    ])],
    ["typing", [
      ["any key", "text goes only into a field; with none under the cursor, keys do nothing but say so"],
      ["a bare key", "acts only on what you navigate, a second after the last key typed in a field"]
    ]],
    ["start", Shortcuts.rows("start")],
    ["conversations", [
      ["↑ · ↓", "choose"],
      ["Enter", "open"]
    ].concat(Shortcuts.rows("conversations"))],
    ["new conversation", [
      ["← · → · ↑ · ↓", "choose whom it is with"],
      ["Enter", "start it with them"]
    ].concat(Shortcuts.rows("new conversation"))],
    ["chat", Shortcuts.rows("chat")],
    ["team", [
      ["↑ · ↓", "move between the works; the detail follows"],
      ["→ · ←", "unfold, fold; on a folded work, go to its parent"],
      ["Enter", "open its detail, or its tabs beside the outline"]
    ].concat(Shortcuts.rows("team"), [
      ["Esc", "the detail, then the outline, then back"]
    ])],
    ["work", Shortcuts.rows("work").concat([["Esc", "back"]])],
    ["thread", Shortcuts.rows("thread").concat([["Esc", "back"]])],
    ["board", [
      ["← · → · ↑ · ↓", "move between the works, across and down the columns"],
      ["Enter · Space", "open the work on its page"]
    ].concat(Shortcuts.rows("board"), [
      ["Esc", "empty the filter, then back to the works"]
    ])],
    ["log", Shortcuts.rows("log").concat([
      ["Esc", "empty the filter, then back to the rows"]
    ])],
    ["timeline", [
      ["↑ · ↓ · PgUp · PgDn", "move between entries"],
      ["Home · End", "first and last entry"],
      ["Tab", "the tools of the entry"]
    ]],
    ["composer", [
      ["Enter", "send, or leave the note"],
      ["Shift+Enter", "a new line"],
      ["Esc", "write to the agent rather than note"]
    ]],
    ["request", [
      ["Enter", "in its words: answer, or escalate when escalating"],
      ["Ctrl+Enter", "in a list of questions: send the answers"]
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
              delegate: GridLayout {
                id: key
                required property var modelData
                Layout.fillWidth: true
                columns: list.width < 480 ? 1 : 2
                columnSpacing: 14
                rowSpacing: 2
                Label {
                  Layout.preferredWidth: key.columns === 1 ? -1 : 200
                  Layout.fillWidth: key.columns === 1
                  text: key.modelData[0]
                  color: Theme.primary
                  font.pixelSize: 11
                  font.letterSpacing: 1
                  wrapMode: Text.Wrap
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
