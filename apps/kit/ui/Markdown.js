.pragma library

// The Markdown Prose draws. Qt fetches the URL of a Markdown image while it
// lays the text out, so what an agent wrote never reaches Text.MarkdownText
// with one: images become their alt text.

// The alt text of an HTML <img> tag, or "" when it has none.
function alt(tag) {
  const found = tag.match(/\balt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
  return found ? found[1] || found[2] || found[3] || "" : ""
}

// `text` outside code: inline and reference images, and <img> tags, replaced
// by their alt text.
function prose(text) {
  return text
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/!\[([^\]]*)\]\[[^\]]*\]/g, "$1")
    .replace(/<img\b[^>]*>?/gi, alt)
}

// `text` with no image Qt would load. Images outside code become their alt
// text; then every `![` left, in code or not, gets a zero-width space after
// its `!`, so no image opens whatever Qt takes for code or for an escape.
function imageless(text) {
  return text.split(/(```[\s\S]*?(?:```|$)|`[^`\n]*`)/)
    .map((part, i) => i % 2 ? part : prose(part))
    .join("")
    .replace(/!\[/g, "!​[")
}

// `address` with a zero-width space after each "/", ".", "-", "_", "?", "=" and "&"
// (not between slashes), where a line may break, so a long address wraps at
// its parts and not inside one.
const breakable = address => address.replace(/([\/.\-_?=&])(?!\/)/g, "$1\u200b")

const escapeHtml = part => part.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")

// `value` with each web or e-mail address it links or holds bare as an
// anchor in `ink`, which Markdown would draw in the system's colour, and
// every one of them, in order. An inline code span gets the background
// `tint`; code is never linked. A name with an @ that is no address
// ("node@22.23.3") has its @ escaped, so Markdown links it no more than we do.
function linked(value, ink, tint) {
  const links = []
  const anchor = (url, label) => {
    links.push(url)
    return "<a href=\"" + escapeHtml(url) + "\" style=\"color:" + ink + "\">" + label + "</a>"
  }
  const text = String(value || "").replace(/(```[\s\S]*?(?:```|$))|`([^`\n]*)`|<(https?:\/\/[^>\s]+)>|\[([^\]\n]*)\]\((https?:\/\/[^)\s]+)\)|(https?:\/\/[^\s<>`"'\[\]]+)|([A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)*\.[A-Za-z]{2,})(?![\w.-]*\d)|(\w[\w.%+-]*@[^\s<>`()"'\[\]]+)/gi,
    (match, fence, code, auto, label, target, bare, mail, at) => {
      if (fence)
        return match
      if (code !== undefined)
        return "<span style=\"background-color:" + tint + "\">" + escapeHtml(code).replace(/[\\*_\[\]!~#|@]/g, c => "&#" + c.charCodeAt(0) + ";") + "</span>"
      if (mail)
        return anchor("mailto:" + mail, escapeHtml(breakable(mail)))
      if (at)
        return at.replace(/@/g, "&#64;")
      if (auto)
        return anchor(auto, escapeHtml(breakable(auto)))
      if (target)
        return anchor(target, label)
      // Punctuation that ends a sentence ends the address too.
      const tail = bare.match(/[.,;:!?)'"]+$/)
      const url = tail ? bare.slice(0, -tail[0].length) : bare
      return anchor(url, escapeHtml(breakable(url))) + (tail ? tail[0] : "")
    })
  return { text: text, links: links.filter((link, at) => links.indexOf(link) === at) }
}

// `text` with its inline marks removed: code ticks, bold and italic marks,
// and links down to their label.
function plain(text) {
  return String(text || "")
    .replace(/\[([^\]\n]*)\]\([^)\s]*\)/g, "$1")
    .replace(/`([^`\n]*)`/g, "$1")
    .replace(/(\*\*|__)(?=\S)([^\n]*?\S)\1/g, "$2")
    .replace(/(^|[\s(])([*_])(?=\S)([^*_\n]*?\S)\2(?=[\s).,:;!?]|$)/g, "$1$3")
}
