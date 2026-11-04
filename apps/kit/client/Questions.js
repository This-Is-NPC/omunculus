.pragma library

const item = /^ {0,3}(\d+)[.)]\s+(.*)$/;

// A question that numbers its asks as {intro, items: [{n, text}]}, or null
// without at least two top-level items counted 1, 2, ...; other lines belong
// to the intro or to the item above them.
function parse(text) {
  const intro = [];
  const items = [];
  for (const line of String(text || "").split("\n")) {
    const match = line.match(item);
    if (match && Number(match[1]) === items.length + 1) items.push({ n: items.length + 1, text: match[2] });
    else if (items.length > 0) items[items.length - 1].text += "\n" + line;
    else intro.push(line);
  }
  if (items.length < 2) return null;
  items.forEach(each => { each.text = each.text.trim(); });
  return { intro: intro.join("\n").trim(), items: items };
}

// The answers as one text reply, numbered as the items; a line break inside
// an answer is indented so it stays under its number.
function join(items, answers) {
  return items.map((each, index) => each.n + ". " + String(answers[index] || "").trim().replace(/\n/g, "\n   ")).join("\n");
}
