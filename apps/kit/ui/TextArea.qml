import QtQuick
import QtQuick.Controls.Basic as C
import QtQuick.Layouts

// TextArea is the multi-line input: one line tall that grows with its text up
// to `maxLines`, then scrolls. Enter emits `submitted` and Shift+Enter breaks
// the line; Enter that confirms an input-method composition does neither.
// The owner empties it (`clear()`) once the text is taken. `label` is a small
// caption above; `framed: false` leaves the outline to the owner.
ColumnLayout {
  id: area

  property alias text: input.text
  // Shown while the box is empty, on one line: cut at the box's width, never wrapped under its neighbours.
  property string placeholderText: ""
  property string label: ""
  property bool dense: false
  property bool invalid: false
  property bool framed: true
  property int maxLines: 8
  // Sending dims the box and stops it taking input.
  property bool sending: false
  readonly property bool focused: input.activeFocus

  signal submitted(string text)

  function focusBox() { input.forceActiveFocus() }
  function clear() { input.clear() }
  // Focus given to the area, as forceActiveFocus() on it, goes to its box.
  onActiveFocusChanged: if (activeFocus) input.forceActiveFocus()

  spacing: Theme.space.tight
  opacity: sending ? 0.5 : 1

  Caption { visible: area.label !== ""; text: area.label.toUpperCase() }

  Item {
    Layout.fillWidth: true
    implicitHeight: Math.min(Math.max(input.implicitHeight, area.dense ? 30 : Theme.size.control), Math.ceil(metrics.lineSpacing * area.maxLines) + input.topPadding + input.bottomPadding)

    InputFrame {
      visible: area.framed
      anchors.fill: parent
      focused: input.activeFocus
      invalid: area.invalid
    }

    Flickable {
      anchors.fill: parent
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      // A text that fits leaves the wheel to the page around it.
      interactive: contentHeight > height
      C.ScrollBar.vertical: C.ScrollBar { policy: C.ScrollBar.AsNeeded }

      C.TextArea.flickable: C.TextArea {
        id: input
        enabled: !area.sending
        font.family: Theme.fontFamily
        font.pixelSize: area.dense ? 12 : 13
        color: Theme.foreground
        placeholderText: placeholder.elidedText
        placeholderTextColor: Theme.dim
        selectionColor: Theme.primary
        selectedTextColor: Theme.badgeForeground
        wrapMode: TextEdit.Wrap
        leftPadding: area.dense ? Theme.space.gap : Theme.space.inset
        rightPadding: area.dense ? Theme.space.gap : Theme.space.inset
        topPadding: area.dense ? Theme.space.tight : Theme.space.cell
        bottomPadding: area.dense ? Theme.space.tight : Theme.space.cell
        background: null
        Accessible.name: area.label !== "" ? area.label : area.placeholderText

        function enter(event) {
          if (event.modifiers & Qt.ShiftModifier || inputMethodComposing)
            event.accepted = false
          else
            area.submitted(text)
        }
        // Marks that text is being written, and leaves the key to the box.
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: Typing.mark()
        Keys.onReturnPressed: event => enter(event)
        Keys.onEnterPressed: event => enter(event)
        // Tab moves on, as from a one-line field, instead of typing a tab.
        Keys.onTabPressed: nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason)
        Keys.onBacktabPressed: nextItemInFocusChain(false).forceActiveFocus(Qt.BacktabFocusReason)
      }
    }
  }

  FontMetrics { id: metrics; font: input.font }
  TextMetrics {
    id: placeholder
    font: input.font
    text: area.placeholderText
    elide: Text.ElideRight
    elideWidth: Math.max(0, input.width - input.leftPadding - input.rightPadding)
  }
}
