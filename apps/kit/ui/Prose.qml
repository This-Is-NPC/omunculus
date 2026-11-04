import QtQuick
import Quickshell
import "Markdown.js" as Markdown

// Prose is what an agent wrote, shown as Markdown as it was written: each
// line break kept, and a line after a list that is no item of it a paragraph
// of its own. Its web addresses are links in the accent: a bare address
// becomes one, the pointer turns over one and its address shows beside it,
// and choosing one opens it in the desktop's browser. With links, it is a
// stop of the keyboard: Left and Right pick one, Enter or Space opens it.
// Only http and https addresses open. An image shows as its alt text, never
// loaded. Plain, it is the text as it was written, with no marks and no links.
Label {
  id: prose

  // The Markdown to show.
  property string source
  property bool plain: false
  // The link the keyboard is on.
  property int chosen: 0

  readonly property var parsed: plain ? { text: source, links: [] } : linked(written(Markdown.imageless(String(source || ""))))
  readonly property var links: parsed.links
  readonly property string pointed: hoveredLink !== "" ? hoveredLink : activeFocus && links.length > 0 ? links[Math.min(chosen, links.length - 1)] : ""

  text: parsed.text
  textFormat: plain ? Text.PlainText : Text.MarkdownText
  // The links the markdown makes itself, an e-mail address among them, take
  // the accent like the web addresses linked here.
  linkColor: Theme.primary
  activeFocusOnTab: links.length > 0
  onLinksChanged: chosen = 0
  onLinkActivated: link => open(link)

  // `value` with each line break kept, where Markdown would join the lines,
  // but in code and in a list item's indented lines, which a break would
  // turn into an item of their own; and a line that follows a list
  // unindented and is no item a paragraph, not more of the last item.
  function written(value) {
    const item = /^\s*(?:[-*+]|\d+[.)])\s/
    const fence = /^\s{0,3}(?:```|~~~)/
    const indented = /^\s+\S/
    let text = ""
    let fenced = false
    let listed = false
    let before = null
    for (const line of String(value || "").split("\n")) {
      if (before !== null)
        text += fenced || fence.test(line) || fence.test(before) || before.trim() === "" || line.trim() === "" ? "\n"
          : listed && indented.test(line) ? "\n"
          : listed && !item.test(line) ? "\n\n"
          : "  \n"
      text += line
      if (fence.test(line))
        fenced = !fenced
      listed = !fenced && (item.test(line) || (listed && indented.test(line)))
      before = line
    }
    return text
  }

  // `value` with each web address it links or holds bare as an anchor in the
  // accent, which Markdown would draw in the system's colour, and every one of
  // them, in order; code is left as it is.
  function linked(value) {
    const links = []
    const escape = part => part.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    const anchor = (url, label) => {
      links.push(url)
      return "<a href=\"" + escape(url) + "\" style=\"color:" + Theme.primary + "\">" + label + "</a>"
    }
    const text = String(value || "").replace(/(```[\s\S]*?(?:```|$)|`[^`\n]*`)|<(https?:\/\/[^>\s]+)>|\[([^\]\n]*)\]\((https?:\/\/[^)\s]+)\)|(https?:\/\/[^\s<>`"'\[\]]+)/gi,
      (match, code, auto, label, target, bare) => {
        if (code)
          return match
        if (auto)
          return anchor(auto, escape(auto))
        if (target)
          return anchor(target, label)
        // Punctuation that ends a sentence ends the address too.
        const tail = bare.match(/[.,;:!?)'"]+$/)
        const url = tail ? bare.slice(0, -tail[0].length) : bare
        return anchor(url, escape(url)) + (tail ? tail[0] : "")
      })
    return { text: text, links: links.filter((link, at) => links.indexOf(link) === at) }
  }

  function open(link) {
    if (/^https?:\/\//i.test(link))
      Quickshell.execDetached(["xdg-open", link])
  }

  Keys.onLeftPressed: chosen = (chosen + links.length - 1) % links.length
  Keys.onRightPressed: chosen = (chosen + 1) % links.length
  Keys.onReturnPressed: open(pointed)
  Keys.onEnterPressed: open(pointed)
  Keys.onSpacePressed: open(pointed)

  HoverHandler { cursorShape: prose.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }

  FocusRing { anchors.margins: -4 }

  Hint {
    active: prose.pointed !== ""
    delay: prose.hoveredLink !== "" ? 300 : 0
    text: prose.pointed + (prose.hoveredLink === "" ? "\nenter opens it" + (prose.links.length > 1 ? "  ·  ←→ " + (prose.chosen + 1) + " of " + prose.links.length : "") : "")
  }
}
