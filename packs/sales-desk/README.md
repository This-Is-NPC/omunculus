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
gives, and the grant reaches the release that waits on it.

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
asks the owner with `ask`; approved, it sends the builders the build.

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

The sales-desk eval overlay declares the first two routes, the agency's all
three. Questions needing an answer use `ask`; a sender replies from known facts or escalates received origins. The depth-0 generalist answers or escalates every request under its inbox in the run that sees it, never taking one there for a question already out, since a request it left unanswered reaches the client without it; it collects every unresolved question in its conversation into one escalation to the client, written to the client as it should reach them, with no ids, stage names or notes for the team, and distributes the returned text to those origins. `break` remains a stopped-work report. The generalist ends on thanks, acknowledgements and promises of later material; a completed sale starts new work only for an explicit new request.
