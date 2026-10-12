# The dream team

Takes a request from a conversation to a published app. It is the surgical
team of *The Mythical Man-Month*, ch. 3: one surgeon designs and writes what
matters, the others free them of the rest. The administrator asks until the
request is clear and plans it, the surgeon builds each item of the plan with
the helpers below, the copilot reviews each, and the clerk publishes the
whole to homologation, then to production once the person grants `promote`.

| Agent | Depth | Role |
|---|---|---|
| administrator | 0 | talks with the person until the work is ready, plans it and hands down each item |
| surgeon | 1 | builds each item of the plan, writing the code that matters |
| copilot | 1, workflow only | reviews each item against its goal, the plan's checks and AGENTS.md |
| clerk | 1, workflow only | publishes the whole to homologation, then to production once the person grants promote |
| toolsmith | 2 | mise, scripts, the means to check and publish |
| tester | 2 | writes and runs the tests |
| editor | 2 | README.md and docs/ |
| language_lawyer | 2 | how a language, library or version is meant to be used |

The administrator first writes `docs/plan.md`: a `## base` item, the
structure every page shares, then a `## page: <name>` item per page, each
with what it shows and how to check it. Each item is a work of the
workflow `page` — build (surgeon), review (copilot) — handed down one at a
time, base first; then one work of the workflow `release` — publish, then
promote (clerk) — takes the whole out. The pack's tool `deliver`, the
administrator's way to conclude, refuses a build until every item and the
release came back done. The pack requires both workflows at the surgeon's
depth; a project that composes teams may change their stages in its own
`[workflows.page]` and `[workflows.release]`, as long as it requires them
there.

## What it holds

```text
pack.toml       the agents, on the role `team`, the workflow, and the secrets
                of the deploy tools, on the providers `homologation` and
                `production`
tools/          deploy_preview (homologation), promote (production) and
                deliver, the administrator's done
workspace/      AGENTS.md, the rules every agent of the team follows
environment/    up and down: the two Dokku instances the deploy tools reach
tasks/          the tasks that show the team works, in the eval's format
```

## Using it

1. Start its environment: `environment/up`. It needs Docker, starts the
   homologation and production Dokku instances on 127.0.0.1, gives each a
   key of its own under `environment/.state/keys` and a unix socket under
   `environment/.state/sockets`. `environment/down` stops them.
2. In the project's `omunculus.toml`, give the deploy tools what they read:
   `OMUNCULUS_DEPLOY` (the sockets folder) in `[execution] environment`, and
   two logins whose keys are the instances' private keys, for example
   `[auth.homologation]` with `key = "$OMUNCULUS_HOMOLOGATION_KEY"` and
   `[auth.production]` with `key = "$OMUNCULUS_PRODUCTION_KEY"`.
3. Import it: `omunculus pack --path <this folder> --models team=<model>
   --auth homologation=<login>,production=<login>`. It writes the pack to
   `[[packs]]` and copies `workspace/AGENTS.md` into the project's workspace.

`promote` is in every agent's `human` list: only the person grants it, once
they have seen the app in homologation.

Questions use `ask`. The lead answers received requests from the briefing or work goal and escalates all remaining questions together, preserving named origins; returned text is distributed with `reply`. Requests preserve waits on children. `break` stops failed work.
