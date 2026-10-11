# Generic requests

Specification for Omakiten plan `generic-requests`, task 3277. This document
records the current implementation and a proposed contract for approval.
The proposed contract is not implemented by this documentation commit.
Tasks 3278–3282 remain gated on the user's approval of this specification.

## Current implementation

A request already has a question (`reason`), named options containing tool
calls, a requester (`agent`, `run_id`, optional `work_id`), an arbiter, and
one of `waiting_agent`, `waiting_human` or `closed` as its status. Its opening
event and request comments hold the question. Options are immutable.

`Store.Actions.Requests` validates and resolves the arbiter. A request from
a child goes to the parent work's assignee if that agent can perform every
option's calls and grant the requested names. Explicit `to = person`,
sealed capabilities, an unsuitable parent, a root or a workless run, and
harness requests go to the human. Blocked grants and requests consisting
only of grants the requester already has are refused.

A request parks its work with `state = waiting`, `waiting = request` and
`waiting_for = request_id`. A work waiting on children cannot open a request.
`reply` requires both a named option and a nonempty comment. It chains that
option's calls, adding the request ID to their arguments. The harness records
the call, reply and effects in one store transaction. A refused chain or emit
applies none of them. An authorized human may reply; an agent must be the
recorded arbiter. The reply closes the request and reopens a work still waiting
on that request. Follow-up opens its run, or a workless requester's agent in
the original conversation. A cancelled work does not run again.

`Store.Runs.unanswered/3` currently changes an unanswered agent request's
arbiter to `human` after the arbiter's run closes. It records an `escalate`
event and an inbox note. This changes the same request in place; it creates
neither a linked request nor a route back through intermediate agents.

## Proposed request contract

A request is anything one agent needs another participant to answer before
its work can continue. Questions, decisions, permissions and release approval
share the same store actions, authorization, comments, events and reply path.
Their tools supply different question and option content.

| Component | Contract |
| --- | --- |
| Question | Nonempty text, stored as `reason` and the opening request comment. It says what is needed and why. |
| Options | An immutable map from answer names to ordered `{name, args}` calls. An empty map means a free-text question. An option with no calls is a named decision. |
| Answerer | A resolved agent arbiter and its work when applicable, or the human. Resolution follows the work's parent chain; depth alone never selects an agent. |
| Effect | A nonempty reply `body`, optionally a chosen option whose calls execute. Text alone executes no calls and confers no permission. |
| Origin | The requesting run, agent, conversation and optional work, plus workflow and stage at the moment of asking. Escalated requests retain links to their immediate origins. |

The stored origin identifies the asker even if its work later advances to
another stage or is assigned to another agent. Capture workflow and stage in
the immutable opening event, alongside the existing IDs. Do not infer the
historical stage from a work's current stage. A workless request has a run and
conversation, with no invented work or stage.

`ask` is the question/decision form: `question` is required; `options` is
optional, and when supplied names distinct answers with empty call lists.
`request_access` is the permission form: it builds the existing grant and deny
options for tools, paths, directories and sandbox resources. Both emit the
same `request` action and end the asking run. There is no second request
engine or request-kind-specific lifecycle.

`reply` takes `request_id`, a nonempty `body` and an optional `option`. An
omitted option answers with text alone, including when the request offers
options. A supplied option must exist; an invalid option must never be
silently treated as a text answer. The request view exposes the reply text
and optional selected option; `answer = nil` alone cannot distinguish an
unanswered request from a closed text answer. Comments remain the durable
text record, with the reply event identifying the answer.

Existing option calls retain their manifest chain whitelist, ceiling checks,
transactional recording and human authorization. A text answer such as
"approved" cannot execute `grant`, `cancel`, `configure`, `pack` or `promote`.
Permanent grant scopes still require a human and change the corresponding
TOML layer before dependent runs become due.

### Routing and authority

An ordinary question goes first to the parent work's agent, or to the human
when there is no parent. A receiver answers what it knows and escalates what
it cannot answer. The depth-0 agent handling the client's conversation is
the generalist for that conversation; there is no new globally hardcoded
agent named generalist.

