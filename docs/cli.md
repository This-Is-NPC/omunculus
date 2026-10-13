# The command line

<!-- Written by `mise run docs:cli` from lib/mix/tasks/omunculus.ex and priv/tools/*/tool.toml; edit those, not this file. -->

## The binary

The `omunculus` binary: `omunculus [--config <path>] <name> [--key value]`
dispatches the tool `<name>` through `Omunculus.CLI.main/1`, and
`omunculus serve --config <server.toml>` starts the HTTP server.

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

`--config <path>` is the only flag of the binary itself, and it comes
first. Without it the file is `./omunculus.toml` in the working directory;
`bin/omunculus` passes that path unless the first argument is already
`--config` or `serve`, and makes a relative `--config` absolute against
the caller's directory. The project root is the directory of that file,
or its `[project] root` resolved against it; the store is its
`[store] path`, resolved against it too. No environment variable
chooses the file. A missing file is a refusal, except for a tool whose
manifest sets `config = false`, as `preset`, which writes the file.

After the name come `--key value` pairs, or one bare value, which goes to
the first required key of the tool's parameters: `omunculus send "count
to 5"` gives `message`. A second bare value, or a `--key` without a value,
is a usage error. A key the parameters do not list is still passed on.
Every value arrives as text; a tool that takes JSON decodes it.

### Output

Stdout is the tool's `output` and nothing else; an empty one is a
success with nothing to print. A refusal or a failure is one line on
stderr, a reason without a sentence of its own printed as the Elixir
term, and the exit status 1; success is 0, and there is no other. A
command that opens runs returns once every run it opened, directly or
through other runs, has finished, and fails with the errors of any of
them, one per line.

### The project's lock

A command takes the project's lock and first recovers what a process
that stopped left: it closes the runs left open and makes due again the
runs that never began. While a server holds the lock, the command goes
to it over the project's local socket, runs there as the local user,
under the project's `[access]`, and returns the same output. A project
held by another direct command is refused as in use.

### Commands that are not tools

`omunculus --config <project.toml> access bootstrap --issuer <issuer>
--subject <subject>` seeds the first project administrator; only the
owner of the config file may, and only while the project has no member.

`<name>` is recorded in the receipt (`preset <name> applied`). `--from` is
the directory that actually supplies the bytes: it must contain
`omunculus.toml`, and if it contains `tools/` that tree is copied beside the
file. `[tools] paths`, the `path` of each of its `[[packs]]` and
`[execution.sandbox] script` are rewritten to
absolute locations resolved against `--from`, and the `tools/` folder
beside the written file is appended to `paths`, so a checkout of
`priv/presets/default` keeps pointing at `priv/tools` and `priv/sandbox.js`
after the copy.

## The commands

Each command is a builtin tool whose manifest lists the `cli` trigger.

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

Asks a question or decision through configured request routing. question says what is needed and why, written to the receiver in their language as it should reach them, without request or work IDs, stage names or notes for agents; when the receiver is to pick one of named answers, name each in options (approve, deny, revise, ...), in the receiver's language, and say what each means in question: they get them as choices, and may still answer in words; never list the choices only in question. Omit options for a free-text answer. Optional to names a route in the project's request_routes; omit to to follow the default route. The run ends and resumes when the request is answered.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `question` | string | yes |  |
| `options` | JSON array | no |  |
| `to` | string | no | Optional name of a route in the project's request_routes. Omit to to follow the default route. |

### `omunculus changes`

```text
omunculus changes [--patch true] [--work_id <work_id>]
```

Lists the files the calls of a work changed, call by call, or with patch their unified diff: of this run's work, or of a work below it; from the command line, of the work named.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `patch` | boolean | no |  |
| `work_id` | string | no |  |

### `omunculus comment`

```text
omunculus comment <body> [--inbox_id <inbox_id>] [--request_id <request_id>] [--work_id <work_id>]
```

Writes a comment on the work, request, or inbox.

Also called by a model and a chain.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `body` | string | yes |  |
| `inbox_id` | string | no |  |
| `request_id` | string | no |  |
| `work_id` | string | no |  |

### `omunculus config`

```text
omunculus config [--item <item>] [--section <section>] [--whole true]
```

Reads the project's setup, as JSON. Without arguments, an index: the file's revision and, for each section (agents, workflows, models, workspaces, auth, secrets, packs, policy, access, names), each item's size in bytes. Then read a section whole with section, or one item with item: an agent or workflow with what the config runs, its pack and, as file, the table configure writes.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `item` | string | no | One item: &lt;section&gt;.&lt;name&gt; (agents.seller, secrets.&lt;tool&gt;), policy or access; with section, its name alone. |
| `section` | string | no | One section printed whole: agents, workflows, models, workspaces, auth, secrets, packs, policy, access or names. |
| `whole` | boolean | no | The whole setup at once, for a client; a real project's is longer than a call returns. |

### `omunculus configure`

```text
omunculus configure <item> --value <value> --revision <revision> [--from <from>]
```

Writes one item of the config (agents.&lt;name&gt;, models.&lt;name&gt;, workflows.&lt;name&gt;, workspaces.&lt;name&gt;, auth.&lt;name&gt;, secrets.&lt;tool&gt;, policy or access) from a JSON table, or removes it for null, while the file is at the revision config printed. The rest of the file keeps what it holds; a provider written without a key keeps the literal key the file holds for it; [auth] store and the tables of the process (project, execution, store, tools, mcp) are not items. A file changed since revision is refused with omunculus.toml changed since it was read; read it again. A result that does not load is refused with the reason, and the file stays as it was. The file is rewritten whole through a temporary file, keys in order and long text as multi-line strings. It needs project.manage_config.

Also called by a chain.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `item` | string | yes | The item: &lt;section&gt;.&lt;name&gt;, policy or access. |
| `value` | string | yes | The item as a JSON table, or null to remove it. |
| `revision` | string | yes | The SHA-256 of the file config printed. |
| `from` | string | no | An item of the same section removed in the same write, which renames it. |

### `omunculus cursor_login`

```text
omunculus cursor_login
```

Opens Cursor's browser login and stores the resulting credential: the login tool behind an [auth] provider of kind tool that names it.

### `omunculus escalate`

```text
omunculus escalate <reason> --origins <origins> [--to <to>]
```

Raises received requests you cannot answer as one question. origins maps each distinct part name to its received request ID; the receiver sees each origin's question and who asked it. reason is what the receiver is asked, written to them in their language as it should reach them: the merged question alone, without request or work IDs, stage or part names, or notes for agents. Optional to names a route in the project's request_routes; omit to to follow the default route. Routing chooses the next receiver. The run ends; the answer returns with the linked origins for distribution.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `reason` | string | yes |  |
| `origins` | JSON object | yes |  |
| `to` | string | no | Optional name of a route in the project's request_routes. Omit to to follow the default route. |

### `omunculus inbox`

```text
omunculus inbox
```

Lists unread notifications, one per line: id agent: body. An empty inbox prints empty inbox and still succeeds. Listing waits on no decision and parks no work.

### `omunculus inbox_read`

```text
omunculus inbox_read <inbox_id>
```

Marks a notification as read: the next inbox listing leaves it out.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `inbox_id` | string | yes | The notification, by the id inbox lists. |

### `omunculus login`

```text
omunculus login <provider> [--key <key>] [--redirect_url <redirect_url>]
```

Stores a credential for an [auth.&lt;id&gt;] provider in the JSON file [auth] store names (mode 0600). An api_key provider takes key, or reads it from stdin after the prompt api key: ; an oauth-code provider opens a localhost callback, with PKCE when the provider asks for it; a tool provider dispatches its login tool instead. A provider the TOML does not declare is unknown auth provider: &lt;id&gt;.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `provider` | string | yes | The [auth.&lt;id&gt;] provider. |
| `key` | string | no | The API key of an api_key provider; without it, read from stdin. |
| `redirect_url` | string | no | The callback address of an oauth-code login. |

### `omunculus logout`

```text
omunculus logout <provider>
```

Removes a provider's stored credential from the auth store; the TOML is not touched.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `provider` | string | yes | The [auth.&lt;id&gt;] provider. |

### `omunculus model_test`

```text
omunculus model_test <name> [--value <value>]
```

Sends one short prompt, without tools, to a model, as saved or as the JSON table value, and prints {"reply", "ms"}: its reply and how long it took, or why it failed. The provider's credential resolves as a run's does. A model the config lacks is no model &lt;name&gt;. A command model runs in the sandbox an agent's ceiling makes, so only a run tests it.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes | The model, by its name under [models]. |
| `value` | string | no | The model as a JSON table, as configure would write it; the file stays as it is. |

### `omunculus omapass`

```text
omunculus omapass
```

Prints, as JSON, what a client needs to take a provider's key from omapass, the optional Omarchy password plugin: installed and, once it is, program (the omapass on PATH, or the plugin's own under HOME), accounts (each password's account and folder, never a secret) and error when it could not list them. A key taken from it is key = "!&lt;program&gt; get -- &lt;account&gt;". It runs omapass outside the sandbox, as a ! key does, since the keyring answers only there.

### `omunculus overview`

```text
omunculus overview [--agent <agent>] [--whole true] [--workspace <workspace>]
```

Reads, as JSON, the project as it runs in each workspace. Without arguments, each depth's workflows with their stages and its agents, each named with its size in bytes; with agent, where that agent runs and, for each, its model, its key and its tools and skills classified by the ceiling there.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | string | no | The agent to read in full. |
| `whole` | boolean | no | Every agent in full at once, for a client; a real project's is longer than a call returns. |
| `workspace` | string | no | Only the place of this workspace. |

### `omunculus pack`

```text
omunculus pack <path> [--auth <auth>] [--depth <depth>] [--models <models>]
```

Imports the pack in path into the project, depth depths below its own when given: writes it to [[packs]] with the models its roles run on and the logins its providers stand for, and copies its workspace/ files where none are; without them, says what it needs.

Also called by a chain.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `path` | string | yes | The pack's folder, relative to the config's directory. |
| `auth` | string | no | provider=login pairs, comma separated: the config's [auth] provider each of the pack's stands for. |
| `depth` | string | no | How many depths below its own the team works: every agent and depth layer of the pack moves down that many. |
| `models` | string | no | role=model pairs, comma separated: the config's model each role runs on. |

### `omunculus preset`

```text
omunculus preset <name> --from <from>
```

Applies a preset: copies from's omunculus.toml onto the config path, and its tools/ beside it when there is one. [tools] paths, the path of each [[packs]] and [execution.sandbox] script are rewritten to absolute locations resolved against from, and the tools/ folder beside the written file is added to paths. A from that is not a folder holding omunculus.toml is unknown preset: &lt;name&gt;. It is the one command that runs without a config.

Runs without a project config.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes | The preset's name, recorded in the receipt preset &lt;name&gt; applied. |
| `from` | string | yes | The folder that supplies the files; it holds omunculus.toml. |

### `omunculus prompt`

```text
omunculus prompt [--run <run>]
```

Prints the assembled prompt of a run, by default the last one to start. No run is no runs, an id the store does not hold unknown run &lt;id&gt;, and a run that never attached an assembled prompt no assembled prompt.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | string | no | The run, by id; without it, the last run to start. |

### `omunculus reply`

```text
omunculus reply <body> --request_id <request_id> [--option <option>] [--parts <parts>]
```

Answers a request with text, optionally picking one of its options to run its tool calls.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `body` | string | yes |  |
| `request_id` | string | yes |  |
| `option` | string | no |  |
| `parts` | JSON object | no |  |

### `omunculus runs`

```text
omunculus runs [--agent <agent>] [--limit <limit>] [--run <run>]
```

Reads the project's last closed runs, newest first: for each, its agent, its work, how long it took, how it ended or that it stopped without end, its calls, those that failed or were refused, and what the model used; agent keeps only that agent's, limit fewer of them; run gives one of them call by call.

Also called by a model.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | string | no |  |
| `limit` | integer | no |  |
| `run` | string | no |  |

### `omunculus send`

```text
omunculus send <message> [--agent <agent>] [--attachments <attachments>] [--work_id <work_id>]
```

Delivers the message and opens the first run: of the work work_id names, else of the agent of depth 0 agent names, else of the agent the conversation began with, else of the only agent of depth 0. It writes PROMPTS(message) and EVENTS(prompt); it creates no work and copies the message onto no title. A work waiting on a request, or parked by break, is reopened first, with EVENTS(work) reason reopened_by_prompt; a work waiting on its children stays waiting, and the message opens a run of its agent. A successful send prints nothing: the assembled prompt and the model's text are in the store.

| Argument | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | string | yes |  |
| `agent` | string | no | The agent of depth 0 the message is for, when there is more than one. |
| `attachments` | JSON array | no | The files the message carries, each as the server kept it: name, media_type, bytes and sha256. |
| `work_id` | string | no | The work the message is for. |

### `omunculus tools`

```text
omunculus tools
```

Prints the project's catalog as JSON. Under tools, each tool, hook and skill with its name, kind, description, triggers, groups, the secrets it declares and the binding [secrets.&lt;tool&gt;] gives them, a skill's uses, its source (folder, inline or skill) and dir; under mcp, each [[mcp.servers]] with its command and secrets, since a server's tools are known only once a run starts it.
