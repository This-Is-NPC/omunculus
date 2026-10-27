.pragma library

// The message text a model event carries: a plain string, an OpenAI or
// Anthropic message, a Responses output, or a command model's text turn; a
// tool call alone has none.
function text(body) {
  if (typeof body === "string") return body;
  if (body === null || typeof body !== "object" || body.type === "call") return "";
  for (const key of ["content", "output"])
    if (typeof body[key] === "string") return body[key];
  for (const key of ["content", "output"])
    if (Array.isArray(body[key]))
      return body[key].map(part => typeof part.text === "string" ? part.text : text(part)).filter(part => part !== "").join("\n");
  return "";
}
