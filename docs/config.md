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

Three keys of `[execution]` are optional. `host = true` shows a command
the machine read-only, as the person sees it, with their home overlaid so
that what it writes there stays in the run's scratch; without it a
command sees only the runtimes, the workspace and the folders of the
catalog's tools. `deny_read` lists paths, absolute or under `~`, a
command may not read; `write` lists paths it may also write.

A root in `runtimes` is read-only inside the sandbox and exposes every
binary it contains; it is not a per-binary allowlist, so keep those
installations outside workspaces. The executor installs neither
Bubblewrap nor a runtime.

`[execution.sandbox]` is mandatory beside it: `script`, `command`, `runner`
and `exec`. The coordinator the model runs, the Deno (or other) flags, and
the wrapper that feeds it stdin are here, not constants in the core.

`[store] path` is mandatory, relative to the file. That is the SQLite
database. Creating the file creates twelve tables. Stores made by earlier versions without conversations, participant columns or escalation links must be recreated before opening them with this version.

`[store] changes`, optional, is the directory where the files each model call changed are kept. `[store] attachments`, optional, is the directory where the files attached to conversations are kept, each under its SHA-256; it needs `[store] attachment_bytes`, the most one file may hold, and that key needs it. Without them a message or an agent can attach nothing.

`[access]` is optional for direct CLI use and required for a project exposed by the HTTP server. It names `creator_role`, `bootstrap_role` and `[access.roles.<name>]` tables, each with `scope = "project"` or `"conversation"` and a `capabilities` list. Memberships are project state in SQLite; role definitions stay in TOML. See [the server guide](server.md).

`[models.<name>]` needs `api`. Every `[agents.<x>]` needs `model`, pointing
at one of those names. Without `[models]`, or without an agent's `model`,
the load fails.

An agent may have an `image`, a picture (`.png`, `.jpg`, `.jpeg`, `.webp`
or `.gif`) relative to the config's directory, or to the pack's folder for
an agent a pack brings, that clients show for it. A path that is not such
a file is refused at load.

`[policy] assemble` (or `agents.<x>.assemble`) names the tool that builds
the assembled prompt. Without it the opening of a run fails.

`[policy] max_retries` is mandatory: a non-negative integer, how many
times a work whose model stopped without `end` gets another run before
the harness breaks it ([the cycle](cycle.md)). `[workspaces.<w>.policy]
max_retries`, or `[policy] max_retries` in the workspace's `config` file,
sets it for the works in that workspace.

