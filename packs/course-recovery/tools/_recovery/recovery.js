const ok = (output = "", emit = []) => ({ ok: true, output, emit });
const fail = (output) => ({ ok: false, output, emit: [] });
const body = (event) =>
  typeof event.body === "string" ? JSON.parse(event.body) : event.body;
const leaves = (request) => {
  const origins = Object.values(request.origins || {});
  return origins.length ? origins.flatMap(leaves) : [request];
};
const unresolved = (request) =>
  leaves(request).filter((r) => r.status !== "closed");
const events = (input) => input.view.events || [];
const actor = (input) =>
  events(input).find((e) => e.type === "start-run")?.body;
const actorName = (input) => {
  const start = actor(input);
  return typeof start === "string" ? JSON.parse(start).agent : start?.agent;
};

function scoped(input) {
  const request = input.view.request;
  const start = events(input).find((e) => e.type === "start-run");
  if (!request || !start || request.conversation_id !== start.conversation_id) {
    return null;
  }
  return request;
}

const participant = (value) =>
  value ? (typeof value === "string" ? JSON.parse(value) : value) : null;
const nodes = (request, parent = null, origin = null) => [
  { request, parent, origin },
  ...Object.entries(request.origins || {}).flatMap(([name, child]) =>
    nodes(child, request.id, name)
  ),
];

function deliveryReceipt(input, request, frontDesk) {
  const delivery = input.view.delivery;
  const targets = unresolved(request).map((r) => r.id);
  if (
    !delivery || delivery.conversation_id !== request.conversation_id ||
    delivery.status !== "pending" ||
    participant(delivery.arbiter)?.kind !== "human" ||
    participant(delivery.requester)?.agent !== frontDesk ||
    !delivery.event_id ||
    !targets.every((id) => leaves(delivery).some((r) => r.id === id))
  ) return null;
  return {
    request_id: delivery.id,
    event_id: delivery.event_id,
    requester: participant(delivery.requester),
    recipient: participant(delivery.arbiter),
    status: delivery.status,
    original_requests: targets,
  };
}

export function inspectCase(input, frontDesk) {
  const request = scoped(input);
  if (!request) return fail("The request must belong to this conversation.");
  const records = (input.view.history || [])
    .filter((r) => r.conversation_id === request.conversation_id)
    .flatMap((r) => (r.events || []).map((e) => ({ ...e, agent: r.agent })))
    .filter((e) => ["request", "reply", "escalate"].includes(e.type))
    .map((e) => ({
      event_id: e.id,
      request_id: e.request_id,
      agent: e.agent,
      type: e.type,
      at: e.at,
      body: body(e),
    }));
  const receipt = deliveryReceipt(input, request, frontDesk);
  return ok(JSON.stringify({
    request_id: request.id,
    routing_map: nodes(request).map(({ request: r, parent, origin }) => ({
      request_id: r.id,
      event_id: r.event_id,
      parent_request_id: parent,
      origin,
      status: r.status,
      requester: participant(r.requester),
      recipient: participant(r.arbiter),
      reason: r.reason,
      workflow: r.workflow,
      stage: r.stage,
      options: participant(r.options),
      answer: r.answer,
    })),
    evidence_scope: {
      routing_map: "Complete canonical named origins of this recovery request.",
      recent:
        "Last 32 closed project runs, filtered to this conversation; not a complete history.",
      warning:
        "Escalated means linked internally, not delivered to a human. Agent replies are claims, not delivery receipts.",
    },
    recorded_routing_events: records.filter((e) => e.type !== "reply"),
    agent_claims: records.filter((e) => e.type === "reply"),
    client_delivery: receipt ? { state: "pending", receipt } : {
      state: "unverified",
      explanation:
        "No valid client delivery receipt was supplied. Do not infer a pending client question from an internal escalation or reply. This is not proof that no historical client question exists.",
    },
  }));
}

export function correct(input, supervisor, frontDesk) {
  if (actorName(input) !== supervisor) {
    return fail("Only the configured supervisor may correct course.");
  }
  const request = scoped(input);
  if (!request) return fail("The request must belong to this conversation.");
  if (!unresolved(request).length) {
    return fail("The original requests are already resolved.");
  }
  const arbiter = participant(request.arbiter);
  if (
    arbiter?.kind !== "agent" || arbiter.agent !== supervisor ||
    request.status !== "pending"
  ) {
    return fail(
      "The supervisor must hold the pending canonical recovery request.",
    );
  }
  const read = events(input).some((e) => {
    if (e.type !== "tool") return false;
    const b = body(e);
    return b.name === "recovery_case" && b.ok === true &&
      b.args?.request_id === request.id;
  });
  if (!read) {
    return fail(
      "Read recovery_case for this pending request before correcting course.",
    );
  }
  const evidence = input.args.evidence_event_ids;
  const recorded = new Set(
    nodes(request).map((n) => n.request.event_id).filter(Boolean),
  );
  if (
    !Array.isArray(evidence) || !evidence.length ||
    evidence.some((id) => !recorded.has(id))
  ) {
    return fail(
      "Cite evidence_event_ids from the canonical routing_map; invented or unrelated events are refused.",
    );
  }
  const state = input.args.client_delivery;
  if (!["unverified", "pending"].includes(state)) {
    return fail("client_delivery must be unverified or pending.");
  }
  const receipt = deliveryReceipt(input, request, frontDesk);
  if (
    state === "pending" &&
    (!receipt || input.args.client_request_id !== receipt.request_id ||
      input.args.client_event_id !== receipt.event_id)
  ) {
    return fail(
      "Client delivery is unverified. A pending claim requires a canonical pending request from the front desk to a human, linked to these original permissions, and its matching event ID. Internal escalation and agent text are not proof. Reinspect recovery_case and revise the claim; no correction was emitted.",
    );
  }
  if (
    state === "unverified" &&
    (input.args.client_request_id || input.args.client_event_id)
  ) {
    return fail(
      "Do not attach a claimed receipt to unverified delivery; inspect it and classify it accurately.",
    );
  }
  const instructions = input.args.instructions;
  if (typeof instructions !== "string" || !instructions.trim()) {
    return fail("instructions required");
  }
  const facts = state === "pending"
    ? `Verified client receipt ${receipt.request_id}, event ${receipt.event_id}. Inspect the existing request and await its actual answer; do not send a duplicate or grant permissions.`
    : "Client delivery is unverified. Inspect your current Inbox and its named origins. Validate any existing client receipt before claiming the client was asked. If there is no valid receipt, filter the business content and present the approval question with its original permission origins. An internal escalation is not client delivery.";
  return ok(
    "Evidence checked; correction escalated internally; permissions remain unresolved.",
    [{
      type: "escalate",
      body: {
        reason:
          `Internal course correction from ${supervisor}. Not a client answer or permission grant.\nRecorded origin events: ${
            evidence.join(", ")
          }.\n${facts}\nSupervisor instructions: ${instructions}`,
        origins: { recovery: request.id },
        to: frontDesk,
      },
    }],
  );
}
