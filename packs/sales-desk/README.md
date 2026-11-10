# The sales desk

The front office of a web agency that builds websites for small businesses.
One agent owns each responsibility, and what one agent needs from another
goes through the one that owns the hub: the project manager.

| Agent | Depth | Role |
|---|---|---|
| front-desk | 0 | the only one that talks with the client: receives what they say, routes it, relays questions, previews, documents and the finished site in plain words |
| project-manager | 1, workflow `engagement` | the internal hub: owns the delivery plan, the stages after the sale and every internal decision; hands works to the seller and to the teams, and gathers their answers |
| seller | 2, workflow `sale` | scopes, prices and writes the proposal; asks the project manager what only the teams know |

The design team's `design-lead` and the dev team's `administrator` are
imported at depth 2 beside the seller, so they are the project manager's
children too: the seller never reaches them, and they reach each other only
through the project manager. The pack is one because the proposal, which
the seller writes and the project manager reads and completes, is one
artifact; its name stays the sales desk's.

Each agent's `image` is a portrait in `images/`, 1950s photographs after Mad
Men: the front desk as the office manager who knows where everything goes,
the seller as the creative director who pitches and closes. The project
manager has none yet.

## Who decides what

R decides and does it, C is asked, I is told. The owner is the human of the
project's console.

| | Front desk | Project manager | Seller | Design team | Dev team | Client | Owner |
|---|---|---|---|---|---|---|---|
| Talks with the client | R | | | | | | |
| Routes a new request and a client's message | R | I | | | | | |
| Qualifies, scopes and prices (the table, 10% off) | | I | R | | | C | |
| Feasibility and time estimate | | R | C | C | C | | |
| Discount beyond 10% | | C | C | | | | R |
| Accepts the proposal | | | I | | | R | |
| Approves the sale | | I | C | | | | R |
| Delivery plan and stage order | | R | | | | | |
| The preview (default), its rounds | | R | | R | | R (approves) | R (rounds beyond) |
| Waives the preview | | I | | | | R | |
| The build and its QA | | R | | | R | | |
| A blocker, a build past the maximum of reopens, a missing tool | | C | | | C | | R |
| Accepts the built site | | I | | | | R | |
| Promotes to production | | C | | | | | R |
| Handover | R (relays) | R | | | I | I | |

Every ask to the owner uses `to = "owner"`; the client is asked only
business questions, by the default route.

## How a request goes

Each client's request is a work of the workflow `engagement`, which the
pack's depth layer requires one depth below the front desk
(`[policy.depth.1] workflows = ["engagement"]`): a work the front desk opens
goes through it whether it names the workflow or not, and one naming an
agent is refused, so the front desk never holds a work of its own. Its
stages, all the project manager's:

1. `sale`: hands the seller a work of the workflow `sale`. The seller's
   stages are `qualify` (discovery, in short questions to the client),
   `estimate` (asks the project manager, with `ask` and `to = "pm"`),
   `propose` (the price from the table, accepted by the client) and
   `signoff` (asks the owner). The project manager answers the estimate
   by handing the dev team's `administrator` a work that begins
   "Assessment only, build nothing:" and, since the preview is the default,
   the design lead one the same way, then replies with what can be built,
   what blocks it and the time in days of work.
