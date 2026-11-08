import QtQuick
import QtQuick.Controls.Basic as C

// Hint is the hover tooltip: monospace text in a frame of the accent, below
// its control. `active` says the pointer is over the control or Tab focus is
// on it; after the delay the hint shows, unless the control is hidden or
// disabled. `dismiss()` closes it, and it stays closed until `active` turns
// false and true again. One hint shows at a time. It stays inside the
// window: at most the window's width less 24 px, wrapping, and moved left
// when its control is near the right edge.
C.ToolTip {
  id: hint

  property bool active: false
  // Closed by a press or Esc until the pointer or focus leaves.
  property bool dismissed: false
  readonly property bool wanted: active && !dismissed && text.length > 0 && parent.visible && parent.enabled
    && (Theme.shownHint === null || Theme.shownHint === hint)

  function dismiss() { dismissed = true }

  // The window's overlay, which the hint is drawn on.
  readonly property Item overlay: C.Overlay.overlay

  delay: 450
  padding: 8
  width: overlay ? Math.min(implicitWidth, overlay.width - 24) : implicitWidth
  // Under its control's left edge, moved to stay 12 px inside the window,
  // where the control is when it shows.
  x: {
    if (!visible || !overlay || !parent)
      return 0
    const left = parent.mapToItem(overlay, 0, 0).x
    return Math.max(12, Math.min(left, overlay.width - 12 - width)) - left
  }
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
