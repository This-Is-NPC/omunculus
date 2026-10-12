# Requests

Questions, decisions and permissions share one lifecycle: a participant asks,
a receiver answers or escalates, and the answer returns to the original asker.

**The requester does not need to know whether the route passes through humans,
agents or both.** A request states what is needed and where it came from.
Authentication, authorization and delivery use participant identities internally;
they do not select different request protocols. Human commands have no synthetic
agent run. An agent receiving a request gets a run; a human receives the request
without one.

## Stored model

| Field | Meaning |
| --- | --- |
| `reason` | Nonempty question, kept in the opening event and request comments. |
| `options` | Immutable map from answer names to ordered tool calls. An empty map is a free-text question; an option with no calls is a named decision. |
| `requester`, `arbiter` | Authenticated participant identities: an agent name, or human issuer/subject. Clients cannot supply another participant's authorship. |
| `run_id`, `work_id` | Optional origin. A human-origin request requires no run. |
| Conversation, workflow, stage | Historical context in the immutable opening event, not inferred from the work's current stage. |
| `status` | `pending`, `escalated` or `closed`. |
| `answer` | The selected option, or nil for a text-only answer. Closed status and the reply comment distinguish a text answer from an unanswered question. |
| `origins` | Canonical linked requests keyed by escalation part names, including their questions, options and original targets. |

The store has twelve tables, including append-only `request_escalations`.
Older request schemas without participant columns or escalation links are
refused with `store_requires_recreation`; there is no compatibility schema.
Request identities and options are immutable. The canonical request view
hydrates origins recursively and is shared by tools and authorized API reads.

## Routing and authority

`[policy] request_routes` is required and nonempty. A file without it is
refused at load with `{:policy, {:invalid, :request_routes}}`; routes are parsed
once into `Config.request_routes`, including workspace overlays. For example:

```toml
[policy]
request_routes = [
  { name = "owner", via = ["origin"] },
  { via = ["parent", "origin"] },
]
```

The first rule matching the optional logical name (`to`), authenticated `from`
identity, `workflow` and `stage` supplies its ordered destinations. Unnamed
requests match unnamed rules. Workflow and stage filters refer to existing
configuration; a stage filter needs its workflow.

Destinations are `parent` (the parent work's assignee), `origin` (the authenticated
conversation creator, or the run/command origin without a conversation), or
an explicit configured agent/human identity. A named agent must be an ancestor's
assignee or a depth-0 agent able to run without a workflow. Missing contextual
destinations and participants already in the linked origins are skipped within
the configured list. If no destination resolves, the action refuses with
`{:request, :no_route}` and writes nothing. There is no implicit human fallback
or permission-based bypass. See [configuration](config.md) for identity syntax.

Routing chooses responsibility; it does not grant authority. Blocked grants and
requests containing only grants the requester already has are refused. Sealed
capabilities, including production promotion, follow the same route through
intermediaries that may not grant them. Only an authorized human's selected
option can grant a sealed capability or permanent scope, on the original target.
An agent's selected grant also requires the applicable ceiling to allow it.
Text never substitutes for a grant or impersonates an upstream answerer.

The presets, Amestris and benchmark declare parent then origin in TOML. The
sales-desk and agency eval overlays also declare the logical `owner` route
used by sales decisions. Importing that pack requires configuring this logical
responsibility; it can name a different participant from the conversation origin.

## Forms and effects

| Form | Behavior |
| --- | --- |
| `ask` | Question with optional named decision answers, each calling nothing. Omit options, or give an empty list, for a free-text answer. |
| `request_access` | One permission request for every listed tool, path, directory or sandbox resource. It comments the report on the work and offers work/permanent grant options and deny. |
| Sandbox access | `request_access` with `kind = resource`, such as `sandbox.write` or `sandbox.network`. There is no builtin `request_sandbox`, alias or separate engine. |
| `escalate` | One question linked to distinct named received origins, preserving their options and permission targets. |
| `reply` | Nonempty body, optional selected option, optional recursive named parts. Chosen option calls execute transactionally through the common chain path. |
| `grant`, `cancel` | Chain-only effects of a selected reply option, targeting the original request. |
| `break`, `reopen` | Stop failed work and return it for correction. A resumable question uses a request rather than a break/reopen round trip. |
| `promote` approval | The release agent requests permission with `request_access`; it follows the configured chain. The pack's `promote` tool publishes only once its grant makes it available. |
| `propose_config`, `propose_pack` | Validated proposals whose apply option calls configure or pack with revision checks. A text reply records advice without applying the proposal. |
| Harness retry/cancel | A routed request after root retry exhaustion. Retry is a named decision with no calls; cancel chains cancellation. Child retry exhaustion remains a stopping break. |
| Unanswered receiver | Linked single-origin escalation through the same action and routing; an upstream human request gets an inbox notification. |

Optional `to` on ask, request_access or escalate names a configured logical
route. It is not a recipient type, and callers can omit it. Receivers answer
what they know and escalate what they cannot answer.

