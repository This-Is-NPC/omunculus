# The TOML

All configuration is one file. Nothing in the SQLite store is configuration,
and the harness has no defaults for a key that lives here. A missing file is
an error; a missing required table is an error; an unknown
`[execution] resources` name is an error.

The file is `./omunculus.toml`, or whatever `--config` named. Paths inside
it are relative to the file. `[project] root`, if set, is the project root
instead of the file's directory.

## Required tables

`[execution]` is mandatory: `backend`, `runtimes`, `environment`,
`timeout_ms`, `max_output_bytes`, `max_concurrent`, `max_queue`,
`queue_timeout_ms`, `resources`. `resources` is the universe of sandbox
capabilities this project admits — `sandbox.write` and `sandbox.network`
are the two names the executor knows — and a name outside that list is
refused rather than ignored. `max_concurrent`, `max_queue` and
`queue_timeout_ms` bound the executor's processes and, in a pool of
their own, the runs: at most `max_concurrent` runs are open at once, up
to `max_queue` more wait for a slot, each for at most `queue_timeout_ms`,
and a run that gets no slot fails with `:queue_full` or
`:queue_timeout`.

`[execution.sandbox]` is mandatory beside it: `script`, `command`, `runner`
and `exec`. The coordinator the model runs, the Deno (or other) flags, and
the wrapper that feeds it stdin are here, not constants in the core.

`[store] path` is mandatory, relative to the file. That is the SQLite
database. Creating the file creates the seven tables.

`[models.<name>]` needs `api`. Every `[agents.<x>]` needs `model`, pointing
at one of those names. Without `[models]`, or without an agent's `model`,
the load fails.

`[policy] assemble` (or `agents.<x>.assemble`) names the tool that builds
the assembled prompt. Without it the opening of a run fails.

`[policy] max_retries` is mandatory: a non-negative integer, how many
times a work whose model stopped without `end` gets another run before
the harness breaks it ([the cycle](cycle.md)). `[workspaces.<w>.policy]
max_retries`, or `[policy] max_retries` in the workspace's `config` file,
sets it for the works in that workspace.

## Catalog

```toml
[tools]
paths = ["/abs/or/relative/tools"]

[tools.my_inline]
name = "my_inline"
kind = "tool"
triggers = ["model"]
description = "…"
module = "Omunculus.Tools.Read"
```

Discovery walks `paths` in order, then `[[mcp.servers]]`, then inline
`[tools.<name>]` tables. The last declaration of a `name` wins. There is
no magical `priv/tools`, `~/.omunculus/tools` or `<project>/tools` outside
what `paths` lists, with one exception: a name the command line or the
harness dispatches (`send`, `assemble`, …) that the catalog does not hold
is looked up among the package's own `priv/tools` folders, and used when
its `triggers` include that trigger. A name in the ceiling that is not in
the catalog is blocked.

`[[mcp.servers]]` is `name`, `command` and `protocol_version` per server.
The version goes on `initialize`. There is no global protocol constant.
MCP discovery runs in a restricted sandbox; a server that fails to list
is skipped and logged, not fatal to the run.

## Models and auth

`api` is `openai-completions`, `openai-responses`, `anthropic-messages`,
`command` or `module`. `module` names an Elixir adapter (`Omunculus.Model.Fake`
is the one the default preset uses). `command` runs a program over the
sandbox NDJSON protocol and takes `command`, `model`, optional `provider`
and `params`. `module` takes optional `params`. The HTTP adapters take
`url`, `model`, optional `timeout_ms`, `temperature`, `headers` and
`provider`.

```toml
[auth]
store = ".omunculus/auth.json"

[auth.anthropic]
kind = "oauth-code"
authorize_url = "https://claude.ai/oauth/authorize"
token_url = "https://console.anthropic.com/v1/oauth/token"
# …

[models.claude]
provider = "anthropic"
api = "anthropic-messages"
url = "https://api.anthropic.com/v1"
model = "claude-sonnet-4-5"
```

