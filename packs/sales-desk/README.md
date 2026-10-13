# The sales desk

The front of a web agency that builds websites for small businesses. It
answers clients in Portuguese, writes what they want and the quote, and
agrees with the builders below that a request can be built before it
promises anything. It was written by the system team's steward in a lab
project and adjusted by hand.

| Agent | Depth | Role |
|---|---|---|
| sales | 0 | the generalist: opens and forwards work, batches received questions and distributes client replies |
| seller | 0, workflow only | works the request through the workflow `sale`, talking with the client on it |

Each agent's `image` is a portrait in `images/`, 1950s photographs after Mad
Men: the generalist as the office manager who knows where everything goes,
the seller as the creative director who pitches and closes.

Each client's request is a work that goes through the stages of the
workflow `sale`: qualify, design, assess, propose, owner, build. The
seller asks the client through requests — a choice, as accepting the price,
with named options the client gets as buttons — records progress with comments and moves it on with
the pack's tool `next_stage`, in place of `done`: it refuses the move
until the proposal in `quotes/` that names the work has what the
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
client in it, and a comment is written to the client, in Portuguese, or not
at all.

It expects a team below it whose front agent is `administrator` and
answers a work that begins "Assessment only, build nothing:" without
building — the dream team (`packs/dream-team`) imported one depth down:

```sh
omunculus pack --path packs/sales-desk --models team=<model>
omunculus pack --path packs/dream-team --models team=<model> \
  --auth homologation=<login>,production=<login> --depth 1
```

The client talks with it by name: `omunculus send --agent sales "…"`.

The proposal follows `workspace/templates/proposal.md`, from the
client's problem in their words to the next steps; change the template
in the project to change the proposal, keeping the parts the stages
check. With the
design team (`packs/design-team`) below it too, a client who wants to see
the site first gets a preview in homologation, and the approved design's
`design/handoff.md` goes to the builders.

Prices: a site of 4 pages is R$ 1.500, each page beyond 4 R$ 300, and
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
it waited in. A client who refuses — picks `recusar`, or says they will not
go ahead — has decided: the seller marks the proposal lost, with why in
their words, and calls `break` with a report that closes it, never `wait`.

The project must configure the logical `owner` request route used by discounts
and contract decisions. For the authenticated conversation origin:

```toml
[policy]
request_routes = [{ name = "owner", via = ["origin"] }, { via = ["parent", { kind = "agent", agent = "sales" }, "origin"] }]
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

Each conversation is one client's. Give the project `[project]
conversations` so each works in a folder of its own, copied from the
workspace's files — the proposal template among them — when it starts
([config](../../docs/config.md#a-folder-per-conversation)):

```toml
[project]
conversations = "clients"
```

Without it every conversation shares the workspace: a seller listing
`quotes/` reads the proposals of earlier clients, and the builders find
another client's design and site where they build, and it reaches the
client as theirs. The eval overlays need none: each task runs in a
project of its own, which has no `[access]`, so its messages open no
conversation.

The sales-desk eval overlay declares the first two routes, the agency's all
three. Questions needing an answer use `ask`; a sender replies from known facts or escalates received origins. The depth-0 generalist answers or escalates every request under its inbox in the run that sees it, never taking one there for a question already out, since a request it left unanswered reaches the client without it; it collects every unresolved question in its conversation into one escalation to the client, written to the client as it should reach them, with no ids, stage names or notes for the team, and distributes the returned text to those origins. `break` remains a stopped-work report, and `wait` the seller's pause for the client's next message. The generalist ends on thanks, acknowledgements and promises of later material; a completed sale starts new work only for an explicit new request.
