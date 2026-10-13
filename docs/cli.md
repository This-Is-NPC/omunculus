# `omunculus`

Dispatch a tool by name.

Exit codes: 0, the run did what was asked; 1, a refusal, a usage error, a
missing config, or a tool that returned `ok` false. There is no exit 2. A
path that is not there, a store that will not open and a model that will not
answer are all 1, and the line on stderr is the reason.

The binary also has `serve` and `access bootstrap` commands. Other names dispatch tools: `omunculus send` is the `send` tool,
`omunculus inbox` is the `inbox` tool: the same `{ name, args, view }` in and
`{ ok, output, emit, chain }` out the model uses, with `trigger = cli`. Replacing
the folder named `send` replaces the command. A name the catalog does not
hold is a refusal.

For tools and `access bootstrap`, `--config <path>` is the only flag that belongs to the binary, and it must
come first. Without it the file is `./omunculus.toml` in the working
directory. `bin/omunculus` always passes that path unless the first argument
is already `--config` or `serve`, and makes a relative `--config` absolute
against the caller's directory. The project root is the directory of that file, or
`[project] root` resolved against it. The SQLite store is `[store] path`,
also resolved against the file.

The binary reads no environment variables: the config file, and with it the
model of every agent, comes from `--config <path>` or `./omunculus.toml`.

A missing file is `` no config at <path>; run `omunculus preset <name> --from <dir>` ``. There is no package config to fall back to.
The one exception is a tool whose manifest set `config = false`, which is
how `preset` can write the file every other verb then reads. `preset` still
takes `--config` as the destination it writes to.

