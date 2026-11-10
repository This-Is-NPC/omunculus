.pragma library

// The calls a model event asks for, as [{name, args}]: an Anthropic message's
// tool uses, an OpenAI message's tool calls, a Responses output's function
// calls, or a command model's call; code mode's script is "code".
function calls(body) {
  if (body === null || typeof body !== "object") return [];
  const given = value => {
    if (typeof value !== "string") return value && typeof value === "object" ? value : {};
    try { const parsed = JSON.parse(value); return parsed && typeof parsed === "object" ? parsed : {}; } catch (error) { return {}; }
  };
  const asked = body.type === "call" ? [{ name: body.name, args: given(body.args) }]
    : Array.isArray(body.content) ? body.content.filter(part => part.type === "tool_use").map(part => ({ name: part.name, args: given(part.input) }))
    : Array.isArray(body.tool_calls) ? body.tool_calls.map(call => ({ name: call.function ? call.function.name : "", args: given(call.function && call.function.arguments) }))
    : Array.isArray(body.output) ? body.output.filter(part => part.type === "function_call").map(part => ({ name: part.name, args: given(part.arguments) }))
    : [];
  return asked.filter(call => !!call.name).map(call => ({ name: call.name === "__omunculus_execute" ? "code" : call.name, args: call.args }));
}

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