`kind` is `api_key` (`key` = `$VAR`, `!cmd`, or a literal; empty falls
through to a stored login), `oauth-code`, or `tool` (`login` / `refresh`
names). Credentials are the JSON file, mode 0600, not the project SQLite.
`login` and `logout` write that file.

## Agents, policy, workflow

```toml
[policy]
mode = "auto"
assemble = "assemble"
max_retries = 3

[agents.concierge]
depth = 0
model = "fake"
tools = ["break", "catalog", "continue", "delegate", "done", "end", "fs.read", "reply", "store", "work"]
text = """
You are the project concierge.
"""

[workflows.delivery]
steps = [
  { name = "to_do", agent = "worker" },
  { name = "review", agent = "reviewer", deny = ["fs.write"] },
]
```

Each of `workspace`, `depth`, a workflow step, an agent and `[policy]` is
a ceiling layer: `mode`, `granted` / `tools`, `negotiable`, `human`,
`deny`, `pinned`, and the per-tool `overrides` below. Intersected, not unioned. [The ceiling](ceiling.md) is
the rule.

`text` is what the assemble tool puts first in the prompt. It is not a
system role and it is not the message from `send`.

## Overrides

Each ceiling layer, and a workflow, may override three keys of a tool's
manifest under `overrides.<tool>`:

```toml
[policy.depth.0.overrides.work]
schema = "staged"

[policy.depth.1.overrides.done]
then = []

[workspaces.app.overrides.done]
chains = ["comment", "end"]

[agents.worker.overrides.done]
then = ["end"]

[workflows.delivery.overrides.work]
then = []

[workflows.delivery]
steps = [
  { name = "review", agent = "reviewer", overrides = { done = { then = [] } } },
]
```

- `then` replaces the manifest's `then`, under the same rule: every name
  in the effective `chains`, `end` only last.
- `chains` restricts the manifest's `chains`; a name the manifest does not
  list is an error.
- `schema` names one of the manifest's `[schemas.<variant>]`; that
  variant is what the model sees instead of `parameters`.

Any other key under `overrides.<tool>` fails the load. Each key resolves
on its own: the most specific layer that sets it wins, in the order
policy, workspace, depth, agent, workflow, stage. A workflow's overrides
apply to the runs in its stages. The ceiling snapshot of a run carries the
resolved overrides, and every call in that run, chain steps and hooks
included, sees the catalog with them applied. Outside a run only policy
and workspace apply; that is what the CLI uses, including which argument
is positional.

Checks against the manifest wait for the catalog: an override that does
not fit its manifest keeps a run from opening, and fails a call outside a
run. An override of a tool that is not in the catalog is ignored.

## Workspaces

```toml
[workspaces.app]
root = "app"
deny = ["delete"]
config = "omunculus.toml"
```

`root` is a directory, relative to the project root. Ceiling keys and
`overrides` on the section are a layer. Any other global table
(`execution`, `models`, `agents`, `workflows`, `tools`, `policy`, `mcp`,
`auth`) overlays the global file: the workspace wins, a list replaces
rather than concatenates. Ceiling keys and `overrides` inside an overlaid
`policy`, `agents` or `workflows` table do not overlay. `[store]` stays
global.

`config` is a second TOML relative to that `root`, same schema minus
`[workspaces]` and `[store]`. Precedence is global, then the inline
section, then the file. The ceiling keys and `overrides` of the file's
`[policy]` join the section's layer, the file's `overrides` winning per
key. Missing file is an error. A permanent grant with
`scope = workspace` writes that file when it exists.

## What a load will not invent

No model from the environment. No store path next to the binary. No
sandbox flags from a module attribute. No catalog from the package unless
`paths` pointed at it (a preset's rewritten `paths` usually does), beyond
the command-line and harness lookup under [Catalog](#catalog).
`$VAR` in an `[auth]` key and names listed in `[execution] environment`
are the two times the process environment is read, and both are declared
in this file.
