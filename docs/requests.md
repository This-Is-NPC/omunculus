# Requests

Questions, decisions and permissions share one lifecycle: a participant asks,
a receiver answers or escalates, and the answer returns to the original asker.

**The requester does not need to know whether the arbiter is a human or an
agent.** A request states what is needed and where it came from.
Authentication, authorization and delivery use participant identities internally;
they do not select different request protocols. Human commands have no synthetic
agent run. An agent receiving a request gets a run; a human receives the request
without one.

## Stored model

| Field | Meaning |
| --- | --- |
| `reason` | Nonempty question, kept in the opening event and request comments. It is shown to the receiver as written, so `ask` and `escalate` describe it as what the receiver is asked, in their language, without ids, stage names or notes for agents; the origins carry who asked and for which work. |
| `options` | Immutable map from answer names to ordered tool calls. An empty map is a free-text question; an option with no calls is a named decision. |
| `requester`, `arbiter` | Authenticated participant identities: an agent name, or human issuer/subject. Clients cannot supply another participant's authorship. |
| `run_id`, `work_id` | Optional origin. A human-origin request requires no run. |
| Conversation, workflow, stage | Historical context in the immutable opening event, not inferred from the work's current stage. |
| `status` | `pending`, `escalated` or `closed`. |
| `answer` | The selected option, or nil for a text-only answer. Closed status and the reply comment distinguish a text answer from an unanswered question. |
| `origins` | Canonical linked requests keyed by escalation part names, including their questions, options and original targets. |

The store has twelve tables, including append-only `request_escalations`.
A store whose tables differ from that schema, or that lacks one of them, is
refused with `store_requires_recreation`; there is no compatibility schema.
Request identities and options are immutable. The canonical request view
hydrates origins recursively and is shared by tools and authorized API reads.

## Who a request goes to

An account is an identity: `{ kind = "agent", agent = "<name>" }` or
`{ kind = "human", issuer = "<issuer>", subject = "<subject>" }`. Agents and
humans ask, answer and grant through the same requests; no action is
reserved for one kind. `[accounts]` names accounts, and the names are the
project's own ([the TOML](config.md#accounts)):

```toml
[accounts]
owner = { kind = "human", issuer = "local", subject = "1000" }
```

A request without `to` goes to the account that gave the asker its work:

- below another work, the assignee of the asker's parent work;
- for a root work, the account that opened the conversation, the requester.

`ask`, `request_access` and `escalate` all follow that rule, and so do the
requests the harness raises: a root work stopped past `max_retries`, a
`reopen` past `max_reopens`, `propose_config` and `propose_pack`.

`to` names an `[accounts]` name or an agent name. An unknown name is refused,
listing what `to` takes, and nothing is written. An account is reached as it
is declared; an agent must be one of the work's ancestors' assignees, or an
agent of depth 0 that is not `workflow_only` and can run without a work. A
request to oneself is refused. If the rule finds nobody (a parent work with no
assignee, or an arbiter already excluded as below), the action refuses with
`{:request, :no_route}` and writes nothing. There is no implicit fallback.

