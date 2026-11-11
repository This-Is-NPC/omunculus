# design-team

The design team makes the visual proposal a site starts from — a design
system (`design/preview/system.css`: colours, fonts, type scale, spacing
and components), a moodboard, and the wireframes and a mockup of each
page in scope — and publishes it to homologation, where the
project manager shows it to the client before anything is built. It builds no site: once the client
and the owner approve, the builders work from its `design/handoff.md`.

| Agent | Depth | Does |
| --- | --- | --- |
| design-lead | 0 | answers the project manager: briefing, rounds, assessments |
| designer | 1, workflow only | makes the design in `design/` |
| design-reviewer | 1, workflow only | the team's QA, independent of the designer and the builders: checks the design against the briefing, and, where a project composes it into the build, what is built against the approved design (or the scope and plan when the client waived it), sending back only defects, each naming the item of the plan that fixes it |
| publisher | 1, workflow only | publishes it to homologation |

## Receiving work

The design lead takes a work from the project manager, in one of three forms:

- **A design.** The goal is the briefing in full, which the sales desk composes from the proposal as a block from `=== PROPOSAL FACTS` to `=== END PROPOSAL FACTS ===` (sections for the client, pages, products and prices, contacts with the WhatsApp number, hours and address, colours, fonts and style, texts, pending and the round) that the lead and the designer use verbatim: the business, who
  decides, what the site is for, the pages in scope, the audience, logo,
  colours and fonts, the content the client sends, references, tone and the
  main action (`templates/design-brief.md`), with the client's content word
  for word (products and prices, hours, address, contact, WhatsApp number)
  that the preview shows as given, only what the client did not give being
  pending, the round (0 for the first
  design) and the client's slug. What is missing the lead asks for before
  handing the design down. The designer commits `Dockerfile` and
  `deploy.toml` with `app = "design-<client-slug>"` at the workspace's
  root, which the build's base item then replaces with the site's own.
  The design is made and published only before the build: when the root's
  `deploy.toml` names another app, the site is built, the team starts no
  design or round and breaks saying so, and a change to the design is a
  change to the build.
- **A round.** The goal names the earlier design (title and id) and what
  the client asked to change. A page or feature outside the briefing's
  scope is not a round, and with the rounds used up the lead starts none,
  unless the goal says the owner approved an extra round, which it then
  starts.
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
only defects that block what the stage must deliver, against the briefing,
the handoff, the plan's checks or the scope, each naming what is wrong, the
item to fix and what it must show; taste and minor content or specimen
issues go in its report as notes, fixed in the next pass, never a reopen.
The deploy descriptor rule depends on the stage: in the design review the
root `deploy.toml` must name `app = "design-<client-slug>"` and the
`Dockerfile` must serve `design/preview`; in `page`, `accept` and the
release the app is the client's slug, never `design-*`. When the client waived the design, the
plan says "Design: waived by the client" and there is no `design/handoff.md`:
it then checks each page and the whole site against the scope and the plan,
and a missing approved design never blocks it.

A project composes it into the build by naming it in the dev team's
workflows (the [sales desk](../sales-desk/README.md#what-the-project-configures)
shows the TOML): in `page` it replaces the copilot after the surgeon, so it
also runs the copilot's mechanical checks (`mise run check`, `AGENTS.md`,
secrets) and checks that `deploy.toml`'s app is the site's, not
`design-<slug>`; in `release` it accepts the published whole between
`publish` and `promote`.

## Importing it

It works for the project manager and publishes with the dream team's
`deploy_preview`, which it `requires`, as it does `bash`, the codex-like
preset's (`priv/presets/codex-like/tools`, in the project's `[tools]
paths`): import the dream team first, then this team beside the
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
