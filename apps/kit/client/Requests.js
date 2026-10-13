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

// The decisions a request offers: its own options, then, of every request it
// gathers from below still waiting, the options named there, each with the
// parts that lead to it and the request it is of, as an escalation keeps a
// decision's options on its origin.
function choices(request, path) {
  const at = path || [];
  const own = Object.keys(request.options || {});
  const mine = own.length > 0 && (at.length === 0 || ["pending", "escalated"].includes(request.status))
    ? [{ part: at.length > 0 ? at[at.length - 1] : "", path: at, options: own, request: request }] : [];
  return Object.keys(request.origins || {})
    .reduce((all, part) => all.concat(choices(request.origins[part], at.concat([part]))), mine);
}

// The option a reply chose: its own, or the first one its parts chose.
function chosen(answer) {
  if (answer.option) return answer.option;
  const parts = Object.values(answer.parts || {}).map(part => chosen(part)).filter(option => option);
  return parts.length > 0 ? parts[0] : "";
}

// The first name a grant among a request's decisions gives, as {kind, name};
// null when none grants.
function granted(request) {
  for (const choice of choices(request))
    for (const option of choice.options)
      for (const step of choice.request.options[option])
        if (step.name === "grant") return step.args;
  return null;
}
