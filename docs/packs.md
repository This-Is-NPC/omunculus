# Packs

A pack is a team distributed as a folder. The repository's own are under
`packs/` (each with the eval tasks that show it works) and
`priv/packs/system`.

## Importing a team

`[[packs]]` imports teams (`Config.Packs`): each names a pack's folder,
whose `pack.toml` holds agents on roles, workflows, tool secrets on
providers, MCP servers and depth layers, and maps its roles to the config's
models and its providers to the config's `[auth]`, and may move the whole
team `depth` depths below its own. The pack's items are laid under the
config's, an item of the config of the same name overriding it key by key
(grants it writes joining the pack's tools); two packs' items of one name
are refused but for depth layers, where the workflows they require add up;
and the pack's `tools/` and `skills/` come before the config's paths.

The `pack` tool imports a pack:

```sh
omunculus pack --path <dir> --models role=model --auth provider=login [--depth n]
```

Given a model for each of its roles and a login for each of its providers,
it writes the pack to `[[packs]]` and copies the pack's `workspace/` into
the default workspace, keeping the files there, when the config loads with
it. It lists the pack's `environment/`, which it does not run.
With `[project] conversations`, a conversation's folder starts as a copy
of the workspace, so those files reach every conversation that starts
after the import ([config](config.md#a-folder-per-conversation)).

A tool a team's agents use that the pack does not bring goes in
`[pack.requires]`, its name and, as text, where to get it:

```toml
[pack.requires]
bash = "the codex-like preset's tools (priv/presets/codex-like/tools)"
```

Loading a config refuses a pack whose required tools its catalog — the
tool folders of `[tools] paths` and the packs, the skills and the inline
tools — lacks, naming each tool and where to get it, so neither the
`pack` tool nor a run starts with a team that cannot call them. An MCP
server's tools are known only once a run starts it, so a pack cannot
require one. An agent can propose the same import
to the person with `propose_pack`, whose `apply` option calls `pack`.

## How a team talks

Pack questions use `ask`, permission forms use `request_access`, and
intermediaries use `reply` or `escalate`; `break` stops failed work. Design
leads and administrators answer known facts and escalate the remaining
named origins while preserving child waits ([requests](requests.md)).

Each of the sales desk's conversations is one client's: the project
importing it sets `[project] conversations`, so no client's proposal,
design or site is in another's reach, and the dream team's deploy tools
name each conversation's apps apart. Its depth layer requires the
workflow `sale` at its depth, so every work there is a client's request
the seller works through it: a work the generalist opens without naming
it goes through `sale`, and one naming an agent is refused. The system
team beside it opens no work, so the requirement leaves it as it is; a
project whose other agents at that depth open works imports the desk a
depth below them.

The sales desk and its `next_stage` refusal name the logical `owner` route,
which the project importing it configures, as do the dream team's
administrator and surgeon for what only the machine's operator can settle;
the dream-team, sales-desk and agency eval overlays declare it. Their default route goes through the parent, then the
sales generalist, then the conversation origin. The generalist batches all
received questions in its conversation into one escalation and distributes
the returned text with `reply`; seller questions and preview and price
approvals use `ask`. It ends on acknowledgements after delivery and creates
new work only for an explicit new request. See
[`packs/sales-desk/README.md`](../packs/sales-desk/README.md).

## The system team

The default preset imports the system team (`priv/packs/system`):

- the `steward`, at depth 0 beside the concierge, which the person talks
  with by name to change the project itself. It reads the setup with
  `config` and `overview`, writes new teams as packs in the workspace, and
  proposes every change with `propose_config` or `propose_pack`;
- the `auditor`, beside it, which finds what in the config is loose or left
  over — grants past an agent's work, what never runs or cannot run — and
  proposes cutting each with `propose_config` — one member of a granted
  group through the agent's `deny`, and an agent or workflow a pack brings
  through that item's keys in the project's file, which override the
  pack's;
- the `refiner`, which reads the project's last runs with `runs` — where an
  agent stopped without ending, retried, was refused, skipped a step or
  looped — and proposes, with the runs that show it, the change in the
  teams' texts, tools or workflows.

The auditor and the refiner are granted `config`, `overview` and
`propose_config` but not `propose_pack`: importing a pack is the steward's.

Their proposals go on the logical `owner` route, which a project importing
the team declares, as the default preset does with
`{ name = "owner", via = ["origin"] }`; see [requests](requests.md).

Their portraits and their skills (`team-design`, `team-composition`,
`configure`, `audit`, `refine`) are in the pack; see
[`priv/packs/system/README.md`](../priv/packs/system/README.md).
