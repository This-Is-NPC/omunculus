# Generic requests

Specification for Omakiten plan `generic-requests`, task 3277. This document
records the current implementation and a proposed contract for approval.
The proposed contract is delivered incrementally; the current behavior is
described below.
The user authorized implementation after clarifying participant-neutral
routing, multiple requests in the existing inbox, and pause/resume semantics.
The implementation tasks record which parts of this contract are delivered.

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
`reply` requires a nonempty comment and accepts an optional named option.
Text alone chains no calls and grants nothing. A selected option chains its
calls, adding the request ID to their arguments. The harness records
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

A request is anything one participant needs another participant to answer
before proceeding. A participant may be a human or an agent, as requester,
receiver, intermediary or final answerer. Questions, decisions, permissions
and release approval share the same store actions, authorization, comments,
events and reply path. Tools and human command interfaces supply the question
and option content through that same contract.

**The requester does not need to know whether a request will pass through
humans, agents or both.** Creating a request states the need and its origin;
it does not require choosing a recipient type, naming every intermediary or
knowing the eventual answerer. A receiver sees a pending request it can answer
or escalate through the same contract. Human-to-human, human-to-agent,
agent-to-human and agent-to-agent requests are all valid compositions.

Identity and authority remain explicit internally for authentication, access
checks, effect authorization and audit. They do not select different request
protocols. Delivery activates an agent run or presents an item to a human;
that is the system's responsibility, not a distinction the requester must
manage. Human input is delivered through the command interface and requires
no synthetic agent run.

| Component | Contract |
| --- | --- |
| Question | Nonempty text, stored as `reason` and the opening request comment. It says what is needed and why. |
| Options | An immutable map from answer names to ordered `{name, args}` calls. An empty map means a free-text question. An option with no calls is a named decision. |
| Answerer | A participant resolved by the configured workflow routing, with a work when applicable. Its human or agent identity is internal authorization and delivery metadata. |
| Effect | A nonempty reply `body`, optionally a chosen option whose calls execute. Text alone executes no calls and confers no permission. |
| Origin | The authenticated requesting participant, conversation and optional run/work, plus workflow and stage at the moment of asking when applicable. Escalated requests retain links to their immediate origins. |

The stored origin identifies the asker even if its work later advances to
another stage or is assigned to another participant. Capture workflow and
stage in the immutable opening event, alongside the existing IDs. Do not
infer the historical stage from a work's current stage. A request without a
work has a conversation and participant, with no invented work or stage. A
human-origin request requires no `run_id` or agent identity: use the
verified principal, never a client-supplied claim of authorship.

`ask` is the question/decision form: `question` is required; `options` is
optional, and when supplied names distinct answers with empty call lists.
`request_access` is the permission form: it builds the existing grant and deny
options for tools, paths, directories and sandbox resources. Both emit the
same `request` action and end the asking run when invoked by a model.
Human creation uses the same store contract through authorized CLI/HTTP
commands. There is no second request engine or participant-specific lifecycle.

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

The user's TOML defines workflow routing and the participants responsible
for its decisions. The system resolves the next receiver from that routing
and the request's context. A parent-work route remains useful for agent work,
but it is not the universal route: a pipeline may place humans between
agents, agents between humans, or several participants of either kind in
sequence. Depth alone never identifies a receiver. No receiver or fallback
to a human is silently invented when routing cannot resolve one; refuse with
the missing routing context. Routing configuration remains in TOML.

A receiver answers what it knows and escalates what it cannot answer. The
requester receives its answer through the original request, independently of
how many human or agent intermediaries were involved. The generalist is a
configured responsibility for collecting a client's questions, not a new
hardcoded agent or a requirement that every pipeline ends at a human.

Permissions follow the same route. The system authorizes each selected
option for its original target using the answering participant's identity
and applicable ceiling/access rules. Existing human-only capabilities,
including `promote` in the dream team, still require an authorized human's
selected grant option. That constraint is enforced internally; it neither
requires the requester to locate a human nor skips configured intermediaries.
Text cannot substitute for a grant. Blocked capabilities remain refusals.

Owner and client are workflow responsibilities, not different request
protocols. A client's content response does not authorize an owner's release
decision unless that principal has the required authority. A human receiver
can answer, merge or escalate through the same authorized actions as an agent.
An explicit logical destination may identify a workflow responsibility when
needed; callers do not choose a transport or a human/agent branch. The current
`to = person` shortcut is replaced by configured routing rather than retained
as a required decision by the requester. Harness retry/cancel requests also
use the configured responsible participant with their existing effect checks.

