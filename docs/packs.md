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
the default workspace, keeping the files there, unless the project lacks a
tool the pack `requires` (from another pack). It lists the pack's
`environment/`, which it does not run. An agent can propose the same import
to the person with `propose_pack`, whose `apply` option calls `pack`.

## How a team talks

Pack questions use `ask`, permission forms use `request_access`, and
intermediaries use `reply` or `escalate`; `break` stops failed work. Design
leads and administrators answer known facts and escalate the remaining
named origins while preserving child waits ([requests](requests.md)).

The sales desk and its `next_stage` refusal name the logical `owner` route,
which the project importing it configures; the sales-desk and agency eval
overlays declare it. Their default route goes through the parent, then the
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
  proposes cutting each with `propose_config`;
- the `refiner`, which reads the project's last runs with `runs` — where an
  agent stopped without ending, retried, was refused, skipped a step or
  looped — and proposes, with the runs that show it, the change in the
  teams' texts, tools or workflows.

Their portraits and their skills (`team-design`, `team-composition`,
`configure`, `audit`, `refine`) are in the pack; see
[`priv/packs/system/README.md`](../priv/packs/system/README.md).