Arguments after the name are `--key value`, or one positional value mapped
onto the first `required` key in the tool's parameters. `omunculus send
"count to 5"` is `message`. A second bare word is a usage error. A `--key`
without a value is a usage error. Keys the schema did not list are still
passed through, which is how `send --work_id <id>` aims a message at a work
the manifest did not have to advertise as required.

Stdout is the tool's `output` and nothing else. Empty output is a successful
run that had nothing to print — `send` and `reply` are this — rather than a
missing result. Stderr is the formatted error; a tool that failed puts its
`output` there and exits 1.

A command that opens runs returns once every run it opened, directly or
through other runs, has finished. The error of any of them makes it exit
1; several errors are printed one per line.

While a [server](server.md) owns the project, a command goes to it over
the project's local socket, runs there as the same local user, and
returns the same output once the runs it opened have finished. The
project's `[access]` then applies to the local user, who needs a
membership. A project held by another direct command is refused as in
use.

A command that takes the project's lock itself first recovers what a
process that stopped left, as the server does when it opens the project
([the cycle](cycle.md#a-process-that-stops)): it closes the runs left
open and makes due again the runs that never began, and returns once
those have finished too, failing with their errors as with its own.

`omunculus --config <project.toml> access bootstrap --issuer <issuer> --subject <subject>` seeds the first project administrator. It requires ownership of the project config file and an empty project membership table. `omunculus serve --config <server.toml>` starts the optional HTTP server; see [the server guide](server.md).

## `omunculus preset`

- **Usage:** `omunculus preset <name> --from <dir>`
- **Config:** not required (`config = false`)

Copy a preset onto the config path.

`<name>` is recorded in the receipt (`preset <name> applied`). `--from` is
the directory that actually supplies the bytes: it must contain
`omunculus.toml`, and if it contains `tools/` that tree is copied beside the
file. `[tools] paths`, the `path` of each of its `[[packs]]` and
`[execution.sandbox] script` are rewritten to
absolute locations resolved against `--from`, and the `tools/` folder
beside the written file is appended to `paths`, so a checkout of
`priv/presets/default` keeps pointing at `priv/tools` and `priv/sandbox.js`
after the copy.

The three folders the package ships:

| `--from` | What it is |
| --- | --- |
| `priv/presets/default` | concierge / worker / reviewer, `fake` model, no shell |
| `priv/presets/codex-like` | Codex-shaped ceiling, plus a `bash` tool |
| `priv/presets/pi-like` | Pi-shaped ceiling, Anthropic OAuth already declared |

The default preset's reviewer uses `ask` to request execution output it
lacks without stopping the work, and the default preset imports the
[system team](packs.md#the-system-team).

A `--from` that is not a directory, or that has no `omunculus.toml`, is
`unknown preset: <name>`.

## `omunculus send`

- **Usage:** `omunculus send <message> [--work_id <id>]`
- **Effect:** writes `PROMPTS(message)` and `EVENTS(prompt)`; then the
  harness opens a run

Deliver a message. It does not create a work and it does not copy the
message onto a title. If the model wants a work, it calls `work`.

`--work_id` aims the prompt at a work that already exists. A work
waiting on a request, or parked by `break`, is reopened (`state = open`, waiting fields cleared) and
`EVENTS(work)` is written with `reason = reopened_by_prompt` before
`EVENTS(prompt)`. A work with `waiting = child` stays waiting on its
children: the message opens a run of its agent, named, and the last child
back reopens the work.

The stdout of a successful send is empty. The assembled prompt and the
model's text are in the store; `prompt` prints the first of those.

## `omunculus prompt`

- **Usage:** `omunculus prompt [--run <id>]`
- **Effect:** read-only

Print the assembled prompt of a run. Without `--run`, the last run by
`started_at`. No runs is `no runs`. An id the store does not hold is
`unknown run <id>`. A run that never attached an assembled prompt is
`no assembled prompt`.

## `omunculus inbox`

- **Usage:** `omunculus inbox`
- **Effect:** read-only

List unread notifications, one per line: `id agent: body`. An empty list
prints `empty inbox` and still exits 0 — that is the answer, not a
failure to find one. Inbox does not wait on a decision and does not
park a work.

## `omunculus config`

- **Usage:** `omunculus config [--section <section>] [--item <item>] [--whole true]`
- **Effect:** read-only

With `whole`, print the project's setup as one JSON object, for a client to show: its
`root`, `agents` (name, depth, model, `workflow_only`, the `granted`,
`negotiable`, `human` and `deny` lists of its own layer, its text and the
SHA-256 of its `image`, or null), `models` (name,
`api`, `provider`, `model`, and nothing else of their tables),
`workspaces` (name, root), the default `workspace`, and `workflows` with
their steps. For an editor it adds `document`: the `agents`, `models`,
`workflows`, `workspaces`, `auth` providers and tool `secrets` by name
and the `policy` and `access` tables, as the file writes them, but for a provider's
literal `key`, which stays in the file; `literal_keys` names the
providers that have one. It adds `revision`, the SHA-256 of the file's
bytes, and `names`, what a ceiling list may hold: the model tools, their
groups and the sandbox resources. It loads the TOML in the harness's
process; the sandbox hides the file from external tools. A server's local
socket runs it through `POST /v1/cli`.

A model reads the setup in parts, since a real project's outgrows what a
call returns (`[policy] tool_output_bytes`). Without arguments it prints
an index: `revision`, `root`, the default `workspace` and `sections`,
each named section (`agents`, `workflows`, `models`, `workspaces`,
`auth`, `secrets`, `packs`) by item name with the item's size in bytes,
and `policy`, `access` and `names` by their size. `section` prints one
section whole as `{section, revision, items}`; `item` prints one item,
`<section>.<name>` as `configure` takes it or, with `section`, its name
alone, as `{item, revision, ...}`; `policy` and `access` print as their
section. An agent item gives what the config runs (depth, model,
`workflow_only`, its lists, text), the `pack` it comes from and, as
`file`, the table the file writes for it, or null; a workflow its steps,
`pack` and `file`; a workspace whether it is the `default`; a provider
whether its key is literal (`literal_key`); a model or a tool's secrets
their `file` table. An unknown section or item fails, naming the
sections.

## `omunculus configure`

- **Usage:** `omunculus configure --item <item> --value <json> --revision <sha256> [--from <name>]`
- **Effect:** rewrites `omunculus.toml`

Write one item: `agents.<name>`, `models.<name>`, `workflows.<name>`,
`workspaces.<name>`, `auth.<name>` or `secrets.<tool>` as the JSON table
`value`, or
`policy` / `access` whole; `null` removes it. `from` names an item of the
same section removed in the same write, which renames it. A provider
written without a `key` keeps the literal key the file holds for it.
The rest of the file keeps what it holds; `[auth] store` and the tables
of the process (`project`, `execution`, `store`, `tools`, `mcp`) are not
items. The file must still be at `revision`, the one `config` printed, or
it is `omunculus.toml changed since it was read; read it again`. The
result must load as a config, or the reason it does not is the failure
and the file stays as it was. The file is rewritten whole, through a
temporary file, in the same form as a permanent grant writes it: keys in
order, text over several lines as multi-line strings. Like every tool
not scoped to a conversation, it needs `project.manage_config`.

## `omunculus overview`

- **Usage:** `omunculus overview [--agent <name>] [--workspace <name>] [--whole true]`
- **Effect:** read-only

With `whole`, print, as JSON, the project as it runs in each place a work can run, for
a client to draw. `places` holds each workspace, and the project root
while no workspace is the default; a place has its `root`, whether it is
the `default` and whether it lies `outside` the project, its own ceiling
lists (`layer`), what it overlays (`changes`), and its `depths`. A depth
has the `workflows` a work there may go through, each with its `name`,
whether it is `required` there and its `stages` (name, `deny`, agent);
whether the place `changed` them; and the `agents` a work goes to
without a stage, an `idle` one being workflow-only. An agent has
its `model` (name, id, api, `body`, whether the place `changed` it), the
`key` of its provider (the provider and where its value comes from:
`$VAR`, `omapass · <account>`, `command`, `stored login` or `in the
file`, never the value), and the names its layer lists, each with its
`state` under the ceiling there (`have`, `askable`, `sealed`,
`blocked`), a group's `members`, and the `secrets` the config binds to
it — the skills apart, as `skills`, each with its `description`, `state`
and the tools its `allowed-tools` names (`uses`). `unused_workflows` are
those no place runs.

A model reads it in parts. Without arguments it prints the same places,
depths, workflows and stages, each agent only as its `name` and its size
in `bytes` (and `idle` for one without a stage). `agent` prints
`{agent, runs}`: for each place, where the agent runs (`at`: the depth,
and the workflow, stage and its `deny`, or `idle` without a stage) and
the agent in full, once for the places it runs the same in. `workspace`
keeps the place of that workspace. An unknown agent or workspace fails.

## `omunculus model_test`

- **Usage:** `omunculus model_test --name <model> [--value <json>]`
- **Effect:** one model request

Send one short prompt, without tools, to the model `name` and print
`{"reply", "ms"}`: what it answered and how long it took. With `value`,
the model is that JSON table, as `configure` would write it, and the file
stays as it is: a model is tested before it is saved. The provider's
credential resolves as a run's does. A failure prints the reason, and a
model the config lacks is `no model <name>`. A `command` model runs in the
sandbox an agent's ceiling makes, so only a run tests it.

## `omunculus tools`

- **Usage:** `omunculus tools`
- **Effect:** read-only

Print the project's catalog as JSON, for a client to list: under
`tools`, each tool, hook and skill with its `name`, `kind`,
`description`, `triggers`, `groups`, the `secrets` it declares and the
`binding` `[secrets.<tool>]` gives them, a skill's `uses`, its `source` (`folder`,
`inline` or `skill`) and `dir`; under `mcp`, each `[[mcp.servers]]`
with its `command` and `secrets`, since a server's tools are known only
once a run starts it.

## `omunculus runs`

- **Usage:** `omunculus runs [--agent <name>] [--limit <n>] [--run <id>]`
- **Effect:** read-only

Print the project's last closed runs, newest first, as many as its
manifest's `recent` view reads: for each, its agent and depth, when it
started and how long it took, its work with the workflow stage, what made
it due (`via`), how it ended — the tool whose chain reached `end`, or that
the model stopped without it — its calls by name, each failed or refused
call with the start of its output, and the model's replies with the
tokens and cost their providers reported. `agent` keeps that agent's
runs, `limit` fewer of them; `run`, an id or the start of one, prints
that run call by call instead.

## `omunculus omapass`

- **Usage:** `omunculus omapass`
- **Effect:** read-only

Print, as JSON, what a client needs to take a provider's key from
omapass, the optional Omarchy password plugin: `installed`, and once it
is, `program` (the `omapass` on `PATH`, or the plugin's own under
`HOME`), `accounts` (each password's `account` and `folder`, without its
Nostr keys and never a secret) and `error` when it could not list them.
A key taken from it is `key = "!<program> get -- <account>"`. It runs
omapass in the harness's process, as a `!` key does, since the keyring
answers only outside the sandbox.

## `omunculus inbox_read`

- **Usage:** `omunculus inbox_read <inbox_id>`
- **Effect:** sets `INBOX.read_at`

Mark one notification read. The next `inbox` listing leaves it out.

## `omunculus reply`

- **Usage:** `omunculus reply <body> --request_id <id> [--option <name>] [--parts <json>]`
- **Effect:** comment + the tool calls of that option

Answer a request with text and optionally one of its options. The request
is closed and the body becomes a comment on it. Without an option no calls
run and no permissions are granted. With an option its calls run as steps
chained by `reply`, with `request_id` in their args and no ceiling check
from the command line. The requester's work, if it still waits on the
request, is reopened; when it is open after the option's calls, the
harness opens its next run, on the same stage, with the request thread in
its prompt. An option the request does not have is a refusal.

For an escalated request, `--parts` accepts a JSON object keyed by origin
part name, for example `'{"logo":{"body":"Use the attached logo"}}'`. Each
part takes `body`, optional `option` and nested `parts`. All selected origin
answers and effects commit together with the upstream answer, preserving the
original permission targets. Omitted parts return to pending for distribution.
Text alone resumes the intermediary without answering its origins.

A request from `request_access` has the options
`grant` (the name enters `WORKS.grants`), `grant_agent`, `grant_depth`,
`grant_stage`, `grant_workspace` (a permanent ceiling change: the file is
rewritten on that layer and `grants` is left alone; workspace scope writes
the workspace's own file when `[workspaces.<name>] config` points at one)
and `deny` (no call: the work runs again without the name). A request the
harness opened for a root work has `retry` (no call: the work runs
again) and `cancel` (the work is cancelled and never runs again).

## `omunculus comment`

- **Usage:** `omunculus comment <body> [--work_id <id>] [--request_id <id>] [--inbox_id <id>]`

Write a comment. At least one target. The store refuses a comment with none.

## `omunculus login`

- **Usage:** `omunculus login --provider <id> [--key <secret>] [--redirect_url <url>]`

Store a credential for an `[auth.<id>]` provider, in the JSON file
`[auth] store` names (mode 0600).

`api_key`: `--key` or a prompt on stdin (`api key: `). `oauth-code`: a
localhost callback, PKCE when the provider asked for it. `tool`: the
provider's `login` tool is dispatched instead (`cursor_login` is the
one the package ships).

A provider the TOML does not declare is `unknown auth provider: <id>`.
A model that needs a login and has none fails later with `` not logged in
to <id>; run `omunculus login --provider <id>` ``.

## `omunculus logout`

- **Usage:** `omunculus logout --provider <id>`

Remove that provider's record from the auth store. The TOML is not
touched.

## `omunculus cursor_login`

Cursor's browser login, as the `tool` kind behind an `[auth]` provider
that names it. Same contract as `login`; the bytes it stores are Cursor's.

## Errors the binary names itself

These are formatted on stderr before a tool runs, or after the store
refuses to open:

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
| `omunculus.toml [policy] last_run_output_bytes must be a positive integer` | `last_run_output_bytes` invalid |
| `omunculus.toml [policy] tool_output_bytes must be a positive integer` | `tool_output_bytes` invalid |
| `omunculus.toml is missing assemble` | no assemble tool named |
| `assemble returned an empty prompt` | assemble ran and produced nothing |
| `overrides.<tool>.chains names <name>, which the <tool> manifest does not chain` | an override widens `chains` |
| `overrides of <tool> leave a then outside its chains or with end not last` | an override breaks the `then` rule |
| `overrides.<tool>.schema names <variant>, which the <tool> manifest does not declare` | an override names an unknown schema |
| `` not logged in to <id>; run `omunculus login --provider <id>` `` | credential missing |

Anything else is `inspect` of the reason, or the tool's own `output`.

## Human requests

Create a question or decision in an existing conversation with `ask`:

```sh
omunculus ask --conversation_id <id> --question "Which deadline?"
omunculus ask --conversation_id <id> --question "Approve the scope?" --options '["approve","deny"]'
omunculus escalate --reason "Please answer these questions" --origins '{"deadline":"<request-id>"}'
```

`ask` needs conversation send access; `escalate` needs reply access and each
origin must be pending, addressed to the authenticated caller and in the same
conversation. `options` and `origins` accept JSON on the CLI. Optional `to` on
either form names a logical route configured in TOML. The caller does not
supply requester identity. Both use the model tools' store actions and reply
path, without opening a synthetic requester run. Their `end` step has no run
to end for a human command. An agent receiver opens a run normally; a human
receiver does not. A route that resolves only to the requester is refused.
