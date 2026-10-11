# design-team

The design team makes the visual proposal a site starts from — a
moodboard, the wireframes of the pages in scope and a mockup of the home
page — and publishes it to homologation, where the sales desk shows it to
the client before anything is built. It builds no site: once the client
and the owner approve, the builders work from its `design/handoff.md`.

| Agent | Depth | Does |
| --- | --- | --- |
| design-lead | 0 | answers the sales desk: briefing, rounds, assessments |
| designer | 1, workflow only | makes the design in `design/` |
| design-reviewer | 1, workflow only | checks it against the briefing |
| publisher | 1, workflow only | publishes it to homologation |

Every design goes through the workflow `design`: design (designer), review
(design-reviewer), publish (publisher). The pack requires it at the
designer's depth and the design lead names it, so another team's workflow
at that depth sits beside it. A briefing comes before any design, the
moodboard and wireframes before the mockup, and the rounds of revision
included are those `templates/design-brief.md` gives; a change of scope is
not a round, and rounds beyond those are the owner's decision.

## Importing it

It works for the sales desk and publishes with the dream team's
`deploy_preview`, which it `requires`: import the dream team first, then
this team one depth below the sales desk.

```sh
omunculus pack --path packs/design-team --models team=<model> --depth 1
```

## What it holds

```text
pack.toml                      the agents, on the role `team`, and the workflow
workspace/design/README.md     the layout and rules of the design
workspace/templates/design-brief.md
                               the briefing, and the rounds included
tasks/                         the evals that show it works
```
