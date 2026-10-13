pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ItemPage is the screen of one item of the project: what kind it is, its
// name, the pack it comes from, and, read, its `facts` and `details`; edited,
// its `form`, the name first when it has one. Its commands, for the bar, go
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
  default property alias form: formColumn.data

  // The row of its table it was opened from.
  property string loadedId: ""

  // Back to the list; and asking to remove it, which the list confirms.
  signal back()
  signal removing()

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
      width: scroll.width
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

      // Read: label and value, a line each.
      GridLayout {
        Layout.fillWidth: true
        visible: !page.editing && page.facts.length > 0
        columns: 2
        columnSpacing: 24
        rowSpacing: 8
        Repeater {
          model: page.editing ? [] : page.facts.reduce((cells, fact) => cells.concat([{ label: true, text: fact[0] }, { label: false, text: fact[1] }]), [])
          delegate: DecodeLabel {
            required property var modelData
            Layout.fillWidth: !modelData.label
            Layout.alignment: Qt.AlignTop
            value: modelData.label ? modelData.text.toUpperCase() : (modelData.text === "" ? "—" : modelData.text)
            color: modelData.label ? Theme.dim : Theme.foreground
            font.pixelSize: modelData.label ? 10 : 13
            font.letterSpacing: modelData.label ? 2 : 0
            wrapMode: modelData.label ? Text.NoWrap : Text.Wrap
          }
        }
      }
      ColumnLayout {
        id: detailsColumn
        Layout.fillWidth: true
        visible: !page.editing
        spacing: 12
      }

      // Edited: its name, then its own fields.
      Field {
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