A permission request also travels through the parent chain. An intermediate
agent can answer only with options it is authorized to execute for the
original requester. A human-only capability, including `promote` in the dream
team, still requires a human's selected grant option. Its presence does not
skip the intervening agents. An agent unable to grant it can collect the
context and escalate it. Blocked capabilities remain refusals, not escalations.

Explicit `to = person` and harness retry/cancel requests retain their human
endpoint. Owner and client describe people in the pack's question and
conversation context. The existing membership and command authorization
checks decide which human principal may answer; this plan introduces no new
owner/client identity tables or automatic claim that any client can authorize
project changes. Packs must distinguish an owner's approval from a client's
content answer. If separate owner/client principal routing is required beyond
the current access model, that needs a separately approved contract.

### States

| State | Meaning and permitted progress |
| --- | --- |
| `waiting_agent` | Its agent arbiter may reply or escalate; an authorized human may reply. |
| `waiting_human` | An authorized human may reply with text or an allowed option. |
| `escalated` | It is unresolved and linked into one upstream request. Its original work stays parked; answers return through that link. It is not offered as a second independent inbox item. |
| `closed` | One reply and its effects committed. Further replies or escalation are refused. |

Opening a normal request parks its work. Escalating an incoming request does
not break or finish the origin's work. A denial closes the request and
returns its reason; its caller decides what to do next. Selecting a cancel
option cancels the work under the existing cancellation rules.

An escalated origin returns to `waiting_agent` when its upstream answer is
available for its arbiter to distribute, or closes in the same transaction
when a validated named part answers it. An upstream text answer without named
parts closes only the upstream request; its linked origins remain unresolved
until their arbiter supplies their respective answers. No request is closed
merely because another request mentions it.

## Escalation and return

The model-facing `escalate` tool emits an `escalate` action and ends its run.
Its inputs identify one or more received request IDs and a merged question.
Each origin gets a distinct, stable part name in the new request. Escalation
creates a new request by the receiving agent, resolves its next parent arbiter
(or the human at the top), and records immutable links to the origins.

Only the current arbiter can escalate a received request. The store requires
all origins to be unresolved, addressed to that arbiter and in the same
conversation. Already escalated origins, duplicate origins, self-links,
cycles and cross-conversation merging are refused. A new request is linked
only upward through the actual parent chain, including workflow assignees.
One upstream request can itself be escalated at the next level.

The merged question contains the context needed to answer and identifies
which part belongs to which origin. It does not flatten origin option calls
into new grants on the escalating agent. Permission targets remain the
original request IDs, agents, works and scopes.

There are two ways to return an answer:

1. **Agent distribution.** The upstream reply reopens a run of the escalating
   arbiter with its answer and origin links. That agent replies to each origin
   with only its relevant text and, where authorized, an option. It can answer
   some and escalate the still-unanswered ones in a new round.
2. **Named parts.** A reply may supply `parts`, a map from the upstream
   request's part names to `{body, option?, parts?}`. Nested `parts` addresses
   the next level of linked origins. The store validates every part,
   its target and its authorization, then applies the upstream reply and those
   origin replies through the same reply implementation in one transaction.
   Unknown parts, empty bodies, invalid options or unauthorized effects refuse
   the entire call. Missing parts stay unresolved for agent distribution.
   Deliver each resulting reply once; a later distribution cannot repeat an
   option effect already committed by a named part.

A named part answers one immediate origin; nested escalation repeats this
rule at each level, recursively using explicit nested parts. An upstream
request with permission-bearing origins must expose their original options
and targets so a human can select the grant on the leaf request explicitly. Free text is never parsed by the store to guess which
answer or permission belongs to a child. A human-authorized option can be
applied to an origin through named parts with the human's identity retained
in events. An agent distributing text cannot turn that text into a human
permission or impersonate the upstream answerer.

An arbiter may receive a request while its own work waits on children.
Escalation must preserve that existing wait: it must not overwrite the
parent's `waiting_for` with the new request or require a `break` to proceed.
The upstream reply makes an arbiter run due even while that work still waits
on the original children. Replying to those children lets their ordinary work
runs resume; the parent's own work resumes when the existing child-wait rule
allows it. A workless arbiter resumes in its original conversation.