### States

| State | Meaning and permitted progress |
| --- | --- |
| `pending` | Awaiting its resolved receiver, who may reply or escalate. The same state applies whether requester and receiver are humans or agents. |
| `escalated` | It is unresolved and linked into one upstream request. Its original work stays parked; answers return through that link. It is not offered as a second independent inbox item. |
| `closed` | One reply and its effects committed. Further replies or escalation are refused. |

Opening a normal request parks its work when it has one. A human requester
without a work receives updates and its answer on the request itself.
Escalating an incoming request does not break or finish the origin's work. A denial closes the request and
returns its reason; its caller decides what to do next. Selecting a cancel
option cancels the work under the existing cancellation rules.

An escalated origin returns to `pending` when its upstream answer is
available for its arbiter to distribute, or closes in the same transaction
when a validated named part answers it. An upstream text answer without named
parts closes only the upstream request; its linked origins remain unresolved
until their arbiter supplies their respective answers. No request is closed
merely because another request mentions it.

## Escalation and return

The model-facing `escalate` tool and the human CLI/HTTP command emit the same
`escalate` action; the tool ends its run. Inputs identify one or more received
request IDs and a merged question. Each origin gets a distinct, stable part
name in the new request. Escalation creates a new request by the receiving
participant, resolves its next receiver from the configured workflow route,
and records immutable links to the origins. Neither caller specifies whether
the next hop is human or agent.

Only the current arbiter can escalate a received request. The store requires
all origins to be unresolved, addressed to that arbiter and in the same
conversation. Already escalated origins, duplicate origins, self-links,
cycles and cross-conversation merging are refused. A new request is linked
along the configured escalation route, including workflow assignees and
human responsibilities. An escalation with no valid next receiver is refused
and leaves the original request pending with its receiver.
One upstream request can itself be escalated at the next level.

The merged question contains the context needed to answer and identifies
which part belongs to which origin. It does not flatten origin option calls
into new grants on the escalating participant. Permission targets remain
the original request IDs, participants, works and scopes.

There are two ways to return an answer:

1. **Receiver distribution.** The upstream reply delivers its answer and
   origin links to the escalating participant, opening a run for an agent or
   making the reply available to a human. That participant replies to each
   origin with only its relevant text and, where authorized, an option. It can answer
   some and escalate the still-unanswered ones in a new round.
2. **Named parts.** A reply may supply `parts`, a map from the upstream
   request's part names to `{body, option?, parts?}`. Nested `parts` addresses
   the next level of linked origins. The store validates every part,
   its target and its authorization, then applies the upstream reply and those
   origin replies through the same reply implementation in one transaction.
   Unknown parts, empty bodies, invalid options or unauthorized effects refuse
   the entire call. Missing parts stay unresolved for receiver distribution.
   Deliver each resulting reply once; a later distribution cannot repeat an
   option effect already committed by a named part.

A named part answers one immediate origin; nested escalation repeats this
rule at each level, recursively using explicit nested parts. An upstream
request with permission-bearing origins must expose their original options
and targets so an authorized participant can select the grant on the leaf
request explicitly. Free text is never parsed by the store to guess which
answer or permission belongs to a child. A human-authorized option can be
applied to an origin through named parts with the human's identity retained
in events. No intermediary, human or agent, can turn an upstream text answer
into another participant's permission or impersonate the upstream answerer.

An arbiter may receive a request while its own work waits on children.
Escalation must preserve that existing wait: it must not overwrite the
parent's `waiting_for` with the new request or require a `break` to proceed.
For an agent receiver, the upstream reply makes an arbiter run due even
while that work still waits on the original children. Replying to those children lets their ordinary work
runs resume; the parent's own work resumes when the existing child-wait rule
allows it. A workless agent arbiter resumes in its original conversation.
A human arbiter receives the same answer and origin links without opening a
run; a later reply uses the same authorization and state checks.

Closing an arbiter run after it explicitly escalated must not trigger today's
`unanswered` shortcut to the human. Replace that shortcut with the same linked
single-origin escalation path along the configured route for an unanswered
agent-run request; no parallel in-place arbiter rewrite remains. A pending
human request does not imply a model run or model retry policy; closing an
unrelated agent run cannot escalate it automatically. Request and reply events remain the causes of the
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

### Mixed participant edge cases

