import QtQuick
import "focus.js" as Focus

// ScrollPage is content taller than its room: it scrolls with the wheel, with
// PgUp/PgDn, Home/End — and ↑/↓ while it holds the keyboard itself — and it
// scrolls to keep the control the keyboard moves to in view, also when the content
// around it changes height.
Flickable {
  id: page

  clip: true
  boundsBehavior: Flickable.StopAtBounds

  function scrollTo(y) { contentY = Math.max(0, Math.min(contentHeight - height, y)) }

  readonly property Item focused: Window.activeFocusItem
  onFocusedChanged: keep()
  onContentHeightChanged: Qt.callLater(keep)

  // A text that wraps over several lines keeps its caret in view, not the
  // whole text, which may be taller than the page.
  readonly property var typing: !!focused && focused !== page && focused["lineCount"] !== undefined ? focused : null
  Connections {
    target: page.typing
    function onCursorRectangleChanged() { page.keep() }
  }

  function keep() {
    if (!focused || focused === page || !Focus.within(focused, contentItem))
      return
    if (typing) {
      const caret = typing.cursorRectangle
      const at = typing.mapToItem(contentItem, 0, caret.y).y
      if (at < contentY)
        scrollTo(at - 12)
      else if (at + caret.height + 32 > contentY + height)
        scrollTo(at + caret.height + 32 - height)
      return
    }
    // A control taller than a clipping item around it, as a text that scrolls
    // in its own frame, shows only through that item: the item is kept in view.
    let shown = focused
    for (let at = focused.parent; at && at !== contentItem; at = at.parent)
      if (at.clip && at.height < shown.height)
        shown = at
    // Below it, room for a line that says what is wrong with it.
    const top = shown.mapToItem(contentItem, 0, 0).y
    const bottom = top + shown.height + 32
    if (top < contentY)
      scrollTo(top - 12)
    else if (bottom > contentY + height)
      scrollTo(bottom - height)
  }

  Keys.onPressed: event => {
    const step = { [Qt.Key_PageDown]: height, [Qt.Key_PageUp]: -height, [Qt.Key_Home]: -contentY, [Qt.Key_End]: contentHeight }[event.key]
      ?? (page.activeFocus ? { [Qt.Key_Down]: 40, [Qt.Key_Up]: -40 }[event.key] : undefined)
    if (step === undefined)
      return
    scrollTo(contentY + step)
    event.accepted = true
  }
}
