# The sales desk

The front of a web agency that builds websites for small businesses. It
answers each client in the language they write in, writes what they want and the quote, and
agrees with the builders below that a request can be built before it
promises anything. It was written by the system team's steward in a lab
project and adjusted by hand.

| Agent | Depth | Role |
|---|---|---|
| sales | 0 | the generalist: opens and forwards work, batches received questions and distributes client replies |
| seller | 1, workflow only | works the request through the workflow `sale`, talking with the client on it |

Each agent's `image` is a portrait in `images/`, 1950s photographs after Mad
Men: the generalist as the office manager who knows where everything goes,
the seller as the creative director who pitches and closes.

Each client's request is a work that goes through the stages of the
workflow `sale`: qualify, design, assess, propose, owner, build. The
pack's depth layer requires it one depth below the generalist
(`[policy.depth.1] workflows = ["sale"]`): a work the generalist opens
goes through `sale` whether it names the workflow or not, and one naming
an agent — the generalist itself included — is refused, so the generalist
never holds a work of its own. The seller runs at depth 1, and the works
it hands down start at depth 2. The
seller asks the client through requests — a choice, as accepting the price,
with named options the client gets as buttons — records progress with comments and moves it on with
the pack's tool `next_stage`, in place of `done`: it refuses the move
until the proposal artifact of the work has what the
stage asks — the client's content after qualify, an approved preview or
"not wanted" after design, the builders' answer after assess, the
client's acceptance after propose — and, after owner, until the run was
opened by the owner's approval, and after build, until a build came back
done. During build, the release's request to grant `promote` is the
client's one approval of the built site: the seller escalates it to them
with the homologation address and every page by name, only the client can
answer it, as the store refuses an agent's answer to a grant only a person
gives, and the grant reaches the release that waits on it. The address is
the one the release's request gives, copied: neither the seller nor the
generalist supplies one of its own, as the design preview's. When the
client's answer asks something the team knows and they cannot, the
generalist replies with it in text to the seller's request rather than
asking the client again, and the seller answers from the release's
request, or replies in text down to a question's origin; a permission's
origin only the person answers, as the store refuses an agent's text on
it, so the seller escalates it again with what it gives.

What reaches the client is what the desk addresses to them: the
generalist's escalations, the seller's comments on the request — its
progress and each stage's report through `next_stage` — and the decisions
routed to the client. Both agents act through tools in every reply, and
the text a model writes beside a call is its own note, which the mailbox
does not show (`docs/mailbox.md`): the generalist never speaks to the
client in it, and a comment is written to the client, in their language, or
not at all.

It expects a team below it whose front agent is `administrator` and
answers a work that begins "Assessment only, build nothing:" without
building — the dream team (`packs/dream-team`) imported one depth below
the seller:

```sh
omunculus pack --path packs/sales-desk --models team=<model>
omunculus pack --path packs/dream-team --models team=<model> \
  --auth homologation=<login>,production=<login> --depth 2
```

The client talks with it by name: `omunculus send --agent sales "…"`.

The proposal is data, not a file: one artifact per work,
`proposal-<work id>`, of kind `proposal`, whose versions are JSON
([artifacts](../../docs/tools.md#artifacts)). The seller writes it with the
pack's tool `proposal`, which lays `fields` over the latest version and keeps
the rest: business, city, audience, who decides, budget and timing, the
problem, the content, the scope's pages, features and exclusions, the design
(`state` `approved` or `waived`, and the preview's `address`), the builders'
assessment, what is pending, the timing, the next steps and the status. Types
are checked and a field the proposal does not have is refused. The status is
one of `draft`, `sent`, `accepted`, `refused` and `approved`, the last being
the owner's. What the seller writes in the fields, as every message to the
client, is in the language the client writes in.

`next_stage` and the tools read only versions the `proposal` tool wrote: a
version another tool puts under that name, with `put_artifact` or by hand,
counts for nothing, and one work's proposal never stands in for another's.
A write that builds on a version another call has since replaced is refused.

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
the next version of the document. The client receives only what the seller
attaches by reference, `attach` with `artifact` set to the document, which
hands over exactly the version named or the latest. The data artifact holds
internal fields and is not for the client: the seller attaches the document
alone. With the
design team (`packs/design-team`) below it too, a client who wants to see
the site first gets a preview in homologation, and the approved design's
`design/handoff.md` goes to the builders.

Prices: a site of 4 pages is R$ 1,500, each page beyond 4 R$ 300, and
the desk may give up to 10% off on its own. A larger discount, and the
contract with the payment and the start date once the client accepts, it
asks the owner with `ask`: the discount at stage propose, the contract
once, at stage owner, after the client accepted, as `next_stage` at
propose reminds it; approved, it sends the builders the build.

A client who answers a decision without making it — they will think the
price over and answer in a few days — has answered for now. The
generalist passes their words in text down to the seller's request, as any
answer, and the store refuses its putting the same question to them again;
the seller writes it in the proposal and calls `wait` once, with a short
message that acknowledges it and names again what they are to decide.
The request is answered and its work waits for the client's next
message, which the mailbox shows as waiting on them, and whatever they
write next the generalist forwards to it, resuming the sale at the stage
it waited in. A client who refuses — picks `refuse`, or says they will not
go ahead — has decided: the seller marks the proposal lost, with why in
their words, and calls `break` with a report that closes it, never `wait`.

The project must configure the logical `owner` request route used by discounts
and contract decisions; the harness's retry/cancel request for a client's
request whose seller stopped on it past `max_retries` goes there too,
rather than to the client. For the authenticated conversation origin:

```toml
[policy]
request_routes = [{ name = "owner", via = ["owners", "origin"] }, { via = ["parent", { kind = "agent", agent = "sales" }, "origin"] }]
```

Replace its destination with the responsible configured participant when the
owner and conversation origin differ. With the dream team below, the
release's request to grant `promote` is the client's approval of the built
site, which only a person may give; a rule before the default sends it to
the seller, who presents it to the client through the generalist, rather
than up through the builders' administrator:

```toml
{ workflow = "release", stage = "promote", via = [{ kind = "agent", agent = "seller" }, { kind = "agent", agent = "sales" }, "origin"] }
```

The client reads the proposal as a file: at stage propose, once the
price is worked out and the status is `sent`, the seller attaches the
artifact `proposal-<work id>.md` to the message that asks them to accept it, and only
then. The project must keep attachments
([config](../../docs/config.md)), or `attach` and the artifacts are refused:

```toml
[store]
attachments = ".omunculus/attachments"
attachment_bytes = 10485760
```

Each conversation is one client's. Give the project `[project]
conversations` so each works in a folder of its own, copied from the
workspace's files — the proposal template among them — when it starts
([config](../../docs/config.md#a-folder-per-conversation)):

```toml
[project]
conversations = "clients"
```

Without it every conversation shares the workspace: the builders find
another client's design and site where they build, and it reaches the
client as theirs. The eval overlays need none: each task runs in a
project of its own, which has no `[access]`, so its messages open no
conversation.

The sales-desk eval overlay declares the first two routes, the agency's all
three. Questions needing an answer use `ask`; a sender replies from known facts or escalates received origins. The depth-0 generalist answers or escalates every request under its inbox in the run that sees it, never taking one there for a question already out, since a request it left unanswered reaches the client without it; it collects every unresolved question in its conversation into one escalation to the client, written to the client as it should reach them, with no ids, stage names or notes for the team, and distributes the returned text to those origins. `break` remains a stopped-work report, and `wait` the seller's pause for the client's next message. The generalist ends on thanks, acknowledgements and promises of later material; a completed sale starts new work only for an explicit new request.
