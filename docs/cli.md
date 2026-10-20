# The command line

<!-- Written by `mise run docs:cli` from lib/mix/tasks/omunculus.ex and priv/tools/*/tool.toml; edit those, not this file. -->

## The binary

The `omunculus` binary: `omunculus [--config <path>] <name> [--key value]`
dispatches the tool `<name>` through `Omunculus.CLI.main/1`, and
`omunculus serve --config <server.toml>` starts the HTTP server.

### Dispatch

`omunculus send` is the `send` tool, `omunculus inbox` the `inbox` tool:
the same `{name, args, view}` in and `{ok, output, emit, chain}` out the
model uses, with the trigger `cli`. Replacing the folder named `send`
replaces the command. A name the catalog does not hold is a refusal.

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

`omunculus serve --config <server.toml>` starts the HTTP server on the
projects its registry lists, until it is stopped.

## The commands

Each command is a builtin tool whose manifest lists the `cli` trigger.

### `omunculus ask`

```text
omunculus ask <question> [--options <options>] [--to <to>]
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
