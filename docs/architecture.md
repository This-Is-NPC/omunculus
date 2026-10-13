# Architecture

The core is `lib/omunculus/`. Read these modules first, in this order. What
each one does with the store, the TOML and the sandbox is detailed in the
other documents of `docs/`; this page is the layout of the tree, the module
map and the run cycle that ties them together.

## Layout

```text
bin/omunculus        shell wrapper: mise exec -- mix omunculus
apps/console/        the window: QML on Quickshell, a client of the server's local socket
apps/mailbox/        the mailbox: a concept client
apps/studio/         the studio: the project's settings
apps/kit/            what the apps share: ui/, the theme and controls, client/, the curl
                     requests to the server's sockets, the request helpers and the scripts
                     that send and open attached files, and run, the launcher of every app
lib/omunculus/       core, config, server, tool, tools, hooks, models, execution, store
lib/mix/tasks/       the omunculus, omunculus.presets and omunculus.socket mix tasks
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
                     workspace files and environment; sales-desk, which answers clients
                     and works over the dream team; design-team, which shows the client
                     a preview of the site before it is built
eval/                Equivalent Exchange, the behaviour benchmark: the Amestris preset,
                     its configurations, tasks and runner (mise run eval:run); each run
                     writes eval/results/<time>-<label>/, ignored by git
scripts/             the jobs mise.toml runs as tasks: validate-*, check-format, up, dev-*, benchmark-*, eval-*
dev/                 the development environment: server registry and project config
```

## `Omunculus.CLI`

Direct entry point. `omunculus [--config <path>] <name> [--key value]` dispatches a tool with trigger `cli` through `Operations`, then follows up its events. `access bootstrap` seeds an administrator. Without `--config` the file is `./omunculus.toml`; `bin/omunculus` passes `--config $PWD/omunculus.toml` unless the first argument is already `--config` or `serve`, and makes a relative `--config` absolute against the caller's directory. A missing file is a refusal, except for a tool with `config = false` (`preset`). When a server holds the project's lock, the command line goes to `POST /v1/cli` on the project's local socket and returns once the runs it opened there have finished. Taking the lock itself, a command first recovers the project (`Run.recover/1`), in the same cycle as its own runs. Reads no environment variables.

## `Omunculus.Project`

Opens the SQLite file `[store] path` names and holds the connection, the config path, and the cycle the runs opened through it join. CLI and server acquire an OS file lock for exclusive project ownership.

## `Omunculus.Cycle`

The runs commands open, each in a process of its own. A command returns once every run it opened, transitively, has finished, and fails with the errors of any of them; in the server's persistent cycle, `command/3` waits only for the runs of its own command, those made due by its process or by those runs. A work has one run at a time: runs due for a work with a run open wait for it, in the order they became due; a work's own run due while another waits is merged into it. A run without a work that creates the root holds the root's turn until it finishes. The runs due and not yet begun live only in the cycle's process; `Run.recover/1` finds again from the store those a stopped process lost.

## `Omunculus.Config`

Loads and validates `omunculus.toml`: the project's `root` and optional `conversations`, policy (including `assemble`, the required `max_retries` and `request_routes` and the optional `max_reopens`, `last_run_output_bytes`, `tool_output_bytes`, `conversation_bytes`, `send_catalog`, and `session_ttl_ms` with `session_max_bytes`), depth layers, workspaces, agents, an agent's optional `image`, a picture relative to the config (or to its pack's folder), workflows (each layer with its per-tool `overrides`; the `workflows` of `[policy]`, or of a depth layer for its depth, are those a work there must go through one of, and without them a work may go through any workflow whose stage agents are of its depth), models, `[auth]`, optional `[access]` role definitions, MCP servers, `[skills] paths`, `[secrets.<tool>]` (and an MCP server's `secrets`) binding the secrets a tool's process receives to `[auth]` providers, `[store]` (with an optional `changes`, where the files each call changed are kept, and an optional `attachments`, where the files attached to conversations are, which comes with `attachment_bytes`) and the required `[execution]` table (including `resources`, `max_concurrent`, `max_queue` and `queue_timeout_ms`, and the optional `host`, `deny_read` and `write`). `[[packs]]` imports teams (`Config.Packs`; see [packs](packs.md)). `Config.Layer` is one ceiling layer; `Config.Toml` encodes the file. Also rewrites the file for permanent grants and for `edit/5`, which writes one item a client edits (an agent, model, workflow, workspace, `auth` provider or tool `secrets`, or the `policy` or `access` table) while the file is at the revision `document/1` read and the result loads; either way it replaces the file whole through a temporary file.

