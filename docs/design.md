# Design

This page is for contributors: what omunculus is, how the tree is laid
out, what each core module does, the run cycle that ties them together,
what it keeps on disk, the protocols it speaks, how it is packaged and
built, and what was measured. Its sections are numbered and the numbers
do not move: code and pages cite them as `docs/design.md §N`. What each
module does with the store, the TOML and the sandbox in detail is on the
other pages of [the map](README.md).

## 1. What it is and is not

Omunculus is a local harness that orchestrates tool-using models. A
project is one `omunculus.toml` and one SQLite store. A command or a
request records a message; the harness opens a run, assembles its prompt
with a tool, lets the model call tools inside the execution sandbox until
it calls `end` or stops, records every step as an event and applies the
store actions those tools emit. Works, conversations, memberships,
requests, notifications and workflow stages are rows of the store; the
harness only follows them.

It is not a chat page, a model host or a package manager. Configuration
comes only from the TOML: no default in code for anything the file holds,
and none in the store. What searches, filters or formats for the model is
a tool, never harness logic. The harness does not protect users from their
own tools and hooks; it guarantees the workflow sequence, the ceiling per
stage and the store rules.

## 2. Layout

Read the modules of §3 in the order they are listed.

```text
bin/omunculus        shell wrapper: mise exec -- mix omunculus
apps/console/        the window: QML on Quickshell, a client of the server's local socket
apps/mailbox/        the mailbox: an e-mail client over the projects
apps/studio/         the studio: the project's settings
apps/kit/            what the apps share: ui/, the theme and controls, client/, the curl
                     requests to the server's sockets, the request helpers and the scripts
                     that send and open attached files, and run, the launcher of every app
lib/omunculus/       core, config, server, tool, tools, hooks, models, execution, store
lib/mix/tasks/       the omunculus mix task
priv/tools/          builtin tool and hook manifests
priv/presets/        default, codex-like, pi-like
priv/packs/system/   the system team: the steward, the auditor and the refiner, their portraits and their
                     skills team-design, team-composition, configure, audit, refine
priv/sandbox.js      tool-call bridge run by Omunculus.Sandbox
test/omunculus/      mirrors lib/; matrix_test.exs and spec_regression_test.exs are the scenario suites
test/support/        fixtures, store case, scripted model, chain tool, execution policy
                     fixtures, command model bridge, MCP server, Rust OpenAI stub
bench/               resident capacity benchmark
packs/               teams distributed as packs (Config.Packs), each with the eval tasks that
                     show it works: dream-team, which builds and publishes, with its tools,
                     workspace files and environment; sales-desk, a front desk,
                     a project manager and a seller that answer clients and
                     work over the dream team; design-team, which shows the client
                     a preview of the site before it is built
eval/                Equivalent Exchange, the behaviour benchmark: the Amestris preset,
                     its configurations, tasks and runner (mise run eval:run); each run
                     writes eval/results/<time>-<label>/, ignored by git
docs/                the documentation; README.md is its map, cli.md is written by docs:cli
scripts/             the jobs mise.toml runs as tasks: validate-*, check-*, docs-cli, up, dev-*,
                     benchmark-*, eval-*
dev/                 the development environment, local and ignored by git
```

## 3. The modules

### `Omunculus.CLI`

