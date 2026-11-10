# design-team

The design team makes the visual proposal a site starts from — a design
system (`design/preview/system.css`: colours, fonts, type scale, spacing
and components), a moodboard, and the wireframes and a mockup of each
page in scope — and publishes it to homologation, where the
sales desk shows it to the client before anything is built. It builds no site: once the client
and the owner approve, the builders work from its `design/handoff.md`.

| Agent | Depth | Does |
| --- | --- | --- |
| design-lead | 0 | answers the sales desk: briefing, rounds, assessments |
| designer | 1, workflow only | makes the design in `design/` |
| design-reviewer | 1, workflow only | the team's QA, independent of the designer and the builders: checks the design against the briefing, and, where a project composes it into the build, what is built against the approved design (or the scope and plan when the client waived it), sending back only defects, each naming the item of the plan that fixes it |
| publisher | 1, workflow only | publishes it to homologation |

## Receiving work

The design lead takes a work from the sales desk, in one of three forms:

- **A design.** The goal is the briefing in full: the business, who
  decides, what the site is for, the pages in scope, the audience, logo,
  colours and fonts, the content the client sends, references, tone and the
  main action (`templates/design-brief.md`), the round (0 for the first
  design) and the client's slug. What is missing the lead asks for before
  handing the design down. The designer commits `Dockerfile` and
  `deploy.toml` with `app = "design-<client-slug>"`.
- **A round.** The goal names the earlier design (title and id) and what
  the client asked to change. A page or feature outside the briefing's
  scope is not a round, and with the rounds used up the lead starts none.
- **An assessment.** The goal begins `Assessment only, build nothing:`. The
  lead answers it itself, never through the workflow `design`, in writing:
  yes, no or partly, then the effort (steps in order and how large each is,
  never a date), what it needs from the client and what blocks it.

The preview is the default. Every design is published as a preview and
handed up for the client; the team never decides the client does not want
one. Skipping the design is the client's waiver, and then no work comes to
this team. The lead's report opens by saying the preview is ready for the
client's approval.

Every design goes through the workflow `design`: design (designer), review
(design-reviewer), publish (publisher), which `deploy_preview` concludes,
commenting the homologation address and the commit, as the stage denies
`done`. It publishes the commit at HEAD, so the workspace's root holds,
committed, a `Dockerfile` that serves `design/preview` and a `deploy.toml`
(`templates/deploy.toml`) naming the app and its port, as the dream team's
[deploy contract](../dream-team/README.md#the-deploy-contract) says. The pack requires it at the
designer's depth and the design lead names it, so another team's workflow
at that depth sits beside it. A briefing comes before any design, the
moodboard and wireframes before the mockup, and the rounds of revision
included are those `templates/design-brief.md` gives; a change of scope is
not a round, and rounds beyond those are the owner's decision.

The design reviewer is the team's QA. It changes no file and sends back
only defects against the briefing, the handoff, the plan's checks or the
scope, each naming what is wrong, the item to fix and what it must show;
taste goes in its report as a note. When the client waived the design, the
plan says "Design: waived by the client" and there is no `design/handoff.md`:
it then checks each page and the whole site against the scope and the plan,
and a missing approved design never blocks it.

## Importing it

It works for the sales desk and publishes with the dream team's
`deploy_preview`, which it `requires`, as it does `bash`, the codex-like
preset's (`priv/presets/codex-like/tools`, in the project's `[tools]
paths`): import the dream team first, then this team one depth below the
seller. The publisher commits under the git identity the project
gives commands, as the dream team's README says, and sets none of its
own.

```sh
omunculus pack --path packs/design-team --models team=<model> --depth 2
```

## What it holds

```text
pack.toml                      the agents, on the role `team`, and the workflow
workspace/design/README.md     the layout and rules of the design
workspace/templates/design-brief.md
                               the briefing, and the rounds included
tasks/                         the evals that show it works
images/                        a portrait of each agent, its `image`, after Totally Spies!:
                               the lead as Jerry, the designer as Clover, the reviewer
                               as Sam, the publisher as Alex
```

Questions use `ask`. The lead answers received requests from the briefing or work goal and escalates all remaining questions together, preserving named origins; returned text is distributed with `reply`. Requests preserve waits on children. `break` stops failed work.