Closing an arbiter run after it explicitly escalated must not trigger today's
`unanswered` shortcut to the human. Replace that shortcut with the same linked
single-origin escalation path for an unanswered request; no parallel in-place
arbiter rewrite remains. Request and reply events remain the causes of the
runs they open. The harness schedules and applies; tools build the merged
question, filter requests and format the model's context.

A cancelled or finished origin work is never resurrected by a late answer.
Its request can retain an auditable reply, with no new work run. Concurrent
reply/escalate attempts are serialized by the store; only the first valid
transition commits, including its option effects and links.

### Example: two questions, three levels

Two depth-2 design works ask the depth-1 design lead for the client's logo
and preferred tone. The lead answers neither from guesswork. It escalates
one request to its depth-0 parent with parts `logo` and `tone`, linked to the
two origins. Both works remain waiting on their own requests.

The generalist asks the client once: "Which logo should we use, and what tone
should the site have?" The client's response answers that merged request.
The lead receives the answer, replies to the logo origin with the logo answer
and to the tone origin with the tone answer. Both works resume. Alternatively,
explicit named parts produce the same origin replies without an extra
interpretation run. Neither worker receives the other worker's answer.

## Store schema change

**The only database change in this plan is the request escalation schema
change in task 3279.** Task 3278 uses the existing options, comments and events
for free-text replies; task 3280 adds a view, not another inbox table.

Extend `requests.status` to accept `escalated`. Add one relation:

```sql
CREATE TABLE request_escalations (
  origin_id TEXT NOT NULL REFERENCES requests (id),
  escalated_id TEXT NOT NULL REFERENCES requests (id),
  part TEXT NOT NULL CHECK (part <> ''),
  event_id TEXT NOT NULL REFERENCES events (id),
  PRIMARY KEY (origin_id, escalated_id),
  CHECK (origin_id <> escalated_id),
  UNIQUE (escalated_id, part)
);
```

The composite primary key prevents duplicate links. Each upstream request
may have many origins. An origin can be escalated again after its upstream
answer returns it to `waiting_agent`; keep the earlier link as history. Only
one upstream request may own an origin at a time: validate that the origin
is `waiting_agent`, then insert its link and set it to `escalated` in one
transaction. The relation is append-only; enforce that with database triggers
like those on events. Its unique index supports reading a request's parts.
Cycle, same-conversation and arbiter checks belong in the same store action.

Keep the existing eleven tables, adding this twelfth. `requests` continues to
hold lifecycle state and options; `comments` holds question and answer text;
`events` holds origin workflow/stage, named reply parts, authorization identity
and escalation causes. `runs`, `works`, `conversations`, membership tables,
`prompts`, `inbox` and command receipts keep their existing responsibilities
and schemas. No separate answers, grants, human-role or client-inbox table is
needed, and no configuration moves into SQLite.

The schema compatibility check must reject an existing store without the new
relation and status constraint with `store_requires_recreation`. Recreate
stores explicitly; there is no migration, dual schema, silent upgrade or
fallback. This specification commit changes no database and recreates no
user or development store.

## Generalist request view

A declared view source exposes every unresolved request currently addressed
to the run's agent, grouped by conversation, with question, origin agent,
work, captured workflow/stage, allowed options and escalation parts. It
includes multiple works' requests even when only one request caused the run.
Escalated origins appear as provenance under the upstream request, not as
duplicate questions for the generalist to answer independently.

Preserve the existing conversation scope of tool hydration and membership
checks. In a conversation-scoped run the client group is that conversation;
the source must not expose other clients' conversations merely because the
agent name matches. A broader caller must already have the corresponding
read access. Grouping introduces no new permission to read across clients.

`assemble` renders this view as a section and tells the generalist to collect
the unresolved questions into one client message per round. The view and tool
do the selection and formatting. There is no new harness batching timer,
message sender, configuration default or scheduling policy. A round consists
of the pending questions visible when the agent composes its message; later
arrivals belong to the next round.

