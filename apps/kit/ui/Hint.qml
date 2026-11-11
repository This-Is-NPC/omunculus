import QtQuick
import QtQuick.Controls.Basic as C
import "Breakpoints.js" as Breakpoints

// Hint is the hover tooltip: monospace text in a frame of the accent, below
// its control. `active` says the pointer is over the control, never that the
// keyboard is on it, so a control focused by the program shows no hint; after
// the delay the hint shows, unless the control is hidden or disabled. `dismiss()` closes it, and it stays closed until `active` turns
// false and true again. One hint shows at a time. It stays inside the
// window: at most the window's width less 24 px, wrapping, and moved left
// when its control is near the right edge. On a narrow window, which is
// touched rather than typed on, it leaves out the keys a tip names after two
// spaces ("close  Esc") and shows only the words.
C.ToolTip {
  id: hint

  property bool active: false
  // The pointer's y within the control, when the hint belongs under that line
  // of it (a link in a paragraph) rather than under the whole control; -1 else.
  property real below: -1
  // Closed by a press or Esc until the pointer or focus leaves.
  property bool dismissed: false
  readonly property bool wanted: active && !dismissed && said.length > 0 && parent.visible && parent.enabled
    && (Theme.shownHint === null || Theme.shownHint === hint)

  function dismiss() { dismissed = true }

  // The window's overlay, which the hint is drawn on.
  readonly property Item overlay: C.Overlay.overlay

  delay: 450
  padding: 8
  width: overlay ? Math.min(implicitWidth, overlay.width - 24) : implicitWidth
  // Where the control is in the window when it shows.
  readonly property real left: visible && overlay && parent ? parent.mapToItem(overlay, 0, 0).x : 0
  readonly property bool narrow: !!overlay && Breakpoints.size(overlay.width) === "narrow"
  // What the hint says: the words, without the keys on a narrow window.
  readonly property string said: narrow ? text.replace(/ {2,}\S.*$/, "") : text
  // Under its control's left edge, moved to stay 12 px inside the window.
  x: Math.max(12, Math.min(left, overlay ? overlay.width - 12 - width : left)) - left
  // Under the control, or under the line, kept inside the window.
  readonly property real top: visible && overlay && parent ? parent.mapToItem(overlay, 0, 0).y : 0
  y: below >= 0 ? Math.max(0, Math.min(below + 22, overlay ? overlay.height - 12 - height - top : below + 22)) : parent.height + 6
  visible: wanted
  onActiveChanged: if (!active) dismissed = false
  onVisibleChanged: {
    if (visible)
      Theme.shownHint = hint
    else if (Theme.shownHint === hint)
      Theme.shownHint = null
  }
  Connections {
    target: Theme
    function onHintsDismissed() { hint.dismiss() }
  }
  Component.onDestruction: if (Theme.shownHint === hint) Theme.shownHint = null

  contentItem: Label {
    text: hint.said
    wrapMode: Text.Wrap
  }
  background: Rectangle {
    color: Theme.background
    border.color: Theme.primary
  }
}
