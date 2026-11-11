.pragma library
.import "Phrases.js" as Phrases

// What a media type is, in a word the client reads; "file" for any other.
const formats = {
  "text/markdown": "document",
  "text/plain": "text",
  "text/html": "web page",
  "application/json": "data",
  "application/pdf": "PDF"
};

// What a media type is called: "document", "data", "image", "file".
function format(mediaType) {
  const type = String(mediaType || "");
  return formats[type] || (type.startsWith("image/") ? "image" : "file");
}

// The heading of an artifact's versions: its title, its kind when that says
// more than the title or the format, and what it is: "Proposal · data".
function heading(artifact) {
  const name = Phrases.document(artifact.name);
  const versions = artifact.versions || [];
  const kind = String(artifact.kind || "");
  const what = versions.length > 0 ? format(versions[0].media_type) : "";
  const known = [name, what].map(word => word.toLowerCase());
  return [name !== "" ? name : kind, name !== "" && !known.includes(kind.toLowerCase()) ? kind : "", what]
    .filter(part => part !== "").join("  \u00b7  ");
}
