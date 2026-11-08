.pragma library

const item = /^ {0,3}(\d+)[.)]\s+(.*)$/;

// A question that numbers its asks as {intro, items: [{n, text}], outro}, or
// null without at least two top-level items counted 1, 2, ...; other lines
// belong to the intro or to the item above them. A line continues the item
// when no blank line precedes it or it is indented two spaces or a tab; an
// unindented line after a blank one ends the list and starts the outro.
function parse(text) {
  const intro = [];
  const items = [];
  const outro = [];
  let blank = false;
  for (const line of String(text || "").split("\n")) {
    const match = line.match(item);
    if (match && outro.length === 0 && Number(match[1]) === items.length + 1) {
      items.push({ n: items.length + 1, text: match[2] });
      blank = false;
    } else if (items.length === 0) intro.push(line);
    else if (outro.length > 0) outro.push(line);
    else if (line.trim() === "") blank = true;
    else if (blank && !/^( {2,}|\t)/.test(line)) outro.push(line);
    else {
      items[items.length - 1].text += (blank ? "\n\n" : "\n") + line;
      blank = false;
    }
  }
  if (items.length < 2) return null;
  items.forEach(each => { each.text = each.text.trim(); });
  return { intro: intro.join("\n").trim(), items: items, outro: outro.join("\n").trim() };
}

// The answers as one text reply, numbered as the items; a line break inside
// an answer is indented so it stays under its number.
function join(items, answers) {
  return items.map((each, index) => each.n + ". " + String(answers[index] || "").trim().replace(/\n/g, "\n   ")).join("\n");
}
