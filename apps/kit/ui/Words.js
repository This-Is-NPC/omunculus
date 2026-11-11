.pragma library

// A text cut for lack of room, at a word: `elided` is `full` as the text
// element's own elision left it, cut mid-word and ended with "…". Back to the
// last space before the cut, unless the cut fell on one or a single word has
// no other; the punctuation left at the end goes with it.
function atWord(full, elided) {
  if (elided === full || elided.charAt(elided.length - 1) !== "…") return elided;
  const kept = elided.slice(0, -1);
  const clean = text => text.replace(/[\s,;:.\-–—]+$/, "") + "…";
  if (full.charAt(kept.length) === " ") return clean(kept);
  const at = kept.lastIndexOf(" ");
  return at > 0 ? clean(kept.slice(0, at)) : elided;
}
