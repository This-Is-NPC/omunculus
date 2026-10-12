.pragma library

function pending(request) { return request.status === "pending"; }
function human(participant) { return participant.kind === "human"; }
function label(participant) {
  return human(participant) ? participant.issuer + ":" + participant.subject : participant.agent;
}

function answer(option, body) {
  const value = { body: body || option };
  if (option) value.option = option;
  return value;
}
