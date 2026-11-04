import QtQuick
import QtQuick.Controls.Basic as C

// Hint is the hover tooltip: monospace text in a frame of the accent, below
// its control. `active` says the pointer is over the control or Tab focus is
// on it; after the delay the hint shows, unless the control is hidden or
// disabled. `dismiss()` closes it, and it stays closed until `active` turns
// false and true again. One hint shows at a time.
C.ToolTip {
  id: hint

  property bool active: false
  // Closed by a press or Esc until the pointer or focus leaves.
  property bool dismissed: false
  readonly property bool wanted: active && !dismissed && text.length > 0 && parent.visible && parent.enabled
    && (Theme.shownHint === null || Theme.shownHint === hint)

  function dismiss() { dismissed = true }

  delay: 450
  padding: 8
  x: 0
  y: parent.height + 6
  visible: wanted
  onActiveChanged: if (!active) dismissed = false
  onVisibleChanged: {
    if (visible)
      Theme.shownHint = hint
    else if (Theme.shownHint === hint)
      Theme.shownHint = null
  }
  Component.onDestruction: if (Theme.shownHint === hint) Theme.shownHint = null

  contentItem: Label {
    text: hint.text
    wrapMode: Text.Wrap
  }
  background: Rectangle {
    color: Theme.background
    border.color: Theme.primary
  }
}
