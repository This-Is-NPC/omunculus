import QtQuick
import QtQuick.Controls.Basic as C
import "Breakpoints.js" as Breakpoints

// Hint is the hover tooltip: monospace text in a frame of the accent, below
// its control. `active` says the pointer is over the control or Tab focus is
// on it; after the delay the hint shows, unless the control is hidden or
// disabled. `dismiss()` closes it, and it stays closed until `active` turns
// false and true again. One hint shows at a time. It stays inside the
// window: at most the window's width less 24 px, wrapping, and moved left
// when its control is near the right edge. On a narrow window, where the
// content under a control is close, it shows beside the control instead,
// when it fits there, so it never covers what is below.
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
  // Where the control is in the window when it shows.
  readonly property real left: visible && overlay && parent ? parent.mapToItem(overlay, 0, 0).x : 0
  // Narrow, beside the control, on the right or else the left, when there is
  // room for it; else under it.
  readonly property real side: {
    if (!visible || !overlay || !parent || Breakpoints.size(overlay.width) !== "narrow")
      return 0
    if (left + parent.width + 6 + width <= overlay.width - 12)
      return 1
    return left - 6 - width >= 12 ? -1 : 0
  }
  // Under its control's left edge, moved to stay 12 px inside the window.
  x: side > 0 ? parent.width + 6 : side < 0 ? -width - 6
    : Math.max(12, Math.min(left, overlay ? overlay.width - 12 - width : left)) - left
  y: side !== 0 ? (parent.height - height) / 2 : parent.height + 6
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