A decision is answered by selecting its option. A workflow stage requiring
`option == approve` advances on that decision; a text-only "approved" does
not record it. After root exhaustion, retry remains an explicit choice in the
notification and reply event. Retry and text replies reuse the common reopen
path; there is no separate retry effect implementation.

The reply tool drops null or empty option values from model/CLI arguments.
HTTP clients must omit option for a text answer; explicit null/empty values
are refused with 400. An unknown nonempty option is refused. A text-only reply
chains no calls, grants nothing and applies no configuration or deployment.

## Escalation and return

The store accepts escalation only for received pending origins addressed to
the escalating participant in the same conversation. Duplicate origins,
invalid part names, already escalated requests, cross-conversation merges and
routes back into linked requesters are refused. Creation of the upstream
request and immutable links is one transaction. Original work waits remain
on their own requests. Escalation preserves the intermediary's child wait.

An upstream request may itself be escalated. Its reply can return answers in
two ways:

- **Receiver distribution:** text closes the upstream question and resumes
  its intermediary. The linked origins become pending for that intermediary
  to answer or escalate again, each with its own relevant content.
- **Named parts:** a reply supplies `parts`, keyed by the immediate origin
  names, each with body, optional option and optional nested parts. Validation
  and authorization use the original targets and actual answerer. Replies and
  selected effects commit through the same reply action in one transaction.
  Unknown parts, empty bodies, invalid options or unauthorized effects refuse
  the entire call. Omitted parts remain unresolved for distribution.

Text is never parsed into grant selections or guessed child answers. A named
part can select a leaf grant with the human answerer's identity retained;
an intermediary cannot turn an upstream text answer into that grant. Already
answered origins cannot execute an effect again through later distribution.

For example, two design works ask their lead for logo and tone. The lead
merges them as logo/tone parts and escalates to its parent. The generalist can
ask once and return the combined text for distribution, or reply with named
parts to close each origin directly. Each worker receives its own answer.
Later arrivals remain pending for a later turn; no batching timer runs in the
harness.

## Inbox, pause and resume

The existing `inbox` view with `relation = received` is anchored to the current
run. At depth 0 it returns one group for that run's conversation, containing
all pending requests addressed to that agent there. Client means conversation;
matching an agent name alone never exposes another conversation. Closed
requests and escalated origins are not independent actionable entries.

The builtin assemble renders that group under `## Inbox`, with questions,
requesters, original works, historical workflow/stage and linked origins, both
on a fresh run and in a continued session's news. The triggering request appears
once, retaining its comments. Without a conversation inbox it stays under
`## Request`. Notification comments can join the inbox section. The default
inbox relation still reads unread notifications. Reading either view or marking
a notification read does not resolve a request. Human clients read the same
canonical requests through scoped conversation resources and snapshots.

Model asking tools end the current run through their end step. No model process
or execution slot is held while the work waits on its specific request. A human
command has no run, so that step emits nothing. Several independent works can
therefore leave requests pending in the same conversation.

A reply closes its request and reopens a work still waiting on that request.
Follow-up makes its next run due, or resumes a workless agent requester in the
original conversation. An upstream reply resumes an intermediary for distribution
even while it waits on children. A human requester receives the answer without
a run. Cancelled or finished work is never resurrected by a late answer.
Concurrent reply/escalate actions are serialized; only the first valid transition
commits. An explicitly escalated origin is not automatically escalated again
when its receiving run ends.

## Human commands and mixed participants

The CLI and HTTP use the same ask/escalate tools and store actions:

```sh
omunculus ask --conversation_id <id> --question "Which deadline?"
omunculus ask --conversation_id <id> --question "Approve?" --options '["approve","deny"]'
omunculus escalate --reason "Please answer both" --origins '{"logo":"<id>","tone":"<id>"}'
```

Creation needs send access to an existing conversation; escalation needs reply
access and matching received origins. Commands derive authorship from the
verified principal. The HTTP conversation requests endpoint creates questions;
its `/escalate` endpoint escalates them. Both require Idempotency-Key and return
a command receipt. Replays reuse it; a changed body conflicts. Invalid fields,
hidden/cross-conversation resources and domain refusals retain explicit 400,
404 and 422 responses. See [CLI](cli.md) and [HTTP](server.md).

| Composition or event | Result |
| --- | --- |
| Human → agent → human → agent | Each configured receiver answers or escalates through the same actions; the answer returns through the recorded links. |
| Agent → human → human | Human intermediaries can merge and escalate without synthetic runs. The agent remains paused until its original request is answered. |
| Human → human | Authenticated creation, escalation and reply use the same lifecycle without model execution. |
| Mixed human and agent origins | Merge only for the same receiver and conversation. Return each part to its original participant. |
| Approval text without an option | It records content and resumes the requester; it grants nothing and records no named decision. |
| Partial upstream answer | Only supplied valid parts close their origins. Missing parts return to pending for distribution. |
| Late or concurrent answer | Completed/cancelled work stays so; serialized transitions prevent duplicate effects. |
| Several clients at one generalist | Each run sees its own conversation group. Cross-client merging is refused. |