`[policy] max_reopens` is optional: a non-negative integer, how many
times in a row a parent may send one work below it back with `reopen`.
The rounds counted are the work's reopens since an answer to a request
of the parent's work last came. Once they reach `max_reopens`, the next
`reopen` does not send the work back: the parent asks along its request
route instead, with a question naming the work and the instructions it
would have gone back with, and waits on the answer, the broken work still
waiting on it ([the cycle](cycle.md#work)). Without it a parent reopens
a work as often as it likes. A workspace sets it the same way as
`max_retries`.

`[policy] request_routes` is mandatory and nonempty. Loading a config without
it refuses with `{:policy, {:required, :request_routes}}`. Malformed routes return
`{:policy, {:invalid, :request_routes}}`. Routes are parsed
once into `Config.request_routes`, including workspace overlays. For example:

```toml
[policy]
request_routes = [
  { name = "owner", via = ["origin"] },
  { via = ["parent", "origin"] },
]
```

The first rule matching the optional logical route name (`to`), authenticated
`from` identity, `workflow` and `stage` selects its `via` list. Unnamed requests
match unnamed rules. A stage filter requires its workflow; both must exist.
Destinations are `parent` (the parent work's assignee), `origin` (the authenticated
conversation creator, or the run/command origin when there is no conversation),
or an identity `{ kind = "agent", agent = "name" }` / `{ kind = "human",
issuer = "issuer", subject = "subject" }`. A named agent must be an ancestor's
assignee or a configured depth-0 agent that can run without a workflow. Missing contextual destinations and
participants already in the linked request's origins are skipped within that
explicit list. If none resolves, the action refuses with `{:request, :no_route}`
and changes nothing. There is no implicit human fallback. Routing does not
authorize grants; sealed capabilities and permanent scopes still need a human's
selected option on the original request. Escalation resolves a new route from
the receiving participant's context. Presets, Amestris and the benchmark declare
`parent` then `origin` in TOML; eval overlays inherit those routes.

`[policy] last_run_output_bytes` is optional: a positive integer, how
many bytes of each tool call's output the `## Last run` section of the
assembled prompt keeps; the rest is cut and a line says how many bytes
were cut. Without it the section keeps each output whole. A workspace
sets it the same way as `max_retries`.

`[policy] tool_output_bytes` is optional: a positive integer, how many
bytes of each tool call's output the model gets back during the run,
from a call it makes directly or through `tools.*`; the rest is cut the
same way. The recorded call keeps the output whole. Without it the model
gets each output whole. A workspace sets it the same way as
`max_retries`.

`[policy] conversation_bytes` is optional: a positive integer, how much
of its conversation's works and exchanges a run without a work is shown
under `## Works` and `## Conversation`, the newest that fit. Without it
they are shown whole.

`[policy] send_catalog` is optional: `true` sends every run the
catalog's model tools, not only its own, so all agents' requests start
alike and a provider's cache serves them; a call to a tool the run does
not have is refused and recorded as failed.

`[policy] session_ttl_ms` and `session_max_bytes` are optional and go
together: a run of an agent whose last run on the work, or in the
conversation for a run without a work, paused and closed within
`session_ttl_ms` continues that session, told only what happened since;
a history longer than `session_max_bytes`, or one that cannot be rebuilt
exactly, starts over ([the cycle](cycle.md#assemble)).

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

Discovery walks `paths` in order, then the skills of `[skills] paths`
([Skills](#skills)), then `[[mcp.servers]]`, then inline
`[tools.<name>]` tables. The last declaration of a `name` wins; a tool
named as a group (a name in some manifest's `groups`) is skipped and
logged, so a name in a ceiling list is a tool or a group. There is
no magical `priv/tools`, `~/.omunculus/tools` or `<project>/tools` outside
what `paths` lists, with one exception: a name the command line or the
harness dispatches (`send`, `assemble`, …) that the catalog does not hold
is looked up among the package's own `priv/tools` folders, and used when
its `triggers` include that trigger. A name in the ceiling that is not in
the catalog is blocked.

`[[mcp.servers]]` is `name`, `command` and `protocol_version` per server,
and an optional `secrets` table binding the variables its process
receives to `[auth]` providers, as `[secrets.<tool>]` does for a tool.
The version goes on `initialize`. There is no global protocol constant.
MCP discovery runs in a restricted sandbox; a server that fails to list,
or whose secrets do not resolve, is skipped and logged, not fatal to the
run.

## Skills

```toml
[skills]
paths = ["~/.agents/skills", ".agents/skills"]
```

Each path, relative to the config file's directory with `~` the home, holds
Agent Skills in the agentskills.io format, the one `~/.agents/skills` and a
repository's `.agents/skills` hold for other agents: a folder with a
`SKILL.md` whose YAML frontmatter has `name` (lowercase letters, digits
and single hyphens, at most 64, equal to the folder's name) and
`description` (1 to 1024 characters). A skill joins the catalog as
`skill.<name>`, in the group `skills`, and the ceiling governs it as it
governs a tool: an agent lists `skills`, or one `skill.<name>`, in its
layers, and reads them through the `skill` tool ([Skills](tools.md#skills)).
Its `allowed-tools`, space separated, names the tools it uses: each entry's
name before any `(…)`, in lowercase, matched to the catalog. A client draws
them; they grant nothing, the ceiling decides.
A folder that breaks the format is skipped and logged; of two
skills with a name, the one of the later path wins. Without `[skills]`
there are none. The presets declare the two paths above.

## Tool secrets

A `command` tool's manifest declares the secrets its process needs
(`secrets = ["GH_TOKEN"]`); the config binds each to the `[auth]`
provider whose credential it is:

```toml
[auth.github]
kind = "api_key"
key = "!omapass get -- dev/github"

[secrets.gh]
GH_TOKEN = "github"

[[mcp.servers]]
name = "github"
command = ["github-mcp-server", "stdio"]
protocol_version = "2025-03-26"
secrets = { GITHUB_PERSONAL_ACCESS_TOKEN = "github" }
```

A provider resolves as a model's does: `$VAR`, `!cmd`, a literal, or a
stored login. A provider `[auth]` lacks does not load. A declared name
left unbound, or a bound name the tool does not declare, refuses the
call. The value reaches only that tool's process, as the read-only file
`/run/secrets/<NAME>` named by `<NAME>_FILE`, removed when the process
ends; it never enters the execution policy, the store or the events,
and what the call returns has it masked as `***`. `[execution]
environment` stays what every process of a run receives.

## Models and auth

### Compatible providers

A model is any server that speaks one of the APIs below, or a program or an
Elixir module of your own. Which provider and model a project uses is its
`[models.<name>]` table; nothing else changes.

| `api` | Speaks | For example |
| --- | --- | --- |
| `anthropic-messages` | Anthropic's Messages API (`/messages`) | Anthropic |
| `openai-responses` | OpenAI's Responses API (`/responses`) | OpenAI |
| `openai-completions` | OpenAI's Chat Completions API (`/chat/completions`) | OpenAI, OpenRouter, and servers compatible with it such as Ollama, vLLM or LM Studio |
| `command` | the sandbox NDJSON protocol, from a program the run starts | a local CLI or a wrapper of your own |
| `module` | an Elixir adapter of the package | `Omunculus.Model.Fake`, for runs without a network |

```toml
[auth.anthropic]
kind = "api_key"
key = "$ANTHROPIC_API_KEY"

[models.claude]
provider = "anthropic"
api = "anthropic-messages"
url = "https://api.anthropic.com/v1"
model = "claude-sonnet-4-5"
timeout_ms = 120000
body = { max_tokens = 32000 }

[auth.openrouter]
kind = "api_key"
key = "$OPENROUTER_API_KEY"

[models.router]
provider = "openrouter"
api = "openai-completions"
url = "https://openrouter.ai/api/v1"
model = "anthropic/claude-sonnet-4-5"
timeout_ms = 120000
```

A model's `provider` names an `[auth.<name>]` login, whose key the adapter
sends; a local server that needs none leaves `provider` out.

### The adapters

`api` is `openai-completions`, `openai-responses`, `anthropic-messages`,
`command` or `module`. `module` names an Elixir adapter (`Omunculus.Model.Fake`
is the one the default preset uses). `command` runs a program over the
sandbox NDJSON protocol (a `{"type":"delta","text":"..."}` line passes
partial reply text to the run without recording it) and takes `command`, `model`, optional `provider`
and `params`. `module` takes optional `params`. The HTTP adapters take
`url`, `model`, `timeout_ms`, and optional `temperature`, `headers`,
`provider`, `stream`, `retries` and `code_mode`; an `anthropic-messages`
model also needs `body = { max_tokens = n }`, the most a reply may take,
thinking included. With `stream = true` the adapter asks for
server-sent events and passes the reply text to the run as it arrives;
the recorded turn is the same as without it. `retries` sends a request
again that many times on a rate limit, a timeout, a server error or a
dropped connection, after the delay the server asks for; without it a
failed request fails the call. `code_mode = true` also offers the model
`__omunculus_execute`, which runs JavaScript in the sandbox calling
`tools.<name>(args)` through the same authorized, recorded path as its
other calls. Every HTTP adapter records, with each turn in
`EVENTS(model)`, the `usage` object the server returns (input, cached
input and output tokens); streamed, `openai-completions` asks for it
with `stream_options.include_usage`. The two OpenAI adapters also take an optional
`prompt_cache_key`, sent as is in every request, which OpenAI uses with
the prompt's prefix to route requests to the server holding that prefix
in cache.

Every HTTP adapter takes an optional `body` table, merged over the
request body it builds: a key of `body` replaces the request's key of the
same name, and two tables merge key by key. It sets what the adapters
have no key for, and replaces what they send, such as the
`anthropic-messages` `max_tokens`:

```toml
[models.router.body]
reasoning = { effort = "high" }
max_tokens = 16000
```

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
timeout_ms = 120000
body = { max_tokens = 32000 }
```

`kind` is `api_key` (`key` = `$VAR`, `!cmd`, or a literal; empty falls
through to a stored login; a password kept by omapass is
`!<program> get -- <account>`, which `omunculus omapass` lists), `oauth-code`, or `tool` (`login` / `refresh`
names). Credentials are the JSON file, mode 0600, not the project SQLite.
`login` and `logout` write that file.

## Agents, policy, workflow

```toml
[policy]
mode = "auto"
assemble = "assemble"
max_retries = 3
request_routes = [{ via = ["parent", "origin"] }]

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

A work goes through a workflow when it names one (`work` and `delegate`
take `workflow` beside `agent`), and keeps it: its stages are the
workflow's. A work may name a workflow whose stage agents are all of its
depth. `workflows = [...]` on `[policy]`, or on a `[policy.depth.<n>]`
for that depth alone, requires them: a work there goes through one of
them — the only one when it names none — and naming an agent is refused.

```toml
[policy.depth.1]
workflows = ["delivery"]
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

`config` is a second TOML relative to that `root` that may hold only
`[policy]`, `[agents]`, `[workflows]`, `[mcp]`, `[execution]`,
`[project]`, `[tools]`, `[models]` and `[auth]`. Precedence is global, then the inline
section, then the file. The ceiling keys and `overrides` of the file's
`[policy]` join the section's layer, the file's `overrides` winning per
key. Missing file is an error. A permanent grant with
`scope = workspace` writes that file when it exists.

### A folder per conversation

```toml
[project]
conversations = "clients"
```

With `[project] conversations`, a folder relative to each workspace's
root and inside it, each conversation works apart: its runs, and the
calls made in it, have `<workspace root>/clients/<conversation id>` as
their root in place of the workspace's, so what one conversation writes
another neither reads nor changes, and a tool that names what it
publishes after its root (the dream team's deploy tools) publishes each
conversation's apart. The folder starts, the first time a run or call of
the conversation needs it, as a copy of the workspace's files as they
are then — the templates and the `AGENTS.md` a pack copied there —
leaving out the conversations' folder itself and what omunculus keeps
inside the workspace: the config file, the store with the files beside
it, `[store] changes` and `attachments`, and `[auth] store`. A file added
to the workspace later reaches only the conversations that start after.
A call with no conversation — the direct CLI without `[access]`, which
opens none — works in the workspace's root. With `[execution] host`,
commands see the machine read-only, the other conversations' folders
included; `deny_read` can name the folder.

## What a load will not invent

No model from the environment. No store path next to the binary. No
sandbox flags from a module attribute. No catalog from the package unless
`paths` pointed at it (a preset's rewritten `paths` usually does), beyond
the command-line and harness lookup under [Catalog](#catalog).
`$VAR` in an `[auth]` key and names listed in `[execution] environment`
are the two times the process environment is read, and both are declared
in this file.

## Errors a load names

The command line prints these on stderr before a tool runs, or when a run
needs what is missing:

| Line | When |
| --- | --- |
| `` no config at <path>; run `omunculus preset <name> --from <dir>` `` | file missing |
| `omunculus.toml is missing [execution]; required keys: …` | table or keys absent |
| `omunculus.toml is missing [execution.sandbox]` | sandbox table absent |
| `omunculus.toml [execution] resources includes unknown name <name>` | a resource the executor does not know |
| `omunculus.toml is missing [models]` | no adapters |
| `omunculus.toml is missing [store]` | no store path |
| `omunculus.toml agent <name> is missing model` | agent without `model` |
| `omunculus.toml [policy] max_retries is required, a non-negative integer` | `max_retries` absent or invalid |
| `omunculus.toml [policy] request_routes is required, a nonempty list of routes` | `request_routes` absent |
| `omunculus.toml [policy] request_routes must be a nonempty list of valid routes` | `request_routes` invalid |
| `omunculus.toml [policy] max_reopens must be a non-negative integer` | `max_reopens` invalid |
| `omunculus.toml [policy] <key> must be a positive integer` | `last_run_output_bytes`, `tool_output_bytes`, `conversation_bytes`, `session_ttl_ms` or `session_max_bytes` invalid |
| `omunculus.toml [policy] session_ttl_ms and session_max_bytes go together` | one of the two without the other |
| `omunculus.toml [policy] send_catalog must be true or false` | `send_catalog` invalid |
| `omunculus.toml is missing assemble` | no assemble tool named |
| `assemble returned an empty prompt` | assemble ran and produced nothing |
| `overrides.<tool>.chains names <name>, which the <tool> manifest does not chain` | an override widens `chains` |
| `overrides of <tool> leave a then outside its chains or with end not last` | an override breaks the `then` rule |
| `overrides.<tool>.schema names <variant>, which the <tool> manifest does not declare` | an override names an unknown schema |
| `pack <pack> requires tools the project lacks: …` | an imported pack names tools no `[tools] path` holds |
| `` not logged in to <id>; run `omunculus login --provider <id>` `` | credential missing |
| `store schema predates conversations; recreate the store` | a store older than the schema |
| `project is in use by another Omunculus process` | another direct command holds the project |

A reason without a sentence of its own prints as the Elixir term.
