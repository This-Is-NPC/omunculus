pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ItemPage is the screen of one item of the project: what kind it is, its
// name, the pack it comes from, and, read, its `image` and `facts`, its
// `details` and what is `related` to it, each related item opening where
// it is shown;
// edited, its `form`, the name first when it has one. Its commands, for the bar, go
// back, edit, remove, save, discard and cancel as fit, then its own `extra`.
// An item a pack brings, or one the config does not write, is only read.
Item {
  id: page

  // "agent", "model", ...
  required property string kind
  property string title: draft ? draft.newName || draft.section : ""
  // The pack it comes from, or "".
  property string origin: ""
  // The draft it edits, or null for an item only read.
  property ItemDraft draft: null
  readonly property bool editable: draft !== null && origin === ""
  property bool editing: false
  // [[label, value]], shown while it is read.
  property var facts: []
  // Commands of its own, as the bar takes them, after the usual ones.
  property var extra: []
  property alias details: detailsColumn.data
  // A picture of it, as a url, shown beside what it is, or "".
  property string image: ""
  // [{title, items: [{text, section, id}]}]: what it uses and what uses it,
  // each item by the section and row it opens.
  property var related: []
  default property alias form: formColumn.data

  // Wide enough for what is related to stand beside the rest.
  readonly property bool wide: scroll.width >= 1000

  // A titled frame the read panels share; its fields stack inside.
  component Panel: Rectangle {
    id: panel
    property string title
    default property alias fields: inner.data
    Layout.alignment: Qt.AlignTop
    implicitHeight: inner.implicitHeight + 32
    color: "transparent"
    border.color: Theme.line
    ColumnLayout {
      id: inner
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
      spacing: 10
      Caption { text: panel.title.toUpperCase() }
    }
  }

  // The row of its table it was opened from.
  property string loadedId: ""

  // Back to the list; asking to remove it, which the list confirms; and
  // asking to open a related item.
  signal back()
  signal removing()
  signal followed(int section, string id)

  readonly property var commands: (editing ? [
    { text: draft && draft.saving ? "SAVING" : "SAVE", icon: "enter", role: "primary", tip: draft && draft.conflict ? "the file changed: discard to read it again" : "write it into the project's config  ctrl+s",
      enabled: !!draft && draft.dirty && !draft.conflict && draft.nameIssue === "", run: () => draft.save() },
    { text: "DISCARD", icon: "trash", tip: "back to what the file holds", shown: !!draft && draft.dirty && draft.stored !== null, run: () => draft.reset() },
    { text: "CANCEL", icon: "close", tip: "stop editing  esc", run: () => page.cancel() }
  ] : [
    { text: "BACK", icon: "chevron-left", tip: "back to the list  esc", run: () => page.back() },
    { text: "EDIT", icon: "edit", tip: "change it  ctrl+e", shown: editable, run: () => page.editing = true },
    { text: "DELETE", icon: "trash", role: "guarded", tip: "remove it from the project's config", shown: editable && draft.stored !== null, run: () => page.removing() }
  ]).concat(extra)

  // Gives the keyboard to the screen: its first field when editing, else the
  // screen itself, whose Esc goes back.
  function takeFocus() {
    if (!editing) {
      page.forceActiveFocus()
      return
    }
    const first = nameField.visible ? nameField.input : formColumn.nextItemInFocusChain(true)
    if (first)
      first.forceActiveFocus()
  }
  onEditingChanged: Qt.callLater(takeFocus)
  activeFocusOnTab: false

  // Esc: out of editing, then back to the list. A new item left unsaved goes.
  function cancel() {
    if (draft && draft.stored === null) {
      back()
      return
    }
    if (draft)
      draft.reset()
    editing = false
  }
  function leave() {
    if (editing)
      cancel()
    else
      back()
  }

  Connections {
    target: page.draft
    function onSaved() { page.editing = false }
  }
  Shortcut { enabled: page.visible && page.editable && !page.editing; sequence: "Ctrl+E"; onActivated: page.editing = true }
  Shortcut { enabled: page.visible && page.editing && !!page.draft && page.draft.dirty; sequence: "Ctrl+S"; onActivated: page.draft.save() }

  ScrollPage {
    id: scroll
    anchors.fill: parent
    contentHeight: content.implicitHeight

    ColumnLayout {
      id: content
      // Read, it takes the room up to a wide measure; edited, the form keeps
      // a readable one; centred either way.
      width: Math.min(scroll.width, page.editing ? 880 : 1640)
      x: (scroll.width - width) / 2
      spacing: 14

      // What it is, and where it comes from.
      Row {
        spacing: 12
        Label { text: page.kind.toUpperCase(); color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 3 }
        Label { visible: page.origin !== ""; text: "◆ " + page.origin.toUpperCase(); color: Theme.magenta; font.pixelSize: 10; font.letterSpacing: 2 }
        Label {
          visible: !!page.draft && page.draft.dirty && !page.draft.saving
          text: !page.draft ? "" : page.draft.conflict ? "CHANGED IN THE FILE" : page.draft.stored === null ? "NEW" : "UNSAVED"
          color: page.draft && page.draft.conflict ? Theme.warning : Theme.primary
          font.pixelSize: 10
          font.letterSpacing: 2
        }
        Label { visible: page.editing; text: "EDITING"; color: Theme.secondary; font.pixelSize: 10; font.letterSpacing: 3 }
      }
      DecodeLabel {
        Layout.fillWidth: true
        value: page.title
        color: page.kind === "agent" ? Studio.toneOf(page.title) : Theme.foreground
        font.pixelSize: 22
        font.letterSpacing: 2
        elide: Text.ElideRight
      }
      FieldError {
        Layout.fillWidth: true
        text: page.draft ? page.draft.issue : ""
      }

      // Read: beside its image, what it is, as pairs; under them its
      // description, the width of the main column; what is related to it
      // down the right side. One under the other on a narrow window. The
      // page scrolls as a whole.
      GridLayout {
        Layout.fillWidth: true
        visible: !page.editing
        columns: page.wide ? 2 : 1
        columnSpacing: 24
        rowSpacing: 20

        ColumnLayout {
          id: main
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          spacing: 20

          RowLayout {
            Layout.fillWidth: true
            spacing: 24
            Image {
              Layout.alignment: Qt.AlignTop
              Layout.preferredWidth: page.image === "" ? 0 : Math.min(260, main.width * 0.3)
              Layout.preferredHeight: Layout.preferredWidth
              visible: page.image !== ""
              source: page.image
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              smooth: true
              mipmap: true
              Rectangle { anchors.fill: parent; color: "transparent"; border.color: Theme.line }
            }
            GridLayout {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignTop
              visible: page.facts.length > 0
              // Two pairs a row when there is room.
              columns: main.width - (page.image === "" ? 0 : 284) > 760 ? 4 : 2
              columnSpacing: 18
              rowSpacing: 10
              Repeater {
                model: page.editing ? [] : page.facts.reduce((cells, fact) => cells.concat([{ label: true, text: fact[0] }, { label: false, text: fact[1] }]), [])
                delegate: DecodeLabel {
                  required property var modelData
                  Layout.fillWidth: !modelData.label
                  Layout.preferredWidth: modelData.label ? -1 : 1
                  Layout.alignment: Qt.AlignTop
                  value: modelData.label ? modelData.text.toUpperCase() : (modelData.text === "" ? "—" : modelData.text)
                  color: modelData.label ? Theme.dim : Theme.foreground
                  font.pixelSize: modelData.label ? 10 : 13
                  font.letterSpacing: modelData.label ? 2 : 0
                  wrapMode: modelData.label ? Text.NoWrap : Text.Wrap
                }
              }
            }
          }

          Panel {
            title: "description"
            Layout.fillWidth: true
            visible: detailsColumn.children.length > 0
            ColumnLayout {
              id: detailsColumn
              Layout.fillWidth: true
              spacing: 12
            }
          }
        }

        Panel {
          title: "related"
          Layout.alignment: Qt.AlignTop
          Layout.preferredWidth: page.wide ? 380 : main.width
          Note {
            visible: page.related.every(group => group.items.length === 0)
            value: "Nothing else in the project names it."
          }
          Repeater {
            model: page.related.filter(group => group.items.length > 0)
            delegate: ColumnLayout {
              id: group
              required property var modelData
              Layout.fillWidth: true
              spacing: 4
              Caption { text: group.modelData.title }
              Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                  model: group.modelData.items
                  delegate: Chip {
                    required property var modelData
                    text: modelData.text
                    tip: "open " + modelData.text
                    onClicked: page.followed(modelData.section, modelData.id)
                  }
                }
              }
            }
          }
        }
      }

      // Edited: its name, then its own fields.
      Field {
        id: nameField
        Layout.fillWidth: true
        visible: page.editing && !!page.draft && !page.draft.single
        label: "name"
        value: page.draft ? page.draft.newName : ""
        error: page.draft ? page.draft.nameIssue : ""
        onEdited: text => page.draft.newName = text.trim()
      }
      ColumnLayout {
        id: formColumn
        Layout.fillWidth: true
        visible: page.editing
        spacing: 12
      }
    }
  }
}
