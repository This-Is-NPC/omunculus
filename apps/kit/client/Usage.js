.pragma library

// The same arithmetic as Omunculus.Usage.sum on the server, per model call.
function tally() {
  return { calls: 0, input: 0, cached: 0, output: 0, cost: 0, priced: 0 };
}

function number(value) { return typeof value === "number" ? value : 0; }

// Adds one model call's reported usage (OpenAI or Anthropic shape) to `into`.
function add(into, usage) {
  const reported = usage || {};
  into.calls++;
  into.input += number(reported.input_tokens || reported.prompt_tokens)
    + number(reported.cache_creation_input_tokens) + number(reported.cache_read_input_tokens);
  into.cached += number(reported.cache_read_input_tokens)
    + number((reported.prompt_tokens_details || {}).cached_tokens);
  into.output += number(reported.output_tokens || reported.completion_tokens);
  if (typeof reported.cost === "number") {
    into.cost += reported.cost;
    into.priced++;
  }
  return into;
}
