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
refused rather than ignored.

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
what `paths` lists. A name in the ceiling that is not in the catalog is
blocked.

`[[mcp.servers]]` is `name`, `command` and `protocol_version` per server.
The version goes on `initialize`. There is no global protocol constant.
MCP discovery runs in a restricted sandbox; a server that fails to list
is skipped and logged, not fatal to the run.

## Models and auth

`api` is `openai-completions`, `openai-responses`, `anthropic-messages`,
`command` or `module`. `module` names an Elixir adapter (`Omunculus.Model.Fake`
is the one the default preset uses). `command` runs a program over the
sandbox NDJSON protocol. The HTTP adapters take `url`, `model`, optional
`timeout_ms`, `headers` and `provider`.

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

[agents.concierge]
depth = 0
model = "fake"
tools = ["break", "catalog", "continue", "delegate", "fs.read", "reply", "store"]
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
`deny`, `pinned`. Intersected, not unioned. [The ceiling](ceiling.md) is
the rule.

`text` is what the assemble tool puts first in the prompt. It is not a
system role and it is not the message from `send`.

## Workspaces

```toml
[workspaces.app]
root = "app"
deny = ["delete"]
config = "omunculus.toml"
```

`root` is a directory, relative to the project root. Ceiling keys on the
section are a layer. Any other global table (`execution`, `models`,
`agents`, `workflows`, `tools`, `policy`, `mcp`, `auth`) overlays the
global file: the workspace wins, a list replaces rather than concatenates.
`[store]` stays global.

`config` is a second TOML relative to that `root`, same schema minus
`[workspaces]` and `[store]`. Precedence is global, then the inline
section, then the file. Missing file is an error. A permanent grant with
`scope = workspace` writes that file when it exists.

## What a load will not invent

No model from the environment. No store path next to the binary. No
sandbox flags from a module attribute. No catalog from the package unless
`paths` pointed at it (a preset's rewritten `paths` usually does).
`$VAR` in an `[auth]` key and names listed in `[execution] environment`
are the two times the process environment is read, and both are declared
in this file.
