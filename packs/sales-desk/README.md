# The sales desk

The front of a web agency that builds websites for small businesses. It
answers clients in Portuguese, writes what they want and the quote, and
agrees with the builders below that a request can be built before it
promises anything. It was written by the system team's steward in a lab
project and adjusted by hand.

| Agent | Depth | Role |
|---|---|---|
| sales | 0 | talks with the client, asks the builders for an assessment, quotes from the table |

It expects a team below it whose front agent is `administrator` and
answers a work that begins "Assessment only, build nothing:" without
building — the dream team (`packs/dream-team`) imported one depth down:

```sh
omunculus pack --path packs/sales-desk --models team=<model>
omunculus pack --path packs/dream-team --models team=<model> \
  --auth homologation=<login>,production=<login> --depth 1
```

The client talks with it by name: `omunculus send --agent sales "…"`.

It qualifies the client (need, who decides, budget, timing), finds out how
the business works and what a site would change, and writes the proposal
in `quotes/<client>.md` following `workspace/templates/proposal.md`, eight
sections from the client's problem in their words to the next steps;
change the template in the project to change the proposal.

Prices: a site of 4 pages is R$ 1.500, each page beyond 4 R$ 300, and
the desk may give up to 10% off on its own. A larger discount, and the
contract with the payment and the start date once the client accepts, it
asks the owner with `ask`; approved, it sends the builders the build.
