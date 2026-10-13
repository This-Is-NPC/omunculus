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
      ["Esc", "go back"],
      ["? · F1", "these keys"]
    ]],
    ["start", [
      ["N", "new conversation"],
      ["H", "the conversations"]
    ]],
    ["conversations", [
      ["↑ · ↓", "choose"],
      ["Enter", "open"],
      ["N", "new conversation"],
      ["/", "search"]
    ]],
    ["conversation", [
      ["Esc", "back from a work, or to the conversations"]
    ]],
    ["timeline", [
      ["↑ · ↓ · PgUp · PgDn", "move between entries"],
      ["Home · End", "first and last entry"],
      ["Tab", "the tools of the entry"]
    ]],
    ["composer", [
      ["Enter", "send"]
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
                  Layout.preferredWidth: 170
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
