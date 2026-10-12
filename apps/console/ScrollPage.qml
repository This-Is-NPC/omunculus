import QtQuick
import "focus.js" as Focus

// ScrollPage is content taller than its room: it scrolls with the wheel, with
// PgUp/PgDn — and ↑/↓ while it holds the keyboard itself — and it scrolls to
// keep the control the keyboard moves to in view.
Flickable {
  id: page

  clip: true
  boundsBehavior: Flickable.StopAtBounds

  function scrollTo(y) { contentY = Math.max(0, Math.min(contentHeight - height, y)) }

  readonly property Item focused: Window.activeFocusItem
  onFocusedChanged: {
    if (!focused || focused === page || !Focus.within(focused, contentItem))
      return
    const top = focused.mapToItem(contentItem, 0, 0).y
    if (top < contentY)
      scrollTo(top - 12)
    else if (top + focused.height > contentY + height)
      scrollTo(top + focused.height - height + 12)
  }

  Keys.onPressed: event => {
    const step = { [Qt.Key_PageDown]: height, [Qt.Key_PageUp]: -height }[event.key]
      ?? (page.activeFocus ? { [Qt.Key_Down]: 40, [Qt.Key_Up]: -40 }[event.key] : undefined)
    if (step === undefined)
      return
    scrollTo(contentY + step)
    event.accepted = true
  }
}