Each request exposes its `requester` and its `arbiter`, the accounts it came
from and goes to. Nothing else about how it was addressed is stored.
Interceptors, which turn an action into a request to a reviewing account, are
described under [Interception](#interception).

Addressing chooses responsibility; it does not grant authority. Blocked
grants and requests containing only grants the requester already has are
refused. Sealed capabilities, including production promotion, climb through
intermediaries that may not grant them. Only an authorized human's selected
option can grant a sealed capability or permanent scope, on the original
target. An agent's selected grant also requires the applicable ceiling to
allow it. Text never substitutes for a grant or impersonates an upstream
answerer.

An account answers a request only as its arbiter: the principal's issuer and
subject, or the agent's name, must equal the arbiter's, else the reply is
refused with `not_arbiter`. Answers returned through named parts of an
upstream request are checked on that upstream request. The apply option of a
`propose_config` or `propose_pack` request needs the answerer to hold
`project.manage_config` to take effect.

When the harness stops a root work past `max_retries` and nobody can receive
the request, no request is made: an inbox note, once, says so.

An escalation is an ask to the escalator's own parent, by the same rule,
carrying the origins and their parts. The escalator's `to` overrides it. A
request never goes to its requesters or to the participants already in the
linked origins, and an origin never goes again to an agent that answered it
with text alone (see below).

## Interception

`[[interceptors]]` ([config](config.md#interceptors)) hold an action of an
agent until an account reviews it. Nothing is hidden: the harness does not
perform the action, and writes a request instead.

An action is held when it matches a rule, before it is performed:

| `action` | What is held | `to` matches |
| --- | --- | --- |
| `ask` | A `request` (`ask`, `request_access`), once its arbiter is resolved. Escalations and requests the harness raises are not held. | The request's arbiter. |
| `comment` | A comment on a work, request or inbox note. | On the root work, the requester; on another work, its assignee; on a request, its arbiter. |
| `attach` | An attachment. | The requester. |
| `grant` | A `grant` reply, or a `reopen` that gives names. | The agent that receives the grant. |
| `tool` | The execution of the tool named by `tool`, before it runs, as a model call or as a step of a chain. | A tool has no target. |

The harness then opens a request from the acting account to the first
reviewer. Its reason says what would be done in a sentence, quoting the text,
for example `seller wants to ask test:client: "Can we ship on Friday?"`. A
tool reads `seller wants to run promote`, followed by one `name: value` line
per argument. Its options are
`approve`, `edit` and `deny`. The acting run waits on it as on any request it
raised: the work waits on the request, and an agent reviewer finds it in its
inbox like any other. The model that made the call is told it is not done yet
and who reviews it. A reviewer who is the acting agent itself is left out; a
rule with no other reviewer does not apply.

A review request has an `interception` in the API: `action`, the `summary` sentence
of what would be done, its `target` (who the action reaches, or null), `args`
(a list of `{name, value}` lines: a tool's arguments, strings as they are, a
nested value flattened one level; empty for other actions, whose text is in
the summary), `files` (a list of `{name, bytes}`: the attachments of a held
attach, or the artifact a held `put_artifact` writes; empty for other
actions), `level` (the depth of the actor's work) and `under` (the `agent` and
`title` of the work above it, or null at level 0), `step` and `of` for its
place among the reviewers. Its
`requester` is the actor and its `options` are the three above. The reply
must name one:

| Option | Effect |
| --- | --- |
| `approve` | The action is performed as the actor, as written. |
| `edit` | The action is performed with the reply's body in place of its text: a question's reason, a comment's body, an attachment's note. A tool or a grant has no text: `edit` approves, and the body is a note. |
| `deny` | Nothing is performed. The reply goes back to the actor as the answer to its request. |

An approval writes a `release` event. A comment, question, attachment or
grant is then performed at once as the original actor: the events it writes
are authored by that agent and carry `released_by`, the id of the review
request that released them. These need no run, only the store.

A released tool needs the actor's run, so the reply does not run it. The
reply opens the actor's next run on the review, and that run calls the tool
first, before the model: the same agent, work, workspace roots, sandbox,
environment and read, write and variables policy as any call of that run.
The ceiling is not asked again, since the agent had the tool when it called
it. The tool's event carries `released_by`, and its output, a success or a
failure, opens what the model reads in that run, as the outcome of its held
call. It runs once; a failure is shown to the agent, which decides, and a
new review opens only if it calls the tool again. When the work is no longer
open, no run opens and the tool does not run. A released action is not held
again by the rule that held it, but may match another rule, which opens its
own review.

With several `accounts`, the reviewers answer one after another. An approval
or an edit that is not the last opens a new review request to the next
reviewer, written from the actor, whose reason shows the action as the
previous reviewer left it; the actor keeps waiting, now on that request. The
action is performed when the last one approves. A `deny` at any reviewer
stops it, and that reply is the actor's answer.

The ceiling is unchanged. A `grant` is an action like another, so a rule can
hold it; who may grant a sealed name or a permanent scope stays with the
capabilities, as in [Forms and effects](#forms-and-effects).

## Forms and effects

| Form | Behavior |
| --- | --- |
| `ask` | Question with optional named decision answers, each calling nothing. Omit options, or give an empty list, for a free-text answer. |
| `request_access` | One permission request for every listed tool, path, directory or sandbox resource. It comments the report on the work and offers work/permanent grant options and deny. |
| Sandbox access | `request_access` with `kind = resource`, such as `sandbox.write` or `sandbox.network`. There is no builtin `request_sandbox`, alias or separate engine. |
| `escalate` | One question linked to distinct named received origins, preserving their options and permission targets. |
| `reply` | Nonempty body, optional selected option, optional recursive named parts. Chosen option calls execute transactionally through the common chain path. |
| `grant`, `cancel` | Chain-only effects of a selected reply option, targeting the original request. |
| `break`, `reopen`, `retire` | Stop failed work, return it for correction, or retire it when the parent no longer wants it. A resumable question uses a request rather than a break/reopen round trip. |
| `wait` | A root work that only the person can move on later — a decision they will think over, something they will send — waits for their next message rather than asking again: their answer stays the answer, and the message reopens the work. A work below another cannot wait on a message. |
| `promote` approval | The release's clerk calls `promote`, a tool of its own; the project declares an interceptor on it, and the review is the approval. Without an interceptor nothing holds the call. |
| `propose_config`, `propose_pack` | Validated proposals whose apply option calls configure or pack with revision checks, to whoever gave the agent its work. A text reply records advice without applying the proposal. |

A `propose_config` change is a patch over the file's item: the keys it gives
replace the file's (a list whole, a nested table key by key), a key given as
`null` is removed, and a key it leaves out stays; `null` as the value removes
the item. The request shows the item as the config runs it, with its pack's
keys, layers and overrides, now and as it would run, and the runs the agent
cited, each checked against the project's recent runs. It is refused before it
reaches the person when it cites a run that does not exist, changes nothing, or
equals a change the person already denied in the conversation; the agent is
told what they replied. A run without a work is told, under `## Answered`, each
request its agent raised in its conversation that was answered, with the option
picked and the reply.
| Harness retry/cancel | A request to the account that opened the conversation after root retry exhaustion. Retry is a named decision with no calls; cancel chains cancellation. Child retry exhaustion remains a stopping break. |
| Unanswered receiver | Not when the run opened child works (`delegate`, `work`) that are still open or waiting, or raised a request of its own (`ask`, `request_access`, `escalate` of something else) that is still pending: the receiver waits on them to answer, and the request stays pending with it. When the raised request is answered, the receiver's work is reopened and its run sees the received request in its inbox. When the last of those children closes, the receiver's work is reopened even if other children of it (the asker's work) are still open, and its run sees the results and the request; if that run ends without answering, this rule applies again. Otherwise, linked escalation through the same action and routing, of the request the run was opened for or, for an intermediary resumed by a text answer, of the origins the answer returned to it; an upstream human request gets an inbox notification. When nobody is left to ask (the parent is excluded, see below), nothing is escalated: the request stays pending and an inbox note, once, names the question and says nobody is left to ask. An origin never goes again to an agent that answered it with text without escalating it (see below). |

An agent's run opened by the answer to its own question — a reply to its
request, or an upstream answer resuming an intermediary — does not put that
question again: a `request` or `escalate` whose reason is the answered
request's, whitespace aside, is refused with `asked_again`, whether the answer
decided or only said that a decision comes later. The run goes on from the
answer: it passes it on with `reply` to the requests it answers, and a root
work that only its person can move on later waits for them with `wait`.

Optional `to` on ask, request_access or escalate names an account or an agent, and
callers can omit it. Receivers answer
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
escalations back into linked requesters are refused. Creation of the upstream
request and immutable links is one transaction. Original work waits remain
on their own requests. Escalation preserves the intermediary's child wait.

A work waiting on its children may raise a request too (`ask`,
`request_access`), for instance to answer one it received: the work keeps
waiting on its children, and the request is pending beside that wait, so
the request received stays pending with its receiver (the run that asked
is not an unanswered receiver). The answer runs the work's agent by name,
with the answer and the inbox; the work reopens only when its children
close, or on a message.

An origin is never escalated, explicitly or automatically, to an agent it was
already escalated to that answered with text alone, naming no part, without
escalating it further (a person is never skipped for that). A reply that
answers some named parts leaves the others for another round with the same
arbiter. A text answer like that returns the
origin to its intermediary, which cannot raise it to the same parent again, so
an unresolved permission cannot circle between the same agents. An agent that
escalated the origin upward and then relayed the upstream text down stays
eligible. When nobody is left, the escalation is refused with
`no_route`; the automatic one of an unanswered request then records an inbox
note (once) and leaves the request pending.

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
merges them as logo/tone parts and escalates to its parent. The front desk can
ask once and return the combined text for distribution, or reply with named
parts to close each origin directly. Each worker receives its own answer.
Later arrivals remain pending for a later turn; no batching timer runs in the
harness.

## Inbox, pause and resume

The existing `inbox` view with `relation = received` is anchored to the current
run. At depth 0 it returns one group for that run's conversation, containing
all pending requests addressed to that agent there. At any depth it also
returns the pending requests addressed to that agent whose run opens on the
run's work or a work below it, other than the request that opened the run, so a run woken to answer a request an earlier
run received sees it and can `reply`. Client means conversation;
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
| Several clients at one front desk | Each run sees its own conversation group. Cross-client merging is refused. |