| Pipeline or event | Required behavior |
| --- | --- |
| Human → agent → human → agent | The initiating human creates one request without knowing the hop types. Each receiver answers or escalates; the answer returns through recorded origins to that human. |
| Agent → human → human | The first human may merge/escalate to the next configured responsibility. The agent sees a pending request and eventually its answer, with no human-specific procedure. |
| Human → human | Creation, partial replies, escalation and closure use the same actions; no synthetic agent or run is introduced. |
| One merged request contains agent and human origins | Merge only when the same authorized receiver and conversation apply. Return each part to its own origin, using a run or human interface internally as appropriate. |
| A content answer and a privileged approval arrive together | Authorize each selected effect against the actual answering identity and original target. Participant-neutral routing does not grant authority or turn content into approval. |
| No route exists, or a route loops | Refuse creation/escalation without mutating the origin. Do not guess a human fallback or leave a request with no responsible receiver. |
| A human and an agent try to answer the same request | The first authorized valid transition commits. Reject the later transition without repeating effects. |

## Store schema change

**The only database change in this plan is the participant-neutral request
and escalation schema revision in task 3279.** Task 3278 uses the existing
options, comments and events for free-text replies; task 3280 evolves the existing inbox, not another inbox table or source.

Within this single schema revision, replace the participant-dependent
`waiting_agent` / `waiting_human` statuses with `pending`, keeping `escalated`
and `closed`. Replace `requests.agent` with a required immutable `requester`
identity and make `arbiter` a required resolved participant identity. Store
these as JSON: an agent identity names its configured agent; a human identity
contains the authenticated issuer and subject. These identities are internal
metadata, not request arguments that let a caller impersonate a participant.
`run_id` and `work_id` remain nullable, so human requests need no invented run.
No old column or status remains as a compatibility alias.

Add one relation:

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
answer returns it to `pending`; keep the earlier link as history. Only
one upstream request may own an origin at a time: validate that the origin
is `pending`, then insert its link and set it to `escalated` in one
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
participant columns, relation and status constraint with
`store_requires_recreation`. Recreate stores explicitly; there is no
migration, dual schema, silent upgrade or fallback. This specification commit changes no database and recreates no
user or development store.

## Inbox and multiple requests

Use the existing inbox as the participant's communication entry point. It
can present multiple independent requests and other communications. Each
request remains the canonical record of its question, options, origins,
answer and lifecycle. Inbox delivery references that request; it must not
copy its state into a second source of truth or introduce a parallel inbox
source or pending-count implementation.

A receiver can answer requests individually, answer some and escalate others,
or merge several into one linked escalation. Resolving one request never
resolves unrelated requests in the same inbox. Reading an inbox communication
is distinct from answering a request: read status must not hide an unresolved
request or release the requesting work. An escalated origin remains visible
as provenance without becoming a duplicate independently actionable request.

Evolve the existing inbox view, tool and authorized API reads to include
request references, questions, origins, applicable options and escalation
parts. A model's `assemble` consumes that inbox context; a human's interface
presents the same pending requests. Neither caller needs to discover whether
any requester, intermediary or next receiver is human or agent. Reuse the
existing request detail view for the canonical request and its comments.

Preserve conversation scoping and membership checks. Requests from multiple
works of one conversation may be grouped; requests from different clients
must not be combined or exposed solely because an agent name matches. The
generalist composes one client message from the requests visible in its inbox
at that turn. Later arrivals remain pending for a subsequent round. Selection
and formatting belong to tools; there is no harness batching timer.

## Pause and resume

Opening a request through an asking tool ends the requester's current run
through its `end` chain. The work remains waiting on that specific request;
there is no model process or execution slot held while an answer is pending.
Multiple requesters can therefore have pending requests in the same inbox
without keeping their runs alive.

An authorized reply resolves its request and makes a new run due for its
requester when the work may proceed. That run receives the answer and may
continue a rebuildable session under the configured session policy. A reply
cannot revive a cancelled or finished work or resume a different requester
merely because its request shares an inbox. For human requesters, delivery
makes the answer available without inventing a model run. Escalation ends
the intermediary's model run and preserves the origins' waits until their
respective answers are returned.

## Mapping existing paths and gaps

