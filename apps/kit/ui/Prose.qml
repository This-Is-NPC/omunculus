import QtQuick
import Quickshell

// Prose is what an agent wrote, shown as Markdown with its web addresses as
// links in the accent: a bare address becomes one, the pointer turns over one
// and its address shows beside it, and choosing one opens it in the desktop's
// browser. With links, it is a stop of the keyboard: Left and Right pick one,
// Enter or Space opens it. Only http and https addresses open. Plain, it is
// the text as it was written, with no marks and no links.
Label {
  id: prose

  // The Markdown to show.
  property string source
  property bool plain: false
  // The link the keyboard is on.
  property int chosen: 0

  readonly property var parsed: plain ? { text: source, links: [] } : linked(source)
  readonly property var links: parsed.links
  readonly property string pointed: hoveredLink !== "" ? hoveredLink : activeFocus && links.length > 0 ? links[Math.min(chosen, links.length - 1)] : ""

  text: parsed.text
  textFormat: plain ? Text.PlainText : Text.MarkdownText
  activeFocusOnTab: links.length > 0
  onLinksChanged: chosen = 0
  onLinkActivated: link => open(link)

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
    visible: prose.pointed !== ""
    delay: prose.hoveredLink !== "" ? 300 : 0
    text: prose.pointed + (prose.hoveredLink === "" ? "\nenter opens it" + (prose.links.length > 1 ? "  ·  ←→ " + (prose.chosen + 1) + " of " + prose.links.length : "") : "")
  }
}