2. `design`: hands the design lead the briefing from the proposal; the
   preview's homologation address goes to the client, who approves it or
   asks changes (the design lead counts the rounds included, and more are the
   owner's). Only the client waives the preview, by answering an explicit
   question the front desk puts to them; their answer is recorded.
3. `build`: hands the administrator the build, stating the design from the
   proposal: `design/handoff.md` when it was approved, "the client waived the
   design" when it was waived, as the administrator requires. When the site is in homologation the release's
   request to grant `promote` comes to the project manager, who has the
   client accept the built site and only then escalates the request to
   the owner, who promotes.
4. `handover`: gives the client where the site is.

`next_stage` is the tool both workflows move on with. It refuses until the
stage holds, saying what is missing: after `qualify` the client's content;
after `estimate` the project manager's answer; after `propose` the client's
acceptance; after `signoff` the owner's approval; after `sale` the seller's
work done with the proposal approved; after `design` an approved preview with
its address, or a waiver with the client's own answer; after `build` a
build done and the client's acceptance of the built site; after `handover`
the production address.

What reaches the client is what the front desk addresses to them: its
escalations, and the project manager's progress comments on the request.
Every agent acts through tools in every reply, and the text a model writes
beside a call is its own note, which the mailbox does not show
([the mailbox](../../docs/mailbox.md)). A client who answers a decision
without making it, saying they will think the price over, has answered for
now: the front desk passes their words down in text, the seller records them
and breaks its work, and the project manager calls `wait`; their next
message, forwarded by the front desk, resumes the sale. A client who refuses
has decided: the seller marks the proposal `refused` and breaks, and the
project manager closes the request.

## The proposal

The proposal is data, not a file: one artifact per engagement,
`proposal-<work id>`, of kind `proposal`, the id being the project manager's
work, whose versions are JSON ([artifacts](../../docs/tools.md#artifacts)).
The seller writes it with the pack's tool `proposal`, which lays `fields`
over the latest version and keeps the rest: business, city, audience, who
decides, budget and timing, the problem, the content, the scope's pages,
features and exclusions, the project manager's `assessment`, what is
pending, the timing, the next steps and the status. The project manager
writes `design` (`state` `approved` or `waived`, the preview's `address` and,
to waive, the client's own `client_answer`) and `delivery` (the built site's
homologation `address`, the client's `accepted`, the `production` address).
Types are checked and a field the proposal does not have is refused. The
status is one of `draft`, `sent`, `accepted`, `refused` and `approved`, the
last being the owner's. What is written in the fields, as every message to
the client, is in the language the client writes in.

`next_stage` and the tools read only versions the `proposal` tool wrote: a
version another tool puts under that name, with `put_artifact` or by hand,
counts for nothing, and one engagement's proposal never stands in for
another's. A write that builds on a version another call has since replaced
is refused.

The desk's price rules live in the tool, not in the core: the price is worked
out from the scope's pages, so the seller cannot misadd it. A `discount`
(percent) past 10% is refused as the owner's decision; one given before the
pages exist is kept and applied once they do.

Each version `proposal` writes is rendered, in the same call, to the client's
document: the artifact `proposal-<work id>.md`, of kind `document`, from
`tools/_proposal/template.md` in the pack, which no run can write. Its
`{{path}}` placeholders name the data (`{{scope.pages}}`, `{{price.total}}`;
a list becomes bullets, a missing value is empty, comments are dropped). The
headings are the template's, in English; change the template in the pack to
change the document, and `render_proposal` renders the latest data again as
the next version of the document. The data artifact holds internal fields and
is not for the client. When the seller asks the client to accept the price it
ends the message with "Attach: proposal-<work id>.md"; the front desk
attaches that artifact, which hands over the latest version, and says the
document is attached.

Prices: a site of 4 pages is R$ 1,500, each page beyond 4 R$ 300, and the
seller may give up to 10% off on its own.

## What it expects below

The design team (`packs/design-team`) and the dev team (`packs/dream-team`)
imported at depth 2:

- the `administrator` takes a work whose goal begins "Assessment only, build
  nothing:" and answers it without building, and a work that asks for the
  build, ending with the release's request to grant `promote`;
- the `design-lead` takes a briefing as the goal of a work, a work that
  begins "Assessment only, build nothing:", and a later round as a work that
  names the earlier one;
- the release's request to grant `promote` reaches the project manager by
  the route below.

```sh
omunculus pack --path packs/sales-desk --models team=<model>
omunculus pack --path packs/dream-team --models team=<model> \
  --auth homologation=<login>,production=<login> --depth 2
omunculus pack --path packs/design-team --models team=<model> --depth 2
```

The client talks with it by name: `omunculus send --agent front-desk "…"`.

## What the project configures

The routes. The logical `owner` route reaches the project's owners, never
the client; `pm` is the seller's way to its parent; the release's `promote`
request goes to the project manager; the seller's questions to the client go
to the front desk, then to the conversation origin:

```toml
[policy]
default_agent = "front-desk"
request_routes = [
  { name = "owner", via = ["owners", "origin"] },
  { name = "pm", via = ["parent"] },
  { workflow = "release", stage = "promote", via = [{ kind = "agent", agent = "project-manager" }] },
  { from = { kind = "agent", agent = "seller" }, via = [{ kind = "agent", agent = "front-desk" }, "origin"] },
  { via = ["parent", { kind = "agent", agent = "front-desk" }, "origin"] },
]
```

`owners` resolves only with `[access]` and an owner member; a project
without them, as the eval configurations, falls back to the conversation's
person through `origin`. With `[access]`, a role holding `project.own` must
hold `conversation.reply` too ([requests](../../docs/requests.md#client-and-owner)).

Without attachments, `attach` and the artifacts are refused:

```toml
[store]
attachments = ".omunculus/attachments"
attachment_bytes = 10485760
```

Each conversation is one client's. Give the project `[project]
conversations` so each works in a folder of its own, copied from the
workspace's files when it starts
([config](../../docs/config.md#a-folder-per-conversation)):

```toml
[project]
conversations = "clients"
```

Without it every conversation shares the workspace: the builders find
another client's design and site where they build, and it reaches the
client as theirs. The eval overlays need none: each task runs in a project
of its own, which has no `[access]`, so its messages open no conversation.