| Current path | Placement in the model | Current gap / required change |
| --- | --- | --- |
| `ask` | Question or decision; empty call lists for named answers. | Requires at least two options today. Allow no options and text replies through the common path; retain named decisions. |
| `request_access` | Permission form; each grant option grants the entire requested set, or deny returns text. | Already emits one request. Use the common lifecycle and escalation while retaining blocked/already-have checks and human-only permanent scopes. |
| `request_sandbox` | Sandbox permissions are `request_access` entries with `kind = resource`, e.g. `sandbox.write`. | No such builtin module or manifest exists at this commit. Older references in `docs/tools.md`, `docs/cycle.md`, `docs/cli.md`, `docs/ceiling.md` and `docs/possibilities.md` are stale. Correct those references when folding paths in; introduce no alias or second sandbox request tool. |
| `reply` → `grant` / `cancel` | A selected answer applies the origin's ordered calls transactionally. | Text-only replies and optional named options share the authorized reply path. Named parts remain to be implemented. Keep grant/cancel chain-only. |
| Questions carried by `break`, then `reopen` | A resumable question is a request; escalation carries it upward and reply resumes it. | Design lead, designer and administrator instructions use stopping reports for missing information. Replace those question instructions with requests. Keep `break` and `reopen` for actual failed/stopped work and correction. |
| `promote` approval | A permission request for the clerk's production tool follows the configured decision route, regardless of intermediary type. | Dream-team seals `promote` as human-only and its clerk requests it with `request_access`, which currently jumps to the human. Preserve the human grant boundary internally while linking every escalation; the requester does not choose a human endpoint. `promote` itself remains the deployment tool and publishes only after the grant; a text approval cannot run it. |
| `propose_config`, `propose_pack` | Decision requests with `apply` calling `configure` or `pack`, and `deny` calling nothing. | Keep validated proposals, revision checks and human authorization on the shared path. Free text records advice without applying a proposal. Resolve the configured responsibility without requiring the asker to identify its participant type. |
| Harness retry / cancel | Decision request to the configured responsible participant after root retry exhaustion. | Keep named effect options and text replies; a text-only reply reopens the requester without cancelling it. Child exhaustion remains a genuine break. |
| Unanswered arbiter run | Single-origin linked escalation. | Today it rewrites the arbiter to human in place. Remove that shortcut in favor of the common escalation path; an explicitly escalated origin must not escalate twice. |
| Human-origin requests | The same request contract with an authenticated human requester and optional work, without a model run. | The current schema requires an agent requester. Replace that assumption in the single schema revision, expose authorized creation/escalation commands, and use the same delivery, reply and effect rules. |
| Seller comments and front-desk forwarding | Generalist asks the client a combined request and routes each answer back to its origin. | Sales currently forwards every message and the seller comments its own questions; it has no shared request inbox. Update pack tools, stage ceilings and instructions so questions use requests and client replies resolve them. Preserve ordinary messages and work creation. |

## Acceptance boundary

Task 3277 delivers this specification and source-grounded mapping only.
Implementation is verified by the following checks:

- **3278:** Store, tool and HTTP/CLI contracts accept text replies to both an
  agent arbiter and the human; comments and assembled context carry the answer;
  invalid options still fail and text executes no option calls.
- **3279:** Apply the single participant-neutral schema revision. Three-level
  escalation merges two origins, returns each answer to its own work, preserves a parent's child wait and retains human authority on
  grants. Cover duplicate/closed origins, cross-conversation attempts, partial
  named answers, rollback and store recreation. Exercise mixed participant
  origins and receivers, including requests with no originating run. Remove
  in-place escalation and participant-dependent waiting statuses.
- **3280:** Existing inbox view, tool/API and assemble tests show two pending
  requests from different works of one conversation together. Each references
  its canonical request with origin and question. Reading does not resolve
  requests; answering one does not resolve another. Do not leak another
  conversation, duplicate escalated origins or add a parallel pending source.
- **3281:** Question and permission forms use the same request/reply/escalation
  implementation. Production approval climbs the chain and is granted only by
  the authorized human. Remove replaced code and stale tool references; update
  AGENTS.md and runtime docs to the behavior on that commit. Human CLI/HTTP
  creation and escalation use the same actions as model tools. Verify human →
  human, human → agent → human and agent → human → agent routes without the
  requester supplying recipient types. Resolve routing from TOML and verify
  missing routes are refused without a hardcoded fallback.
- **3282:** Update agency packs and record a passing `design-to-build` eval
  execution, its result path and measured client question messages per round.
  Questions from seller, design lead and administrator are batched into one
  client message per round and their answers resume the original works.

Before each commit, run `mise run pre-commit`, `mise run validate:regular` and
`mix compile --warnings-as-errors` in the isolated worktree. No push. Task 3283 records the pause/resume contract and focused lifecycle coverage.
Work proceeds through the approved implementation tasks; record commits,
validation and review evidence on the board.