Direct entry point. `omunculus [--config <path>] <name> [--key value]` dispatches a tool with trigger `cli` through `Operations`, then follows up its events. `access bootstrap` seeds an administrator. The CLI only reads the command line into a tool and its arguments, through the tool's manifest, and calls `Operations`, as the HTTP router does with a request; `Errors.format/1` gives both the same sentence for an error, to which the CLI adds the command that resolves it. Without `--config` the file is `./omunculus.toml`; `bin/omunculus` passes `--config $PWD/omunculus.toml` unless the first argument is already `--config` or `serve`, and makes a relative `--config` absolute against the caller's directory. A missing file is a refusal, except for a tool with `config = false` (`preset`). When a server holds the project's lock, the tool and its arguments go to `POST /v1/call` on the project's local socket, and `access bootstrap` to `POST /v1/access/bootstrap`; the command returns once the runs it opened there have finished, with what they gave the person after its output (`Operations.reply/2`, [the command line](cli.md#output)). Taking the lock itself, a command first recovers the project (`Run.recover/1`), in the same cycle as its own runs. Reads no environment variables.

### `Omunculus.Project`

Opens the SQLite file `[store] path` names and holds the connection, the config path, and the cycle the runs opened through it join. CLI and server acquire an OS file lock for exclusive project ownership.

### `Omunculus.Cycle`

The runs commands open, each in a process of its own. A command returns once every run it opened, transitively, has finished, and fails with the errors of any of them; in the server's persistent cycle, `command/3` waits only for the runs of its own command, those made due by its process or by those runs. A work has one run at a time: runs due for a work with a run open wait for it, in the order they became due; a work's own run due while another waits is merged into it. A run without a work that creates the root holds the root's turn until it finishes. The runs due and not yet begun live only in the cycle's process; `Run.recover/1` finds again from the store those a stopped process lost.

### `Omunculus.Config`

Loads and validates `omunculus.toml`: the project's `root` and optional `conversations`, policy (including `assemble`, the required `max_retries` and the optional `default_agent` (an agent of depth 0 that is not workflow-only, shown to clients by the `config` tool's `policy` section), `max_reopens`, `report_required` (the report fields every ending report must give), `last_run_output_bytes`, `tool_output_bytes`, `conversation_bytes`, `send_catalog`, and `session_ttl_ms` with `session_max_bytes`), depth layers, workspaces, agents, an agent's optional `image`, a picture relative to the config (or to its pack's folder), workflows (each layer with its per-tool `overrides`; the `workflows` of `[policy]`, or of a depth layer for its depth, are those a work there must go through one of, and without them a work may go through any workflow whose stage agents are of its depth), models, `[auth]`, optional `[accounts]` (the names `to` takes) and `[access]` role definitions, MCP servers, `[skills] paths`, `[secrets.<tool>]` (and an MCP server's `secrets`) binding the secrets a tool's process receives to `[auth]` providers, `[store]` (with an optional `changes`, where the files each call changed are kept, and an optional `attachments`, where the files attached to conversations are, which comes with `attachment_bytes`) and the required `[execution]` table (including `resources`, `max_concurrent`, `max_queue` and `queue_timeout_ms`, and the optional `host`, `deny_read`, `read`, `write` and `variables`). `[[packs]]` imports teams (`Config.Packs`; see [packs](packs.md)). a workflow's optional `isolate = "worktree"`; `Config.Layer` is one ceiling layer; `Config.Toml` encodes the file. Also rewrites the file for permanent grants and for `edit/5`, which writes one item a client edits (an agent, model, workflow, workspace, `auth` provider or tool `secrets`, or the `policy` or `access` table) while the file is at the revision `document/1` read and the result loads; either way it replaces the file whole through a temporary file.

### `Omunculus.Harness`

Discovers the catalog, checks the trigger, hydrates the views a manifest declares, resolves the secrets a tool declares through `Omunculus.Secrets`, invokes the tool and the steps it chains with them, masks their values in what it returns, records `EVENTS(tool)` for each, and applies all their emitted actions in one transaction; with `[store] changes`, a model's call in a run that may write its workspace is bracketed by snapshots of the workspace's tree (`Omunculus.Changes`, git run on the harness side, outside the sandbox, in a bare repository of its own), and the files it changed, with the two trees, go in its `EVENTS(tool)` as `changes`; a model's call whose actions the store refuses is recorded as failed, its output the refusal, and applies none of them. `end` is the only event that ends a run. Hooks of every other event run immediately; hooks of `end` wait until the run has closed and the runs its events ask for are due. `open_due/2` (after each model call) and `follow_up/3` (after the close) write permanent grants to the TOML before making runs due; an upstream text `reply` resumes an intermediary with unresolved origins even while its work waits on children; a human requester needs no run. A normal `reply`, with text and an optional option whose calls run, opens a run of the requester's work when that work is open, or, for a request from a run without a work, a run of that run's agent in its conversation.

### `Omunculus.Run`

Opens one run, holding a slot of the execution limiter's `run` class (`[execution]` `max_concurrent`, `max_queue`, `queue_timeout_ms`): resolves the agent from the stage of the work's workflow, the work's assignee or, for a message without a work, the agent of depth 0 the message is for — the one it names (`send --agent`), else the one its conversation began with, else the only one, decided and recorded when the message is stored, which refuses it otherwise; a work that names no agent where its depth has several is refused too, and an unnamed root is its creating run's agent's, unless depth 0 requires no workflow and depth 1 requires one, in which case that workflow's first stage takes the root — a work's own run takes the greater of its place in the tree and its assignee's depth — mounts the ceiling, builds the execution policy (with `[policy] send_catalog` the model is sent every model tool of the catalog, so all agents' requests start alike, and may call only its own; a call to another is refused and recorded as failed), begins the run with the event that made it due as its `cause_id`, dispatches the `assemble` tool, attaches `PROMPTS(assembled)` and, when the tool continues the agent's paused session on the work, a `session` event naming the run it continues and what it was told had happened since, drives the model until it calls `end` or stops — its calls and their reactions reuse the config and catalog it prepared (`Harness.prepared/3`) rather than loading them again — making the runs each call's actions ask for due at once, and handing the run the messages sent to its work since it began that no run has told (`Store.deliver/3`, which records them as `news` events, and the adapters put them after the results as user messages; [the cycle](cycle.md#a-message-during-a-run)) — on a work's own run whose model has `handoff_tokens`, past that many tokens of request, as the reply's `usage` reports them, only `comment`, `done`, `continue` and `break` run, and the comment, the run's report, stops it — closes the run, then retries a work whose model stopped without `end`, a model that fails or crashes counting as one that stopped, its `end-run` carrying `error`, why in a sentence (`Out.model_failed/1`, one formatter for every adapter's errors); over `max_retries` it breaks a child work and opens a request to the account that opened the conversation, with `retry` and `cancel` options and an inbox entry, for a root work. A cancelled work opens no run; a work's own run does not open once the work is no longer open. A work of a workflow with `isolate = "worktree"` gets its root from `Omunculus.Worktree`: `Harness.workspace_context/3` returns the work's worktree, `Run` creates it before assembling and removes those of works that ended once a run closes and on `recover/1` ([the cycle](cycle.md#a-worktree-per-work)). `recover/1`, when the server opens a project or a direct command takes its lock, closes the runs left open and makes due again what a stopped process lost: the runs events asked for and no run began for (`Harness.lost/1`), a retry decision never applied, a request left at an agent, and a message's run, which has no work to retry, opened again for its message up to `max_retries` runs unless it had called `end` ([the cycle](cycle.md#a-process-that-stops)).

### `Omunculus.Ceiling`

Intersects the policy, workspace, depth, agent and stage layers into the effective tool set of a run and classifies a name as have, askable, sealed or blocked. `pinned` intersects the same way and marks which effective tools become cards when `tool_search` is present. The same layers resolve the run's per-tool `overrides`, the most specific layer winning per key; the snapshot carries them.

### `Omunculus.Participant`

Builds authenticated human and configured agent request identities from the action context and formats their labels. Identities are stored as JSON; callers cannot supply another participant's authorship.

### `Omunculus.Accounts` and `Omunculus.Store.Destination`

`Accounts` parses `[accounts]` once into `Config.accounts` and reads a `to` name: an account's identity, else the agent of that name. `Store.Destination` resolves the arbiter of a request from the authenticated asker, its work and the conversation. Without `to`, it is the assignee of the asker's parent work, with that work as the arbiter's; for a root work, the conversation's `created_issuer` and `created_subject`, the requester, or the run's origin when there is no conversation row. With `to`, an unknown name is refused with the names `to` takes, the asker itself is refused, and an agent must be an ancestor's assignee, or depth 0 and able to run without a workflow. The arbiter is never one of the excluded participants (the origins' requesters and the agents that answered an origin with text alone): then nobody is left and the action returns `no_route`. Escalation is the same resolution from the escalator's own work. The opening `request` event records the `requester` and the `arbiter`; nothing else about the addressing is stored ([requests](requests.md#who-a-request-goes-to)).

### `Omunculus.RequestOptions`

The store's recursive validation and authorization of request replies: lifecycle state, selected options, named origin parts and permission boundaries on the original targets. An agent cannot answer a request with a sealed grant option, including with deny or text; it must escalate for a human decision. The reply tool normalizes its arguments and builds chains; it leaves these checks to the store's transaction. The HTTP router checks required text and an optional nonempty option at the command boundary.

### `Omunculus.Store` and `Omunculus.Store.*`

The only code that touches SQL. `Connection` is the one process that owns the SQLite handle; every statement and transaction runs in it, so concurrent runs apply their transactions one after another, and it announces committed events to the processes subscribed to it. `Access` checks project and conversation memberships, scopes reads, and manages idempotent command receipts. `View` reads cuts of the tables, including recursively linked request origins and their questions; the inbox source with `relation = "received"` reads pending requests addressed to the current run's agent, in its conversation at depth 0 and, at any depth, those whose arbiter run opens on its work or below, grouped by conversation and hydrated through the canonical request view. Escalated origins appear only as provenance, and reading does not resolve requests. `Actions` applies emits (`comment`, `request`, `escalate`, `reply`, `grant`, `cancel`, `work`, `delegate`, `continue`, `break`, `wait`, `end`, `notify`, `prompt`, `attach`, `artifact`, `memory`, `compact`, ...); it refuses `end` on a work's own run that would leave the work open with nothing to run it again — no request of it pending, no run of it due since the run began — or with a child that broke waiting on it; a request stores JSON `requester` and `arbiter` participant identities (agent name, or authenticated human issuer/subject), with `pending`, `escalated` and `closed` statuses; it carries named options of tool calls and its arbiter is resolved in the store: an option calling a tool only a human may give remains subject to that authorization boundary, while its receiver follows the first matching TOML route; `to` is an optional logical route name; a request's view gives the option its reply chose (`answer`), nil for a text-only answer; its closed status and reply comment distinguish that from an unanswered request. `escalate` merges received pending requests in the same conversation into one linked request and preserves child waits, and never routes an origin to an agent it was already escalated to (`request_escalations`) that answered with text alone, naming no part, without escalating it further; recursive named reply parts retain the actual answerer and original grant targets, while omitted parts return to pending. `Runs` and `Events` write the run lifecycle; `Runs.record_tools` records a call and its chained steps as one transaction; `Runs.unreported` decides a retry, break or request in one; `Runs.unanswered` uses the same linked action for a pending request left unanswered by its receiver and names, in the linked request's reason, the receiver and each question it held — who asked it, the title of their work and the question, shortened, never an id — and writes the same as an inbox note when the linked request reaches a human; requester and arbiter identities remain immutable. `Omunculus.Jobs` folds the `job` and `job_fire` events into scheduled jobs, as memory is folded (see [Jobs](#jobs-as-events)). `Schema` creates thirteen tables, including append-only `request_escalations` and `interceptions` (the action a review holds, its actor and its reviewers left; `Store.Interception` opens a review from a matching `[[interceptors]]` rule and releases the action on approval, every event it writes carrying `events.released_by`; a released tool is run first in the actor's next run on the review, `Harness.run_released/4`, with that run's execution context), and refuses a store whose tables differ from them, or that lacks one, with `store_requires_recreation`.

### `Omunculus.ConversationRoot`

With `[project] conversations`, the folder each conversation works in, `<workspace root>/<conversations>/<conversation id>`, the root of its runs and calls in place of the workspace's (`Harness.workspace_context/3` picks it from the call's run, work or context). The first time one is needed it starts as a copy of the workspace's files, without the conversations' folder and what omunculus keeps there, copied beside it and renamed into place ([config](config.md#a-folder-per-conversation)).

### `Omunculus.Attachments`

Keeps the files attached to conversations in the directory `[store] attachments` names, each under its SHA-256, within `[store] attachment_bytes`, and checks a description `{name, media_type, bytes, sha256}` against the file kept for it. The event that carries a file describes it — a message's `prompt` or a run's `attach` — and the store checks each description it records; there is no table of attachments.

### `Omunculus.Artifacts`

The documents agents make and hand on, as typed, versioned records over the content `Omunculus.Attachments` keeps ([§10](#10-artifacts)). Names and kinds are checked here; the store assigns each version the number after the last of its name in the conversation, in the transaction that records the `artifact` event.

### `Omunculus.Operations`

Shares tool dispatch, human authorization and cycle follow-up between the direct CLI and HTTP commands. `reply/2` reads, once a command's runs have finished, what the runs it caused gave the person: the replies of agents without a work, their reports on root works and their questions to accounts (`Store.said/2`).

### `Omunculus.Server` and `Omunculus.Server.*`

Optional Bandit/Plug HTTP server. Its TOML registry maps project IDs to project configs and holds run/stream limits; an optional TCP listener (`host`, `port`) comes with `[auth]`, which maps JWT claims to human principals. Each project owns a persistent cycle in `Server.Project`, whose process only opens and closes the project and keeps it as its registry value: every read and command runs in the request's own process, so a command held in its tool or hooks keeps no other request waiting, and a request that crashes still answers `500` with the contract's error body. `Server.Socket` serves the project on `<store>.omunculus.sock` (mode 0600) as the local principal, the one the direct CLI uses; only there, `POST /v1/call` runs a tool through `Operations.command/4`, `POST /v1/access/bootstrap` seeds the first administrator, `POST /v1/projects` starts another project under the running supervisor (`Server.register/3`) and writes it into the registry file, and `GET /v1/projects` lists every project the supervisor runs with its socket, where over HTTP it lists the projects the user may read; `GET /v1/projects/:id/agents/:agent/image` serves an agent's image. The versioned contract exposes scoped conversations, snapshots, events, a WebSocket event stream (`Server.EventStream`) of a conversation or of every conversation the principal may read, the works of those conversations (`GET /v1/projects/:id/works`, by `state`) and typed commands; the core store enforces access. `OpenAPI.route` registers a Plug route and its operation together; `/openapi.json` renders an OpenAPI 3.1 document from these declarations and schemas in `OpenAPI`.

### `Omunculus.Tool.Catalog`, `Manifest`, `Views`, `Overrides`, `Invoke`, `Omunculus.Skills`

Discover `tool.toml` / `hook.toml` folders, Agent Skills and MCP servers, parse manifests (including `chains`, `then`, `secrets`, named `schemas` and `[views.<key>]` tables), parse and hydrate a call's views — each a core `source` read from an anchor (`from`) with that source's options, scoped to the call's conversation — apply a run's `overrides` (`then`, `chains`, `schema`) to the catalog, and call a tool either as an Elixir module or as an external command fed JSON on stdin. `Manifest.card/1` is `- name: description [tags: a, b]`; no tags, no suffix.

### `Omunculus.Tools.*`, `Omunculus.Hooks.Noop`

The builtin tools. Each has a manifest under `priv/tools/<name>/` and a module here; `write`, `edit` and `patch` end by `Tools.Format`, which runs the `[settings.format]` command of each written file's extension inside the run's sandbox and says in the tool's output when it changed the file or failed, never undoing the write; the builtin hooks (`on-request`, `on-notify`, `on-continue`, `on-break`) all use `Hooks.Noop`. The model tools that hand a work away (`work`, `done`, `break`, `wait`, `request_access`) take a `report` and end the run through `then = ["end"]`; `wait` parks a root work until its person's next message; each work `work` creates may name its `agent` or its `workflow`, which the work keeps and goes through; `delegate` and `continue` are chain-only steps of `work` and `done`; `grant` and `cancel` are chain-only steps of `reply`, which omits null or empty options, answers with text and chains a chosen option when given; `forward` hands what the person said to a root work of the run's conversation still open, as a message that opens a run of it, and the store refuses a run's message to a work of another conversation; `reopen` sends a work below the run's own that broke back to its agent, another named at its depth, or, in a workflow, the agent of a stage it names up to its own, from which the work goes through the stages after again, with instructions, granting it on that work the names it lists that the parent could grant on a request, and ends the run, and delegating, continuing (`done`) and ending are refused while such a work waits on the parent; `retire` cancels such a work with a report and lets the run go on, to hand out what must come first and a new work after it; past `[policy] max_reopens` reopens of one work in a row, `reopen` asks instead, on the `owner` route where the project names one, else along the parent's route; `config` and `overview` print the project's setup, logins' keys left out, whole for a client with `whole` and otherwise in parts a call returns — an index, then a section or an item of the config, which includes `tools`, the catalog the project has whether an agent is granted a tool or not, or one agent where it runs; `propose_config` lays the keys of a change over the table the file holds for the item (a key left out stays, a `null` removes it, a list replaces the file's whole), loads the config that would make and, only when it loads, asks the person in a request showing the item as the config runs it before and after, and the runs it cites, whose `apply` option calls `configure` with the merged table at the file's revision, ending the run; it refuses a cited run that is not among the `recent` runs, a change that leaves the item as it is and one equal to a change the person already refused in the conversation (the `requests` view's `answered` relation); each refuses a change whose agents lack a step a tool of theirs that ends the run chains (`Tools.Steps`); `propose_pack` does the same for importing a pack, its `apply` option calling `pack`, and says each of the pack's agents at the depth and on the model it would run, and what its `environment/` holds; `ask` and `escalate` accept model and CLI calls; human creation needs conversation send access and human escalation needs reply access and matching received origins. They reuse the same request actions, with no synthetic requester run; their `end` step emits nothing when no run exists. `escalate` merges named origins and ends a model run; `reply` accepts recursive named parts; its effects and human-only sealed and permanent grants are validated in the store transaction against their original targets. `ask` asks a free-text question or, with named options that call nothing, a decision, through the configured route, with optional `to` naming a logical responsibility, as on `request_access` and `escalate`; `request_access` asks in one request for every tool, path, directory and sandbox capability it lists, each option granting them all; `changes` lists, call by call, the files the calls of the run's work or of a work below it changed, or their unified diff, as `[store] changes` recorded them — from the command line, of the work named, with read access to its conversation — and `revert` puts those files back as they were before the work, refusing when one changed since — from the command line, or the server's `POST /works/{id}/revert`, of the work named in the workspace it ran in, each file writable under that workspace's write rules with the person granting `sandbox.write` unless a layer denies it (`Harness.workspace_policy`); `skill` reads one of the skills the run has, which `assemble` lists under `## Skills`; `merge` merges the branch of a done work below the run's into the run's root through `Worktree.merge/2`, aborting a conflict and naming its paths; `runs` sums up the project's last closed runs, of every conversation, through the `runs` view source's `recent` relation — how each ended, its calls, what failed, what the model used — or gives one call by call. `attach` keeps a file under the run's roots, as it is then, as an attachment of the run's conversation, with an optional `note`, through `Omunculus.Attachments`; `read_attachment` reads one of the conversation's attachments by its `sha256`, which `assemble` lists under `## Attachments`, read through the `events` view source with `relation = "attachments"`. The default `assemble` also reads `inbox` with `relation = "received"`: at depth 0, `## Inbox` groups the pending requests addressed to the run's agent by its conversation, with original questions, identities, works and historical workflow/stage, including linked parts; it does not repeat the request that opened the run there and under `## Request`. This inbox is included in a continued session's news too. On a work, `## Children` lists every work handed down from it as it stands — title, agent, id, workflow stage and state, one that broke marked as waiting on the run to reopen it, retire it or break the work, one that is done with its report unless `## Results` has it — in a fresh prompt and in a continued session's news alike. `Tools.Session` rebuilds, from the work's closed runs, or for a run without a work from its conversation's closed runs that had none, the session a run continues: with `[policy] session_ttl_ms` and `session_max_bytes`, a run of the agent whose last run there paused (an answer, a request, children, a wait for the person, a retry) recently goes on as the same conversation, under the instructions it started with, and is told only what happened since; a session that cannot be rebuilt exactly, or a hand-on (`continue`, `break`), starts over. A run without a work is shown the requests its agent raised in the conversation that were answered, with the option picked and the reply, under `## Answered`, and its conversation's root works under `## Works` and, when its session starts over, what the person and the agent said there under `## Conversation` — of the agent, its last reply that called no tool, not the text it wrote beside its calls — each the newest that fits `[policy] conversation_bytes`.

### `Omunculus.Sandbox`

Runs the code the model submits inside the execution sandbox and answers each `tools.<name>(args)` call it makes.

### `Omunculus.Execution.*`

Starts every external process through Bubblewrap under an immutable per-run policy, with concurrency, queue, timeout and output limits. A command's script (the loop of the `bash` tool's shell) reaches `sh` as a read-only file in that same temporary directory and never as an argument, so no process's command line holds it and `pkill -f` from the script cannot match the sandbox itself; a runner that dies before writing its status is reported as `{:bubblewrap, {:killed, status}}`, apart from Bubblewrap failing to start it, which is `:setup_failed`. A command's secrets reach its process alone, as read-only files at `/run/secrets/<NAME>` named by `<NAME>_FILE`, written into that process's temporary directory before it starts and removed with it; the policy never holds them. With `[execution] host`, a command sees the machine read-only as the person does — their home overlaid so that what it writes there stays in the run's scratch, `/run` hidden but for the resolver, and what `deny_read` names (and the logins store) hidden — and writes only the workspace, given `sandbox.write`, and what `write` names (what `read` names is mounted read-only in either mode, and `variables` sets environment variables, so a command resolves the person's mise installs); without it, it sees only the runtimes, the workspace and the folders the catalog's tools were found in (each folder of `[tools] paths` whole, so the tools of one path share what lies beside them)), and, written like its secrets into its temporary directory, an `/etc/passwd` and `/etc/group` of its own that name its user `omunculus`, with its ids and `/tmp/home` as its home, so that `id`, `ssh` or `git` find who runs them without the machine's accounts. A run's commands share its scratch, a directory beside the store (`<store>.scratch/<id>`) bound as their `/tmp`, home within, kept from one command to the next and outside the workspace — with `[execution] host`, its home overlay is mounted by one command at a time, the next waiting for it under `flock` within its own timeout, because the kernel lets one mount use an overlay's upper and work directories; every process of a command ends with it, background ones included, so none outlives it to hold the overlay; the run removes it when it ends, and opening the project with its lock removes any a run left.

### `Omunculus.Mcp`

JSON-RPC to one MCP server, run through the execution sandbox, for discovery and calls.

### `Omunculus.Model.Fake`, `OpenAI`, `OpenAIResponses`, `AnthropicMessages`, `Command`

Model adapters, picked by `api` in `[models.<name>]`. `api = "module"` names an Elixir adapter: `Fake` echoes the first prompt line. `openai-completions` posts to `/chat/completions`, `openai-responses` to `/responses`, `anthropic-messages` to `/messages`; with `stream = true` they read the reply as server-sent events through `Model.EventStream`. The HTTP adapters record the server's `usage` with each reply and keep it out of the next request; `anthropic-messages` marks two cache breakpoints, the end of the instructions and the end of the last turn. Each HTTP adapter merges the model's `body` table over the request it builds — an `anthropic-messages` model sets there the `max_tokens` a reply may take, thinking included, which loading refuses it without — and with the model's `retries` sends a request again on a rate limit or a server error, after the delay the server asks for (`Model.Retry`); a call whose arguments are not a JSON object goes back to the model as that call's result (`Model.Arguments`). With the model's `code_mode`, they also offer `__omunculus_execute`, which runs JavaScript in the sandbox calling `tools.<name>(args)` through the same authorized, recorded path as native calls (`Omunculus.Sandbox`); without it, they do not. `command` runs an external program over the sandbox NDJSON protocol, where `{type: delta, text}` lines carry partial text. An adapter is a `(prompt, tools, call, record, delta, execution)` fun, where `prompt` is an `Omunculus.Prompt`: the assembled `instructions`, which the HTTP adapters send apart from the run's `context` (a `system` message, the Responses `instructions`, a cached Anthropic `system` block) so the provider can reuse them from its cache, and, continuing a session, its `history`, which they send as the conversation it was; `record` writes `EVENTS(model)`, `delta` publishes partial reply text on the store connection without recording it.

## 4. The run cycle

```text
omunculus send "text"
  → tool send emits prompt → PROMPTS(message) + EVENTS(prompt)
  → follow_up/3 makes a run due in the cycle; each due run opens in its own
    process, within [execution] max_concurrent
      Config.load, Catalog.discover, Ceiling.mount, Overrides.apply, Policy.build
      RUNS + EVENTS(start-run)
      assemble tool → PROMPTS(assembled) + EVENTS(tool)
      model → tool calls → EVENTS(tool) per call and chained step
              + emitted actions + hooks
        → a call without end: open_due/2 makes the runs its actions ask for due at once
        → past the model's handoff_tokens: only comment, done, continue and break
          run; the comment stops the run
      until the model calls end (EVENTS(end)), stops (EVENTS(model)) or fails
      EVENTS(end-run), with {"error": why} when the model failed, RUNS.status = done
  → follow_up/3 makes the runs the ending call asked for due, runs the hooks
    of end, then makes the reaction runs of calling hooks due
  → a model that stopped without end or failed on a work still open: a run with
    via = retry on that work, or, once [policy] max_retries is used up, a
    break (a child) or a request with retry / cancel to the requester (a root)
  → the command returns when every run it opened, transitively, has finished
```

## 5. State on disk

Everything a project keeps lies where its `omunculus.toml` says
([the TOML](config.md)); paths are relative to that file.

| What | Where | Written by |
| --- | --- | --- |
| The store: twelve tables, conversations and their members, project members, command receipts, prompts, events, runs, comments, works, requests, request escalations and the inbox | `[store] path`, one SQLite file, with its `-wal` and `-shm` files | `Omunculus.Store` alone |
| The project's lock | `<store>.omunculus.lock`, held through `flock` | the CLI or the server that opened the project |
| The local socket | `<store>.omunculus.sock`, mode 0600 | `Omunculus.Server.Socket`, while a server holds the project |
| A run's scratch, its `/tmp` and home | `<store>.scratch/<run id>` | `Omunculus.Execution`; removed when the run ends, and on the next open with the lock |
| The files each call changed | the bare git repository `[store] changes` names | `Omunculus.Changes` |
| Attached files and the content of every artifact version | `[store] attachments`, each under its SHA-256 | `Omunculus.Attachments` |
| Stored logins | the JSON file `[auth] store` names, mode 0600 | the `login` tool |
| A work's worktree | `<workspace root>/.omunculus-worktrees/<work id>`, on the branch `work/<work id>` | `Omunculus.Worktree`; removed when the work ends, the branch kept |
| A conversation's folder | `<workspace root>/<[project] conversations>/<conversation id>` | `Omunculus.ConversationRoot` |
| The config itself | `omunculus.toml`, rewritten whole through a temporary file | `Omunculus.Config`, for `configure` and permanent grants |

The store refuses tables that differ from its schema with
`store_requires_recreation`; there are no migrations.

## 6. Protocols

- **The tool contract.** Every tool, builtin or external, takes
  `{name, args, view}` and returns `{ok, output, emit, chain}`: an Elixir
  module is called, a command is fed JSON on stdin inside the sandbox
  ([tools](tools.md)). The command line is the same contract with the
  trigger `cli` ([the command line](cli.md)).
- **The server's `/v1` contract.** HTTP on the project's local socket, as
  the local user, and on an optional TCP listener with signed JWTs; a
  WebSocket event stream; the OpenAPI 3.1 document at `/openapi.json`
  ([the server](server.md)). It is the only thing the apps and the core
  share ([clients](clients.md)).
- **The sandbox bridge.** `priv/sandbox.js` runs under Deno inside
  Bubblewrap and answers `tools.<name>(args)` calls of code the model
  submits; a `command` model speaks NDJSON over it.
- **MCP.** JSON-RPC to each configured server, run through the execution
  sandbox, for discovery and calls.
- **Model APIs.** Anthropic's Messages API and OpenAI's Responses and
  Chat Completions APIs over HTTP, with server-sent events when `stream`
  is on ([the TOML](config.md#models-and-auth)).

## 7. Packaging

A release is two Arch packages built by `packaging/arch/PKGBUILD` from
`git archive HEAD` of the tagged tree: `omunculus` (the `mix release` with
its ERTS under `/usr/lib/omunculus`, the `omunculus` launcher, the builtin
tools, the system pack and the systemd user unit) and `omunculus-apps` (the
QML apps, their launchers, desktop entries and icon). The domain packs,
`eval/`, `bench/`, `dev/` and `test/` stay out of both. `scripts/package`
builds them with the toolchain `mise.toml` pins, the release workflow
attaches them with a `SHA256SUMS`, and `install.sh` and `omunculus update`
install them with `pacman -U` after checking it. The package depends on the
libcrypto soname of the openssl its Erlang was built against. See
[how to install, update and remove](how-to-install-and-remove.md).

From a checkout, `bin/omunculus` runs `mise exec -- mix omunculus`, so the
Elixir, OTP and Deno pins of `mise.toml` are the ones that run. Teams come as
packs: the system team under `priv/packs/system`, the others under `packs/`
([packs](packs.md)). The apps run on Quickshell from `apps/`, each through
`apps/kit/run` ([clients](clients.md)).

## 8. Building and checking

```sh
mise install                    # toolchain from mise.toml
mix deps.get
mix compile --warnings-as-errors
mise run pre-commit             # validate:boundaries, mix format --check-formatted, check:cli, check:links
mise run check                  # check:cli, check:format, check:links, check:qml and check:spacing
mise run docs:cli               # write docs/cli.md from the commands
mise run validate:regular       # mix test --exclude cargo --exclude sandbox
mise run validate:sandbox       # needs Linux with Bubblewrap namespaces
mise run pre-push               # validate:regular
bin/omunculus preset default
bin/omunculus send "text" --agent concierge
bin/omunculus serve --config server.toml
apps/kit/run console --config server.toml [--project <id>]
apps/kit/run mailbox --config server.toml [--project <id>]
apps/kit/run studio --config server.toml [--project <id>]
mise run package                # the Arch packages of HEAD into target/arch/pkg
mise run test:install           # install, use and remove them in a disposable container
mise run up                     # the dev server; the apps open with dev:console, dev:studio, dev:mailbox
```

`<id>` is a placeholder for a project id of the registry. Before a commit,
`mise run pre-commit` and `mise run validate:regular` pass and
`mix compile --warnings-as-errors` is clean. The development server and
its tasks are on [the development environment](development.md).

### Testing the install

`mise run test:install` builds the packages (`package`), then runs
`scripts/test-install`. It needs Docker, network access and a `makepkg` that
runs as your user. The script copies the packages, a `SHA256SUMS` and
`install.sh` into a fresh, unprivileged `archlinux:latest` container with no
init, as a user with `sudo` and no `LANG`. It removes the container and its
temp files on exit, even after a failure, and touches no other container.

It asserts, and stops at the first mismatch:

- `install.sh` with `DRY_RUN=1` (with and without `APPS=0`), a tampered
  checksum, a missing release, and the `cat install.sh | bash` form;
- the install of both packages: `omunculus version` without a locale
  warning, the files and launchers, and no `eval/`, `bench/`, `dev/`,
  `test/` or domain `packs/` in the packages;
- `omunculus preset default`, `send` and `runs`, on the fake model;
- `omunculus setup` twice, and `systemd-analyze verify` on the unit;
- the server: the unit's own `ExecStart` runs as the test user. A project
  without `[access]` is refused in the log while the server stays up. After
  an `[access]` table and `access bootstrap`, `omunculus socket` and the
  socket answer, and `send` succeeds while the server holds the project's lock;
- `omunculus update` against the real GitHub API;
- a lower version, built by editing the `pkgver` of the package, then back up
  with `pacman -U`, which print the restart message;
- `pacman -R`, which prints the `systemctl --user disable --now` message,
  followed by stopping the server and checking that no process, binary or
  package remains, and that the config and the project stay.

The container has no systemd user manager, so `systemctl --user enable --now`
and the restarts are not exercised for real; the unit tests cover them with a
fake runner, and `setup` must say that the unit is enabled but not running.
`update` can only reach the real release, which carries no packages until one
is published, so the test checks its wording and exit code only.

The release links the `libcrypto` of its build machine, so the package
depends on that soname. On a newer Arch, pacman installs the matching
`openssl-3` beside the current openssl, as it did here for a package built
against openssl 3.6. To test packages built elsewhere, set
`OMUNCULUS_PACKAGES=<folder>`. A run takes about 75 s once the packages
exist.

### Hooks and the local-check gate

`master` requires the commit status `local-check`. Nothing on GitHub runs the
gate; your machine does, and posts the status.

```sh
mise run hooks:install   # sets core.hooksPath to .githooks (once per clone)
mise run local-check     # gate HEAD and post the status
```

The gate is `mise run check` followed by `mise run validate:regular`, run on
the clean tree of the commit.

- `pre-commit` runs only `mise run check:format`.
- `pre-push` runs `scripts/local-check --pre-push` on each pushed commit. A red
  gate refuses the push. A green one posts `local-check` as `success` once
  GitHub has the commit. Tag pushes and deletions pass.

The full gate output goes to `_build/local-check.log`, overwritten by each run.
A red gate also keeps it as `_build/local-check-failed-<UTC stamp>.log` and
prints the path. The newest 10 such files stay; set
`OMUNCULUS_LOCAL_CHECK_KEEP_FAILED=<n>` to change the count (`0` keeps none).

The status is posted with `gh`, so it needs `gh auth login`. Without it the
gate runs and the push goes through, but `master` refuses the merge. The gate
vouches only for a clean checkout of the pushed commit.

`--dry-run` prints the API calls instead of sending them. To skip on purpose
set `OMUNCULUS_SKIP_LOCAL_CHECK=1`; no status is posted. `git commit
--no-verify` and `git push --no-verify` skip the hooks.

The branch protection of `master`:

- it requires the status `local-check`, up to date with `master` (strict);
- administrators can bypass the rule;
- force pushes and deletions are refused;
- only rebase merges are allowed.

### Releases

[release-please](https://github.com/googleapis/release-please) cuts releases
from the Conventional Commits on `master` (`.github/workflows/release.yml`,
`release-please-config.json`, `.release-please-manifest.json`). Each push to
`master` updates a release pull request with the next version and its
`CHANGELOG.md` entry. Merging it tags `vX.Y.Z` and publishes the GitHub
release. Before 1.0, `feat` bumps the minor version and `fix` the patch. The
version lives in `mix.exs`. Pull requests follow `.github/pull_request_template.md`; the
release pull request carries the same sections around its changelog, set by
`pull-request-header` and `pull-request-footer` in the release-please config,
and no generated-by line. Neither commits nor pull requests carry AI
attribution.

A bot pushes the release pull request, so no hook ran for it. Check out its
branch, run `mise run check` and `mise run validate:regular`, then post the
status for the commit at its head:

```sh
scripts/local-check --post-only --state=success --sha=<commit of the PR head>
```

## 9. What was measured

- [Equivalent Exchange](../eval/README.md), the behaviour benchmark: real
  tasks run by real models against a project, each checked against its
  solution, `mise run eval:run`.
- [The linear resident-agent benchmark](../bench/README.md): resident
  capacity, adding one real run at a time, `mise run benchmark:run`.
- [The comparison](comparison.md) with other harnesses, read from their
  sources and this tree at a pinned commit.
- [Experimental steward recovery](how-to-measure-course-recovery.md):
  five pairs replayed one saved copy of the permission cycle
  seen before escalation skipped agents that had answered the origin with text,
  with the steward overlay and without it. With it, five of five trials
  recovered, in 5.8 responses, 35.0 seconds and $0.008833 per trial on
  average. Without it, none of five recovered within twenty responses; those
  trials were censored at the response budget. `correct_course` refused five
  citations outside the current origin map, and the steward revised them.
  This measured coordination recovery at one checkpoint, not general
  reliability or full task quality. The overlay is optional.

The steward overlay, `eval/overlays/course-recovery.toml`, adds the
[course-recovery](../packs/course-recovery/README.md) pack and changes no
core module. It limits the steward's tools to the course-correction skill,
`recovery_case`, `correct_course` and `end`. A request reaches the steward
when an agent addresses it with `to = "steward"`, which a depth-0 agent that
is not `workflow_only` accepts; `correct_course` escalates the correction
to the front desk by name, so the steward never delivers to the client.
The saved checkpoint of the measurement above predates accounts: a replay
needs a copy of a stalled store taken under the current schema.

`recovery_case` keeps apart the canonical origin map, the recorded routing
events and the agents' claims; its recent window is not the whole history.
A claim that the client was asked needs a canonical request receipt: a
pending human request from the front desk, linked to the original
permissions, with its recorded event ID. `client_request_id` reads that
receipt even outside the recent window. `correct_course` needs a
successful evidence read, cited origin event IDs and a `client_delivery`:
`pending` needs a verified receipt, and `unverified` must not claim the
client is already waiting. It escalates the corrective instructions and the
original permission envelope back to the front desk, which writes the
client question. A refusal emits no action and leaves the steward's run
open to revise the claim. Neither the skill nor the tool grants a
permission or changes the configuration. These checks cover structured
claims; how the steward and the front desk read free text is measured, not
checked.

## 10. Artifacts

Agents make documents — a proposal, a brief, a design, a handoff, a
preview — and today those live as files in the workspace, where an edit
overwrites them and only a path names them. An artifact is the same
document as a record of the conversation: named, typed, versioned and
immutable once written. The core knows the record and its tools; what a
kind holds and what it must satisfy is a pack's.

**The record.** An artifact belongs to one conversation (runs without one share a set). It has a `name`
(a file name without a directory, such as `proposal` or `proposal.md`),
a `kind` (a lowercase word the pack chooses; the core keeps no list) and
versions numbered from 1. A version is `{name, kind, version, media_type,
bytes, sha256}` with an optional `note`, and the event's `event_id`, `at`
and `by`. A name has one kind: a later version naming another is refused.
A version never changes; a change is the next version, and a write whose
content equals the latest version's (same SHA-256 and media type) makes
none: that version stands and no event is recorded. A write may name
the `base` it builds on and is refused when another version came since
(also when its content is equal),
and the event records the `tool` that wrote the version, so a pack can
trust only what its own tool wrote.

**Where it lives.** The metadata is an `artifact` event, as an
attachment is an `attach` or `prompt` event: the store has no table of
artifacts, so no migration, history is append-only and the operator reads
it with the rest of the conversation. The content is a file under its
SHA-256 in `[store] attachments`, so a version is exactly what was written
and survives whatever the workspace does after. The workspace is not the
home of artifacts because a path names no version, an agent edits it in
place and a conversation may share a workspace with others. An artifact
needs `[store] attachments`, like an attachment.

**The backend contract.** A backend keeps content and answers for it:
`put(name, media_type, content)` returns `{name, media_type, bytes,
sha256}` within the size limit, and `path(sha256)` gives the content back.
`Omunculus.Attachments` is the one backend. The record, the numbering, the
tools and the routes depend on nothing else, so another backend — object
storage, a design tool behind an MCP server — replaces those two
functions without changing them. None is implemented. A bucket is not
such a backend: it is a copy that two tools keep, over the events
([tools](tools.md#artifacts-in-a-bucket)), so the record, the numbering and the routes do not know it.

**Visibility.** A version is not an attachment. The person's conversation
reads only the `prompt` and `attach` events, so a client receives a
version only when an agent with the `attach` tool attaches it by
reference: `attach` with `artifact` (and `version`, the latest when
omitted) emits an `attach` of that version's exact file. The ceiling
decides which agents have `attach`. The operator lists every artifact and
version through the server ([the server](server.md#artifacts)), with
`conversation.read`, read-only.

**Structured documents.** A kind may be data: a version of media type
`application/json`. A pack's tool holds the rules over that data (a
proposal's price lines, total and status words) and renders the
client-facing file from a template of the pack, putting it as an artifact
of its own. The sales desk's `proposal` does that, and `render_proposal` renders again
([the pack](../packs/sales-desk/README.md)). The core never reads what a
version holds, but to hand its JSON to a tool that declares it wants it
([tools](tools.md#artifacts)).

## 11. Memory

The work tree is the memory of one conversation. Memory is what should
outlive it: the client prefers X, this repository's tests run with Y,
deploys fail unless Z. It is learned, short and stated by an agent.
Skills are authored procedures read on demand ([config](config.md#skills)),
and memory does not replace them: a procedure someone wrote down is a
skill, a procedure an agent found out is a `procedure` entry.

**The record.** An entry has a `scope` (`project`, `agent` or
`workspace`), a `kind` (`fact`, `preference`, `procedure` or `pitfall`)
and a `text`. Its source is the event that holds it: the conversation,
work, run, actor and time. The `agent` and `workspace` scopes are keyed by
the run's agent and its work's workspace, which the store reads from the
run, never from the call.

**Where it lives.** In `memory` events, `remember` and `forget`, applied by
`Store.Actions.Memory`. The entries are the events folded in order, a
`forget` ending the entry whose id it names. No table: the log is already
append only, ordered and per project, so history, provenance and removal
need no schema change, and a store made before memory still opens. A
partial index on `events (sequence) WHERE type = 'memory'` keeps the read
from scanning the log. The `memories` view source reads what a run sees:
the project's entries, its agent's and its workspace's.

**Search.** `recall` matches the words of a query in an entry's text in the
tool, ranking by the number of words matched, then by time. There is no
FTS5 table or embedding: the entries are short and few, and a second
index would be a second copy to keep true to the log.

**In the prompt.** With `[policy] memory_bytes`, `assemble` renders the
newest entries that fit under `## Memory` in the context, after the
instructions that stay the same, so a change of memory never invalidates a
provider's cache of them. Without it, the prompt carries none and an agent
searches with `recall` ([tools](tools.md#memory)).

## Jobs as events

Scheduled jobs are two event types, with no table: a store made before jobs
still opens, and `store_requires_recreation` stays what it was. `job` events
(`create`, `change`, `transition`, `read`) carry a job's definition and
lifecycle, each with its `origin` (author, channel, approving request, run,
work, conversation); `job_fire` events carry one state of a fire each, with
its cost. A job is the `job` events folded in order, so each change bumps
`version`; a fire is its `job_fire` events merged. Expression indexes on the
job id and the fire id keep a job's reads off the rest of the log; finished
fires are totalled in SQL. A table would have recreated every existing store
for what the log already keeps ordered and append only.

The modules: `Jobs.Policy` (the `[jobs]` table), `Jobs.Fields` (the checks of a
job's fields), `Jobs.Schedule` and `Jobs.Zone` (cron, `every`, `daily at`, in a
zone), `Jobs.Summary` (a job in words), `Jobs` (the fold, the writes, and what
the scheduler calls), `Tools.Jobs` and `Tools.ProposeJob`. Schedules are
parsed in the project rather than by a dependency: the grammar is small, and
`Zone` reads the host's `/usr/share/zoneinfo` (TZif and its POSIX rule), the one
source of zones. A fire's run has `via = "job"`; `Jobs.write/3` walks a run's
`cause_id` chain for that, to refuse jobs made from a fire.

For the scheduler, `Jobs` offers `due/2` (active jobs with unclaimed slots,
lazily), `pending/1` (fires not finished), `record_fire/3` (a fire's states, in
order, each event carrying telemetry) and `transition/5`.

### The scheduler

`Server` starts a `Jobs.Scheduler` beside each `Server.Project`, so it lives and
stops with the project's process. Every second it calls `plan/3`, which is the
whole decision for an instant `now` and so is driven in tests with any clock and
no waiting (`Server.start_link/2` takes a `clock` for the same reason). `plan/3`
reads `[jobs]` from the file each time, then: at the first call after the start,
fails the fires a stopped server left `running` and applies `missed` to the slots
that passed while it was down (the missed ones are one `missed` fire with
`scheduled_for`, `until` and `count`, which the next count of slots starts after); claims every slot that has come as a `due` fire
(`record_fire/3` refuses a slot taken twice); ends the jobs whose `end_at` has
passed; and goes through the `due` and `late` fires, oldest first, cancelling
those of a paused job, marking `late` (and asking the owner, a request from the
owner to the owner, since the scheduler is no run and a run's inbox reaches no one)
those past `lateness_seconds`, holding those that would pass `max_parallel`, and
running each remaining one's condition (`Jobs.Fire.condition/2`, no model). A fire
that passes is recorded `running` before its process starts, so a second `plan/3`
counts it against `max_parallel`.

`Jobs.Fire.run/3` acts as the job's owner: `Operations.start/4` with the owner as
principal, the job's conversation (or one `Access.create_conversation/2` makes), and
`via = "job"`, which `Harness.follow_up/4` stamps on every run the call opens
whatever tool event made them; the runs below carry it through `cause_id`, which is
how `Jobs.write/3` refuses jobs from a fire. `Cycle.command/3` waits for those runs.
`Jobs.Cost` finds them (the runs the call's events caused, transitively, as
`Store.said/2` does) and sums their model replies at the models' prices (`Usage`; the model is the config key
`Config.model_key/3` finds, as `GET /usage` does; an unpriced model adds zero). Consecutive failures count the fires that finished
`failed` since the job's anchor, which a resume moves.

A fire's message or work is written with `"via": "job"` in its event body, so
a run that the server's crash left to `Run.recover/1` is reopened `via = "job"`
too, and a retry of a run in a fire keeps it: the guard holds after a crash. `Jobs.Preview` reads the same history for
the cost estimate.