## `Omunculus.Harness`

Discovers the catalog, checks the trigger, hydrates the views a manifest declares, resolves the secrets a tool declares through `Omunculus.Secrets`, invokes the tool and the steps it chains with them, masks their values in what it returns, records `EVENTS(tool)` for each, and applies all their emitted actions in one transaction; with `[store] changes`, a model's call in a run that may write its workspace is bracketed by snapshots of the workspace's tree (`Omunculus.Changes`, git run on the harness side, outside the sandbox, in a bare repository of its own), and the files it changed, with the two trees, go in its `EVENTS(tool)` as `changes`; a model's call whose actions the store refuses is recorded as failed, its output the refusal, and applies none of them. `end` is the only event that ends a run. Hooks of every other event run immediately; hooks of `end` wait until the run has closed and the runs its events ask for are due. `open_due/2` (after each model call) and `follow_up/3` (after the close) write permanent grants to the TOML before making runs due; an upstream text `reply` resumes an intermediary with unresolved origins even while its work waits on children; a human requester needs no run. A normal `reply`, with text and an optional option whose calls run, opens a run of the requester's work when that work is open, or, for a request from a run without a work, a run of that run's agent in its conversation.

## `Omunculus.Run`

Opens one run, holding a slot of the execution limiter's `run` class (`[execution]` `max_concurrent`, `max_queue`, `queue_timeout_ms`): resolves the agent from the stage of the work's workflow, the work's assignee or, for a message without a work, the agent of depth 0 the message is for — the one it names (`send --agent`), else the one its conversation began with, else the only one, decided and recorded when the message is stored, which refuses it otherwise; a work that names no agent where its depth has several is refused too, and an unnamed root is its creating run's agent's — mounts the ceiling, builds the execution policy (with `[policy] send_catalog` the model is sent every model tool of the catalog, so all agents' requests start alike, and may call only its own; a call to another is refused and recorded as failed), begins the run with the event that made it due as its `cause_id`, dispatches the `assemble` tool, attaches `PROMPTS(assembled)` and, when the tool continues the agent's paused session on the work, a `session` event naming the run it continues and what it was told had happened since, drives the model until it calls `end` or stops — its calls and their reactions reuse the config and catalog it prepared (`Harness.prepared/3`) rather than loading them again — making the runs each call's actions ask for due at once, closes the run, then retries a work whose model stopped without `end`, a model that fails or crashes counting as one that stopped, its `end-run` carrying `error`, why in a sentence (`Out.model_failed/1`, one formatter for every adapter's errors); over `max_retries` it breaks a child work and opens a request along the configured route, with `retry` and `cancel` options and an inbox entry, for a root work. A cancelled work opens no run; a work's own run does not open once the work is no longer open. `recover/1`, when the server opens a project or a direct command takes its lock, closes the runs left open and makes due again what a stopped process lost: the runs events asked for and no run began for (`Harness.lost/1`), a retry decision never applied, a request left at an agent ([the cycle](cycle.md#a-process-that-stops)).

## `Omunculus.Ceiling`

Intersects the policy, workspace, depth, agent and stage layers into the effective tool set of a run and classifies a name as have, askable, sealed or blocked. `pinned` intersects the same way and marks which effective tools become cards when `tool_search` is present. The same layers resolve the run's per-tool `overrides`, the most specific layer winning per key; the snapshot carries them.

## `Omunculus.Participant`

Builds authenticated human and configured agent request identities from the action context and formats their labels. Identities are stored as JSON; callers cannot supply another participant's authorship.

## `Omunculus.RequestRoutes` and `Omunculus.Store.RequestRoutes`

Parse the required TOML routes once into `Config.request_routes` and resolve the next receiver from authenticated participants, conversation origin and work ancestry. The resolver checks logical route names once for both creation and escalation; an unknown name is refused with the configured names and guidance to omit `to` for the default route. The ask and escalate manifests describe `to` as an optional name from `request_routes`. Missing route configuration returns required; malformed routes return invalid. The first matching rule supplies ordered destinations; no implicit human fallback or permission-based bypass remains. A named agent without an ancestor work must be depth 0 and able to run without a workflow.

## `Omunculus.RequestOptions`

The store's recursive validation and authorization of request replies: lifecycle state, selected options, named origin parts and permission boundaries on the original targets. An agent cannot answer a request with a sealed grant option, including with deny or text; it must escalate for a human decision. The reply tool normalizes its arguments and builds chains; it leaves these checks to the store's transaction. The HTTP router checks required text and an optional nonempty option at the command boundary.

## `Omunculus.Store` and `Omunculus.Store.*`

The only code that touches SQL. `Connection` is the one process that owns the SQLite handle; every statement and transaction runs in it, so concurrent runs apply their transactions one after another, and it announces committed events to the processes subscribed to it. `Access` checks project and conversation memberships, scopes reads, and manages idempotent command receipts. `View` reads cuts of the tables, including recursively linked request origins and their questions; the inbox source with `relation = "received"` reads pending requests addressed to the current depth-0 run's agent in its conversation, grouped by conversation and hydrated through the canonical request view. Escalated origins appear only as provenance, and reading does not resolve requests. `Actions` applies emits (`comment`, `request`, `escalate`, `reply`, `grant`, `cancel`, `work`, `delegate`, `continue`, `break`, `wait`, `end`, `notify`, `prompt`, `attach`, `compact`, ...); it refuses `end` on a work's own run that would leave the work open with nothing to run it again — no request of it pending, no run of it due since the run began — or with a child that broke waiting on it; a request stores JSON `requester` and `arbiter` participant identities (agent name, or authenticated human issuer/subject), with `pending`, `escalated` and `closed` statuses; it carries named options of tool calls and its arbiter is resolved in the store: an option calling a tool only a human may give remains subject to that authorization boundary, while its receiver follows the first matching TOML route; `to` is an optional logical route name; a request's view gives the option its reply chose (`answer`), nil for a text-only answer; its closed status and reply comment distinguish that from an unanswered request. `escalate` merges received pending requests in the same conversation into one linked request and preserves child waits; recursive named reply parts retain the actual answerer and original grant targets, while omitted parts return to pending. `Runs` and `Events` write the run lifecycle; `Runs.record_tools` records a call and its chained steps as one transaction; `Runs.unreported` decides a retry, break or request in one; `Runs.unanswered` uses the same linked action for a pending request left unanswered by its receiver and names, in the linked request's reason, the receiver and each question it held — who asked it, the title of their work and the question, shortened, never an id — and writes the same as an inbox note when the linked request reaches a human; requester and arbiter identities remain immutable. `Schema` creates twelve tables, including append-only `request_escalations`, and refuses older request schemas with `store_requires_recreation`.

## `Omunculus.ConversationRoot`

With `[project] conversations`, the folder each conversation works in, `<workspace root>/<conversations>/<conversation id>`, the root of its runs and calls in place of the workspace's (`Harness.workspace_context/3` picks it from the call's run, work or context). The first time one is needed it starts as a copy of the workspace's files, without the conversations' folder and what omunculus keeps there, copied beside it and renamed into place ([config](config.md#a-folder-per-conversation)).

## `Omunculus.Attachments`

Keeps the files attached to conversations in the directory `[store] attachments` names, each under its SHA-256, within `[store] attachment_bytes`, and checks a description `{name, media_type, bytes, sha256}` against the file kept for it. The event that carries a file describes it — a message's `prompt` or a run's `attach` — and the store checks each description it records; there is no table of attachments.

## `Omunculus.Operations`

Shares tool dispatch, human authorization and cycle follow-up between the direct CLI and HTTP commands.

## `Omunculus.Server` and `Omunculus.Server.*`

Optional Bandit/Plug HTTP server. Its TOML registry maps project IDs to project configs and holds run/stream limits; an optional TCP listener (`host`, `port`) comes with `[auth]`, which maps JWT claims to human principals. Each project owns a persistent cycle in `Server.Project`, whose process only opens and closes the project and keeps it as its registry value: every read and command runs in the request's own process, so a command held in its tool or hooks keeps no other request waiting, and a request that crashes still answers `500` with the contract's error body. `Server.Socket` serves the project on `<store>.omunculus.sock` (mode 0600) as the local principal, the one the direct CLI uses; only there, `POST /v1/cli` runs a forwarded command line through `CLI.in_project/2`, and `GET /v1/projects` lists every project of the registry with its socket, where over HTTP it lists the projects the user may read; `GET /v1/projects/:id/agents/:agent/image` serves an agent's image. The versioned contract exposes scoped conversations, snapshots, events, a WebSocket event stream (`Server.EventStream`) of a conversation or of every conversation the principal may read, the works of those conversations (`GET /v1/projects/:id/works`, by `state`) and typed commands; the core store enforces access. `OpenAPI.route` registers a Plug route and its operation together; `/openapi.json` renders an OpenAPI 3.1 document from these declarations and schemas in `OpenAPI`.

## `Omunculus.Tool.Catalog`, `Manifest`, `Views`, `Overrides`, `Invoke`, `Omunculus.Skills`

Discover `tool.toml` / `hook.toml` folders, Agent Skills and MCP servers, parse manifests (including `chains`, `then`, `secrets`, named `schemas` and `[views.<key>]` tables), parse and hydrate a call's views — each a core `source` read from an anchor (`from`) with that source's options, scoped to the call's conversation — apply a run's `overrides` (`then`, `chains`, `schema`) to the catalog, and call a tool either as an Elixir module or as an external command fed JSON on stdin. `Manifest.card/1` is `- name: description [tags: a, b]`; no tags, no suffix.

## `Omunculus.Tools.*`, `Omunculus.Hooks.Noop`

The builtin tools. Each has a manifest under `priv/tools/<name>/` and a module here; the builtin hooks (`on-request`, `on-notify`, `on-continue`, `on-break`) all use `Hooks.Noop`. The model tools that hand a work away (`work`, `done`, `break`, `wait`, `request_access`) take a `report` and end the run through `then = ["end"]`; `wait` parks a root work until its person's next message; each work `work` creates may name its `agent` or its `workflow`, which the work keeps and goes through; `delegate` and `continue` are chain-only steps of `work` and `done`; `grant` and `cancel` are chain-only steps of `reply`, which omits null or empty options, answers with text and chains a chosen option when given; `forward` hands what the person said to a root work of the run's conversation still open, as a message that opens a run of it, and the store refuses a run's message to a work of another conversation; `reopen` sends a work below the run's own that broke back to its agent, another named at its depth, or, in a workflow, the agent of a stage it names up to its own, from which the work goes through the stages after again, with instructions, granting it on that work the names it lists that the parent could grant on a request, and ends the run, and delegating, continuing (`done`) and ending are refused while such a work waits on the parent; `retire` cancels such a work with a report and lets the run go on, to hand out what must come first and a new work after it; past `[policy] max_reopens` reopens of one work in a row, `reopen` asks along the parent's route instead; `config` and `overview` print the project's setup, logins' keys left out, whole for a client with `whole` and otherwise in parts a call returns — an index, then a section or an item of the config, or one agent where it runs; `propose_config` loads the config one change of an item would make and, only when it loads, asks the person in a request whose `apply` option calls `configure` with it at the file's revision, ending the run; each refuses a change whose agents lack a step a tool of theirs that ends the run chains (`Tools.Steps`); `propose_pack` does the same for importing a pack, its `apply` option calling `pack`, and says each of the pack's agents at the depth and on the model it would run, and what its `environment/` holds; `ask` and `escalate` accept model and CLI calls; human creation needs conversation send access and human escalation needs reply access and matching received origins. They reuse the same request actions, with no synthetic requester run; their `end` step emits nothing when no run exists. `escalate` merges named origins and ends a model run; `reply` accepts recursive named parts; its effects and human-only sealed and permanent grants are validated in the store transaction against their original targets. `ask` asks a free-text question or, with named options that call nothing, a decision, through the configured route, with optional `to` naming a logical responsibility, as on `request_access` and `escalate`; `request_access` asks in one request for every tool, path, directory and sandbox capability it lists, each option granting them all; `changes` lists, call by call, the files the calls of the run's work or of a work below it changed, or their unified diff, as `[store] changes` recorded them — from the command line, of the work named, with read access to its conversation — and `revert` puts those files back as they were before the work, refusing when one changed since; `skill` reads one of the skills the run has, which `assemble` lists under `## Skills`; `runs` sums up the project's last closed runs, of every conversation, through the `runs` view source's `recent` relation — how each ended, its calls, what failed, what the model used — or gives one call by call. `attach` keeps a file under the run's roots, as it is then, as an attachment of the run's conversation, with an optional `note`, through `Omunculus.Attachments`; `read_attachment` reads one of the conversation's attachments by its `sha256`, which `assemble` lists under `## Attachments`, read through the `events` view source with `relation = "attachments"`. The default `assemble` also reads `inbox` with `relation = "received"`: at depth 0, `## Inbox` groups the pending requests addressed to the run's agent by its conversation, with original questions, identities, works and historical workflow/stage, including linked parts; it does not repeat the request that opened the run there and under `## Request`. This inbox is included in a continued session's news too. On a work, `## Children` lists every work handed down from it as it stands — title, agent, id, workflow stage and state, one that broke marked as waiting on the run to reopen it, retire it or break the work, one that is done with its report unless `## Results` has it — in a fresh prompt and in a continued session's news alike. `Tools.Session` rebuilds, from the work's closed runs, or for a run without a work from its conversation's closed runs that had none, the session a run continues: with `[policy] session_ttl_ms` and `session_max_bytes`, a run of the agent whose last run there paused (an answer, a request, children, a wait for the person, a retry) recently goes on as the same conversation, under the instructions it started with, and is told only what happened since; a session that cannot be rebuilt exactly, or a hand-on (`continue`, `break`), starts over. A run without a work is shown its conversation's root works under `## Works` and, when its session starts over, what the person and the agent said there under `## Conversation` — of the agent, its last reply that called no tool, not the text it wrote beside its calls — each the newest that fits `[policy] conversation_bytes`.

## `Omunculus.Sandbox`

Runs the code the model submits inside the execution sandbox and answers each `tools.<name>(args)` call it makes.

## `Omunculus.Execution.*`

Starts every external process through Bubblewrap under an immutable per-run policy, with concurrency, queue, timeout and output limits. A command's secrets reach its process alone, as read-only files at `/run/secrets/<NAME>` named by `<NAME>_FILE`, written into that process's temporary directory before it starts and removed with it; the policy never holds them. With `[execution] host`, a command sees the machine read-only as the person does — their home overlaid so that what it writes there stays in the run's scratch, `/run` hidden but for the resolver, and what `deny_read` names (and the logins store) hidden — and writes only the workspace, given `sandbox.write`, and what `write` names; without it, it sees only the runtimes, the workspace and the folders the catalog's tools were found in (each folder of `[tools] paths` whole, so the tools of one path share what lies beside them)), and, written like its secrets into its temporary directory, an `/etc/passwd` and `/etc/group` of its own that name its user `omunculus`, with its ids and `/tmp/home` as its home, so that `id`, `ssh` or `git` find who runs them without the machine's accounts. A run's commands share its scratch, a directory beside the store (`<store>.scratch/<id>`) bound as their `/tmp`, home within, kept from one command to the next and outside the workspace; the run removes it when it ends, and opening the project with its lock removes any a run left.

## `Omunculus.Mcp`

JSON-RPC to one MCP server, run through the execution sandbox, for discovery and calls.

## `Omunculus.Model.Fake`, `Battery`, `OpenAI`, `OpenAIResponses`, `AnthropicMessages`, `Command`

Model adapters, picked by `api` in `[models.<name>]`. `api = "module"` names an Elixir adapter: `Fake` echoes the first prompt line, `Battery` is the scripted "count to 5" model. `openai-completions` posts to `/chat/completions`, `openai-responses` to `/responses`, `anthropic-messages` to `/messages`; with `stream = true` they read the reply as server-sent events through `Model.EventStream`. The HTTP adapters record the server's `usage` with each reply and keep it out of the next request; `anthropic-messages` marks two cache breakpoints, the end of the instructions and the end of the last turn. Each HTTP adapter merges the model's `body` table over the request it builds — an `anthropic-messages` model sets there the `max_tokens` a reply may take, thinking included, which loading refuses it without — and with the model's `retries` sends a request again on a rate limit or a server error, after the delay the server asks for (`Model.Retry`); a call whose arguments are not a JSON object goes back to the model as that call's result (`Model.Arguments`). With the model's `code_mode`, they also offer `__omunculus_execute`, which runs JavaScript in the sandbox calling `tools.<name>(args)` through the same authorized, recorded path as native calls (`Omunculus.Sandbox`); without it, they do not. `command` runs an external program over the sandbox NDJSON protocol, where `{type: delta, text}` lines carry partial text. An adapter is a `(prompt, tools, call, record, delta, execution)` fun, where `prompt` is an `Omunculus.Prompt`: the assembled `instructions`, which the HTTP adapters send apart from the run's `context` (a `system` message, the Responses `instructions`, a cached Anthropic `system` block) so the provider can reuse them from its cache, and, continuing a session, its `history`, which they send as the conversation it was; `record` writes `EVENTS(model)`, `delta` publishes partial reply text on the store connection without recording it.

## The run cycle

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
      until the model calls end (EVENTS(end)), stops (EVENTS(model)) or fails
      EVENTS(end-run), with {"error": why} when the model failed, RUNS.status = done
  → follow_up/3 makes the runs the ending call asked for due, runs the hooks
    of end, then makes the reaction runs of calling hooks due
  → a model that stopped without end or failed on a work still open: a run with
    via = retry on that work, or, once [policy] max_retries is used up, a
    break (a child) or a routed request with retry / cancel (a root)
  → the command returns when every run it opened, transitively, has finished
```
