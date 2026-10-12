.pragma library

function pending(request) { return request.status === "pending"; }
function human(participant) { return participant.kind === "human"; }
function label(participant) {
  return human(participant) ? participant.issuer + ":" + participant.subject : participant.agent;
}
