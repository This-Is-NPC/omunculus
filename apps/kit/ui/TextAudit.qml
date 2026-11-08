import QtQuick

// TextAudit finds text that escapes its place. Every second it walks the
// window's items and logs, once per text and reason, each visible text that
// is wider than its box with neither elide nor wrap (`overflow`), drawn past
// the window's left or right edge (`window`), or past the right edge of the
// nearest clipping item that does not scroll sideways (`clipped`), as
//   text-fit: <reason> "<first 60 chars>" w=<w> cw=<cw> x=<x>
// A text is reported once it is seen out of place on two walks running, so
// a slide or a sweep under way is not. An app loads it only to check itself.
Item {
  id: audit

  // What was out of place on the last walk, and what has been logged.
  property var seen: ({})
  property var logged: ({})

  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: audit.walk()
  }

  function walk() {
    const window = Window.window
    if (!window || !window.contentItem)
      return
    const now = {}
    visit(window.contentItem, window.width, 1, null, false, now)
    for (const key in now)
      if (seen[key] && !logged[key]) {
        logged[key] = true
        console.log(now[key])
      }
    seen = now
  }

  // `clipRight` is the right edge, in the window, of the nearest clipping
  // item, unless that one scrolls sideways: then `scrolled` is set, and that
  // item keeps what it holds in the window by its own edges.
  function visit(item, windowWidth, opacity, clipRight, scrolled, out) {
    if (!item.visible)
      return
    const shade = opacity * item.opacity
    if (shade <= 0)
      return
    if (isText(item) && item.text !== "")
      check(item, windowWidth, clipRight, scrolled, out)
    let right = clipRight
    let sideways = scrolled
    if (item.clip && scrollsSideways(item)) {
      right = null
      sideways = true
    } else if (item.clip)
      right = item.mapToItem(null, item.width, 0).x
    for (const child of item.children)
      visit(child, windowWidth, shade, right, sideways, out)
  }

  // A Text (a Label among them): TextEdit and TextInput have no `truncated`.
  function isText(item) { return "truncated" in item && "elide" in item && "wrapMode" in item }
  function scrollsSideways(item) { return "flickableDirection" in item && item.contentWidth > item.width + 1 }

  function check(item, windowWidth, clipRight, scrolled, out) {
    const left = item.mapToItem(null, 0, 0).x
    const right = item.mapToItem(null, Math.max(item.width, item.contentWidth), 0).x
    const reasons = []
    if (item.elide === Text.ElideNone && item.wrapMode === Text.NoWrap && item.contentWidth > item.width + 1)
      reasons.push("overflow")
    if (!scrolled && (right > windowWidth + 1 || left < -1))
      reasons.push("window")
    if (clipRight !== null && right > clipRight + 1)
      reasons.push("clipped")
    for (const reason of reasons) {
      const text = String(item.text).replace(/\s+/g, " ").slice(0, 60)
      out[reason + "\u0000" + item.text] = "text-fit: " + reason + " \"" + text + "\" w=" + Math.round(item.width)
        + " cw=" + Math.round(item.contentWidth) + " x=" + Math.round(left)
    }
  }
}
