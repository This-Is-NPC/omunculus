# The sales desk

The front of a web agency that builds websites for small businesses. It
answers clients in Portuguese, writes what they want and the quote, and
agrees with the builders below that a request can be built before it
promises anything. It was written by the system team's steward in a lab
project and adjusted by hand.

| Agent | Depth | Role |
|---|---|---|
| sales | 0 | the front desk: opens each client's request as a work, and forwards to it what they say |
| seller | 0, workflow only | works the request through the workflow `sale`, talking with the client on it |

Each client's request is a work that goes through the stages of the
workflow `sale`: qualify, design, assess, propose, owner, build. The
seller answers the client with comments on the work and moves it on with
the pack's tool `next_stage`, in place of `done`: it refuses the move
until the proposal in `quotes/` that names the work has what the
stage asks — the client's content after qualify, an approved preview or
"not wanted" after design, the builders' answer after assess, the
client's acceptance after propose — and, after owner, until the run was
opened by the owner's approval, and after build, until a build came back
done.

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
request_routes = [{ name = "owner", via = ["origin"] }, { via = ["parent", "origin"] }]
```

Replace its destination with the responsible configured participant when the
owner and conversation origin differ. The agency and sales-desk eval overlays
declare this route. Questions needing an answer use `ask`; received requests use
`reply` or `escalate`. `break` remains a stopped-work report.
