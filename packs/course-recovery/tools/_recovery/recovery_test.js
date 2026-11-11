import { correct, inspectCase } from "./recovery.js";
const equal = (actual, expected) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
};
const input = () => ({
  args: {
    instructions: "Sales must present the current approval request.",
    evidence_event_ids: ["origin-event"],
    client_delivery: "unverified",
  },
  view: {
    request: {
      id: "envelope",
      event_id: "origin-event",
      status: "pending",
      conversation_id: "c",
      arbiter: '{"kind":"agent","agent":"steward"}',
      origins: {
        permission: {
          id: "leaf",
          status: "escalated",
          options: '{"grant":[{"name":"grant"}]}',
        },
      },
    },
    history: [],
    events: [{
      type: "start-run",
      conversation_id: "c",
      body: '{"agent":"steward"}',
    }, {
      type: "tool",
      body: {
        name: "recovery_case",
        ok: true,
        args: { request_id: "envelope" },
      },
    }],
  },
});
Deno.test("a correction is an internal linked escalation, never a grant or client prompt", () => {
  const i = input();
  const before = JSON.stringify(i.view.request);
  const out = correct(i, "steward", "sales");
  equal(out.ok, true);
  equal(out.emit.map((e) => e.type), ["escalate"]);
  equal(out.emit[0].body.to, "sales");
  equal(out.emit[0].body.origins, { recovery: "envelope" });
  equal(JSON.stringify(i.view.request), before);
});
Deno.test("the supervisor must hold the pending canonical request", () => {
  const i = input();
  i.view.request.arbiter = '{"kind":"agent","agent":"sales"}';
  equal(correct(i, "steward", "sales").ok, false);
  i.view.request.arbiter = '{"kind":"agent","agent":"steward"}';
  i.view.request.status = "closed";
  equal(correct(i, "steward", "sales").ok, false);
});
Deno.test("cross-conversation requests, other callers and resolved origins are refused", () => {
  const i = input();
  i.view.request.conversation_id = "foreign";
  equal(correct(i, "steward", "sales").ok, false);
  equal(inspectCase(i, "sales").ok, false);
  i.view.request.conversation_id = "c";
  i.view.events[0].body = '{"agent":"sales"}';
  equal(correct(i, "steward", "sales").ok, false);
  i.view.events[0].body = '{"agent":"steward"}';
  i.view.request.origins.permission.status = "closed";
  equal(correct(i, "steward", "sales").ok, false);
});
Deno.test("evidence includes only events from the current conversation", () => {
  const i = input();
  i.view.history = [{
    conversation_id: "foreign",
    events: [{ type: "request", body: '{"reason":"secret"}' }],
  }];
  equal(JSON.parse(inspectCase(i, "sales").output).agent_claims, []);
});

Deno.test("direct CLI projects without a conversation ID retain project-local request scope", () => {
  const i = input();
  i.view.events[0].conversation_id = null;
  i.view.request.conversation_id = null;
  equal(correct(i, "steward", "sales").ok, true);
  i.view.request.conversation_id = "foreign";
  equal(correct(i, "steward", "sales").ok, false);
});

Deno.test("routing facts, agent claims and delivery receipts are separate", () => {
  const i = input();
  i.view.history = [{
    conversation_id: "c",
    agent: "sales",
    events: [
      {
        id: "claimed",
        type: "reply",
        body: { body: "The client was already asked; wait." },
      },
      {
        id: "internal",
        type: "request",
        body: { arbiter: { kind: "agent", agent: "sales" } },
      },
    ],
  }];
  const out = JSON.parse(inspectCase(i, "sales").output);
  equal(out.client_delivery.state, "unverified");
  equal(out.agent_claims[0].event_id, "claimed");
  equal(out.recorded_routing_events[0].event_id, "internal");
  equal(out.routing_map[1].parent_request_id, "envelope");
  equal(out.routing_map[1].status, "escalated");
  equal(out.evidence_scope.recent.includes("not a complete history"), true);
});

const receipt = () => ({
  id: "client",
  event_id: "delivered",
  status: "pending",
  conversation_id: "c",
  arbiter: '{"kind":"human","issuer":"local","subject":"1000"}',
  requester: '{"kind":"agent","agent":"sales"}',
  origins: { approval: { id: "leaf", status: "escalated" } },
});
const claimPending = (i) => {
  i.args.client_delivery = "pending";
  i.args.client_request_id = "client";
  i.args.client_event_id = "delivered";
};
Deno.test("unsupported pending-client claims are refused without effects and can be revised", () => {
  const i = input();
  claimPending(i);
  let out = correct(i, "steward", "sales");
  equal(out.ok, false);
  equal(out.emit, []);
  i.view.delivery = {
    ...receipt(),
    arbiter: '{"kind":"agent","agent":"sales"}',
  };
  equal(correct(i, "steward", "sales").ok, false);
  i.args.client_delivery = "unverified";
  delete i.args.client_request_id;
  delete i.args.client_event_id;
  out = correct(i, "steward", "sales");
  equal(out.ok, true);
  equal(
    out.emit[0].body.reason.includes("Client delivery is unverified"),
    true,
  );
});
Deno.test("canonical client receipts outside the recent window are accepted", () => {
  const i = input();
  claimPending(i);
  i.view.delivery = receipt();
  equal(i.view.history, []);
  equal(
    JSON.parse(inspectCase(i, "sales").output).client_delivery.state,
    "pending",
  );
  const out = correct(i, "steward", "sales");
  equal(out.ok, true);
  equal(
    out.emit[0].body.reason.includes(
      "Verified client receipt client, event delivered",
    ),
    true,
  );
  equal(out.emit[0].body.reason.includes("do not send a duplicate"), true);
});
Deno.test("closed, foreign, unrelated and non-front-desk receipts are refused", () => {
  for (
    const update of [
      { status: "closed" },
      { conversation_id: "foreign" },
      { origins: { approval: { id: "other" } } },
      { requester: '{"kind":"agent","agent":"clerk"}' },
    ]
  ) {
    const i = input();
    claimPending(i);
    i.view.delivery = { ...receipt(), ...update };
    equal(correct(i, "steward", "sales").ok, false);
  }
  const i = input();
  claimPending(i);
  i.view.delivery = receipt();
  i.args.client_event_id = "invented";
  equal(correct(i, "steward", "sales").ok, false);
});
Deno.test("corrections require a successful evidence read and canonical origin citations", () => {
  const i = input();
  i.view.events.pop();
  equal(correct(i, "steward", "sales").ok, false);
  const j = input();
  j.args.evidence_event_ids = ["invented"];
  equal(correct(j, "steward", "sales").ok, false);
  j.args.evidence_event_ids = [];
  equal(correct(j, "steward", "sales").ok, false);
});