## Mapping existing paths and gaps

| Current path | Placement in the model | Current gap / required change |
| --- | --- | --- |
| `ask` | Question or decision; empty call lists for named answers. | Requires at least two options today. Allow no options and text replies through the common path; retain named decisions. |
| `request_access` | Permission form; each grant option grants the entire requested set, or deny returns text. | Already emits one request. Use the common lifecycle and escalation while retaining blocked/already-have checks and human-only permanent scopes. |
| `request_sandbox` | Sandbox permissions are `request_access` entries with `kind = resource`, e.g. `sandbox.write`. | No such builtin module or manifest exists at this commit. Older references in `docs/tools.md`, `docs/cycle.md`, `docs/cli.md`, `docs/ceiling.md` and `docs/possibilities.md` are stale. Correct those references when folding paths in; introduce no alias or second sandbox request tool. |
| `reply` → `grant` / `cancel` | A selected answer applies the origin's ordered calls transactionally. | Requires an option today. Make it optional for text, expose answer text, and apply named parts through the same authorized reply path. Keep grant/cancel chain-only. |
| Questions carried by `break`, then `reopen` | A resumable question is a request; escalation carries it upward and reply resumes it. | Design lead, designer and administrator instructions use stopping reports for missing information. Replace those question instructions with requests. Keep `break` and `reopen` for actual failed/stopped work and correction. |
| `promote` approval | A permission request for the clerk's production tool travels through administrator/seller/generalist to the responsible human. | Dream-team seals `promote` as human-only and its clerk requests it with `request_access`, which currently jumps to the human. Preserve the human grant boundary while linking every escalation. `promote` itself remains the deployment tool and publishes only after the grant; a text approval cannot run it. |
| `propose_config`, `propose_pack` | Decision requests with `apply` calling `configure` or `pack`, and `deny` calling nothing. | Keep validated proposals, revision checks and human authorization on the shared path. Free text records advice without applying a proposal. |
| Harness retry / cancel | Human decision request after root retry exhaustion. | Keep named effect options and text replies; a text-only reply reopens the requester without cancelling it. Child exhaustion remains a genuine break. |
| Unanswered arbiter run | Single-origin linked escalation. | Today it rewrites the arbiter to human in place. Remove that shortcut in favor of the common escalation path; an explicitly escalated origin must not escalate twice. |
| Seller comments and front-desk forwarding | Generalist asks the client a combined request and routes each answer back to its origin. | Sales currently forwards every message and the seller comments its own questions; it has no shared request inbox. Update pack tools, stage ceilings and instructions so questions use requests and client replies resolve them. Preserve ordinary messages and work creation. |

## Acceptance boundary

Task 3277 delivers this specification and source-grounded mapping only.
Approval is required before implementing the following checks:

- **3278:** Store, tool and HTTP/CLI contracts accept text replies to both an
  agent arbiter and the human; comments and assembled context carry the answer;
  invalid options still fail and text executes no option calls.
- **3279:** Three-level escalation merges two origins, returns each answer to
  its own work, preserves a parent's child wait and retains human authority on
  grants. Cover duplicate/closed origins, cross-conversation attempts, partial
  named answers, rollback and store recreation. Remove in-place escalation.
- **3280:** View and assemble tests show two pending requests from different
  works of one conversation together, with origin and question, without leaking
  another conversation or duplicating escalated origins.
- **3281:** Question and permission forms use the same request/reply/escalation
  implementation. Production approval climbs the chain and is granted only by
  the authorized human. Remove replaced code and stale tool references; update
  AGENTS.md and runtime docs to the behavior on that commit.
- **3282:** Update agency packs and record a passing `design-to-build` eval
  execution, its result path and measured client question messages per round.
  Questions from seller, design lead and administrator are batched into one
  client message per round and their answers resume the original works.

Before each commit, run `mise run pre-commit`, `mise run validate:regular` and
`mix compile --warnings-as-errors` in the isolated worktree. No push. Task 3277
stays in review until the user approves this document; later tasks stay in
backlog during that review.
