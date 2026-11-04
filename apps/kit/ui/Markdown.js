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
