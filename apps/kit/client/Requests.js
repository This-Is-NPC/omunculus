.pragma library

function pending(request) { return request.status === "pending"; }
function human(participant) { return participant.kind === "human"; }
function label(participant) {
  return human(participant) ? participant.issuer + ":" + participant.subject : participant.agent;
}

// An answer with words and an option; given the part names of an escalated
// request's origins down to the request the option is of, the option goes
// there, each level carrying the words.
function answer(option, body, path) {
  const value = { body: body || option };
  if (option) value.option = option;
  return (path || []).reduceRight((inner, part) => {
    const parts = {};
    parts[part] = inner;
    return { body: value.body, parts: parts };
  }, value);
}
