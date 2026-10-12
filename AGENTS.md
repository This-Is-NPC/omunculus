# Agent rules

This file is the contract for anyone (human or agent) changing a
repository that uses it. It is self-contained: do not look up an
external skill to commit, and do not invent a second toolchain
beside mise.

## What Omunculus is

A local harness with a direct CLI and an optional HTTP server that orchestrates tool-using language models. It opens a SQLite store per project, assembles a prompt for one run, lets the model call tools inside the execution sandbox, records every step as an event, and applies the store actions those tools emit. Work items, conversations, memberships, requests, notifications and workflow stages are state in the store; the harness only follows them.

Targets Linux, Elixir 1.17, OTP 27, Deno 2.9 and Bubblewrap 0.8 or newer. Tool versions are pinned in `mise.toml`.

## Architecture

The core is `lib/omunculus/`. Read these modules first, in this order.

| Module | Role |
| --- | --- |
| `Omunculus.CLI` | Direct entry point. `omunculus [--config <path>] <name> [--key value]` dispatches a tool with trigger `cli` through `Operations`, then follows up its events. `access bootstrap` seeds an administrator. Without `--config` the file is `./omunculus.toml`; `bin/omunculus` passes `--config $PWD/omunculus.toml` unless the first argument is already `--config` or `serve`, and makes a relative `--config` absolute against the caller's directory. A missing file is a refusal, except for a tool with `config = false` (`preset`). When a server holds the project's lock, the command line goes to `POST /v1/cli` on the project's local socket and returns once the runs it opened there have finished. Reads no environment variables. |
| `Omunculus.Project` | Opens the SQLite file `[store] path` names and holds the connection, the config path, and the cycle the runs opened through it join. CLI and server acquire an OS file lock for exclusive project ownership. |
| `Omunculus.Cycle` | The runs commands open, each in a process of its own. A command returns once every run it opened, transitively, has finished, and fails with the errors of any of them; in the server's persistent cycle, `command/3` waits only for the runs of its own command, those made due by its process or by those runs. A work has one run at a time: runs due for a work with a run open wait for it, in the order they became due; a work's own run due while another waits is merged into it. A run without a work that creates the root holds the root's turn until it finishes. |
| `Omunculus.Config` | Loads and validates `omunculus.toml`: policy (including `assemble`, the required `max_retries` and the optional `last_run_output_bytes`, `tool_output_bytes`, `conversation_bytes`, `send_catalog`, and `session_ttl_ms` with `session_max_bytes`), depth layers, workspaces, agents, workflows (each layer with its per-tool `overrides`; the `workflows` of `[policy]`, or of a depth layer for its depth, are those a work there must go through one of, and without them a work may go through any workflow whose stage agents are of its depth), models, `[auth]`, optional `[access]` role definitions, MCP servers, `[skills] paths`, `[secrets.<tool>]` (and an MCP server's `secrets`) binding the secrets a tool's process receives to `[auth]` providers, `[store]` (with an optional `changes`, where the files each call changed are kept) and the required `[execution]` table (including `resources`, `max_concurrent`, `max_queue` and `queue_timeout_ms`, and the optional `host`, `deny_read` and `write`). `[[packs]]` imports teams (`Config.Packs`): each names a pack's folder, whose `pack.toml` holds agents on roles, workflows, tool secrets on providers, MCP servers and depth layers, and maps its roles to the config's models and its providers to the config's `[auth]`, and may move the whole team `depth` depths below its own; the pack's items are laid under the config's, an item of the config of the same name overriding it key by key (grants it writes joining the pack's tools), two packs' items of one name refused but for depth layers, where the workflows they require add up, and the pack's `tools/` and `skills/` come before the config's paths. `Config.Layer` is one ceiling layer; `Config.Toml` encodes the file. Also rewrites the file for permanent grants and for `edit/5`, which writes one item a client edits (an agent, model, workflow, workspace, `auth` provider or tool `secrets`, or the `policy` or `access` table) while the file is at the revision `document/1` read and the result loads; either way it replaces the file whole through a temporary file. |
| `Omunculus.Harness` | Discovers the catalog, checks the trigger, hydrates the views a manifest declares, resolves the secrets a tool declares through `Omunculus.Secrets`, invokes the tool and the steps it chains with them, masks their values in what it returns, records `EVENTS(tool)` for each, and applies all their emitted actions in one transaction; with `[store] changes`, a model's call in a run that may write its workspace is bracketed by snapshots of the workspace's tree (`Omunculus.Changes`, git run on the harness side, outside the sandbox, in a bare repository of its own), and the files it changed, with the two trees, go in its `EVENTS(tool)` as `changes`; a model's call whose actions the store refuses is recorded as failed, its output the refusal, and applies none of them. `end` is the only event that ends a run. Hooks of every other event run immediately; hooks of `end` wait until the run has closed and the runs its events ask for are due. `open_due/2` (after each model call) and `follow_up/3` (after the close) write permanent grants to the TOML before making runs due; an upstream text `reply` resumes an intermediary with unresolved origins even while its work waits on children; a human requester needs no run. A normal `reply`, with text and an optional option whose calls run, opens a run of the requester's work when that work is open, or, for a request from a run without a work, a run of that run's agent in its conversation. |
| `Omunculus.Run` | Opens one run, holding a slot of the execution limiter's `run` class (`[execution]` `max_concurrent`, `max_queue`, `queue_timeout_ms`): resolves the agent from the stage of the work's workflow, the work's assignee or, for a message without a work, the agent of depth 0 the message is for — the one it names (`send --agent`), else the one its conversation began with, else the only one, decided and recorded when the message is stored, which refuses it otherwise; a work that names no agent where its depth has several is refused too, and an unnamed root is its creating run's agent's — mounts the ceiling, builds the execution policy (with `[policy] send_catalog` the model is sent every model tool of the catalog, so all agents' requests start alike, and may call only its own; a call to another is refused and recorded as failed), begins the run with the event that made it due as its `cause_id`, dispatches the `assemble` tool, attaches `PROMPTS(assembled)` and, when the tool continues the agent's paused session on the work, a `session` event naming the run it continues and what it was told had happened since, drives the model until it calls `end` or stops — its calls and their reactions reuse the config and catalog it prepared (`Harness.prepared/3`) rather than loading them again — making the runs each call's actions ask for due at once, closes the run, then retries a work whose model stopped without `end`; over `max_retries` it breaks a child work and opens a request to the human, with `retry` and `cancel` options and an inbox entry, for a root work. A cancelled work opens no run; a work's own run does not open once the work is no longer open. |
| `Omunculus.Ceiling` | Intersects the policy, workspace, depth, agent and stage layers into the effective tool set of a run and classifies a name as have, askable, sealed or blocked. `pinned` intersects the same way and marks which effective tools become cards when `tool_search` is present. The same layers resolve the run's per-tool `overrides`, the most specific layer winning per key; the snapshot carries them. |
| `Omunculus.Store` and `Omunculus.Store.*` | The only code that touches SQL. `Connection` is the one process that owns the SQLite handle; every statement and transaction runs in it, so concurrent runs apply their transactions one after another, and it announces committed events to the processes subscribed to it. `Access` checks project and conversation memberships, scopes reads, and manages idempotent command receipts. `View` reads cuts of the tables, including recursively linked request origins and their questions. `Actions` applies emits (`comment`, `request`, `escalate`, `reply`, `grant`, `cancel`, `work`, `delegate`, `continue`, `break`, `end`, `notify`, `prompt`, `compact`, ...); a request stores JSON `requester` and `arbiter` participant identities (agent name, or authenticated human issuer/subject), with `pending`, `escalated` and `closed` statuses; it carries named options of tool calls and its arbiter is resolved in the store: an option calling a tool only the person may give the requester goes to the person, and so does a request that says it is for them (`to = "person"`); a request's view gives the option its reply chose (`answer`), nil for a text-only answer; its closed status and reply comment distinguish that from an unanswered request. `escalate` merges received pending requests in the same conversation into one linked request and preserves child waits; recursive named reply parts retain the actual answerer and original grant targets, while omitted parts return to pending. `Runs` and `Events` write the run lifecycle; `Runs.record_tools` records a call and its chained steps as one transaction; `Runs.unreported` decides a retry, break or request in one; `Runs.unanswered` hands the person a request whose agent arbiter closed its run without a reply. `Schema` creates twelve tables, including append-only `request_escalations`, and refuses older request schemas with `store_requires_recreation`. |
| `Omunculus.Operations` | Shares tool dispatch, human authorization and cycle follow-up between the direct CLI and HTTP commands. |
| `Omunculus.Server` and `Omunculus.Server.*` | Optional Bandit/Plug HTTP server. Its TOML registry maps project IDs to project configs and holds run/stream limits; an optional TCP listener (`host`, `port`) comes with `[auth]`, which maps JWT claims to human principals. Each project owns a persistent cycle, and `Server.Socket` serves it on `<store>.omunculus.sock` (mode 0600) as the local principal, the one the direct CLI uses; only there, `POST /v1/cli` runs a forwarded command line through `CLI.in_project/2`. The versioned contract exposes scoped conversations, snapshots, events, a WebSocket event stream (`Server.EventStream`) and typed commands; the core store enforces access. `OpenAPI.route` registers a Plug route and its operation together; `/openapi.json` renders an OpenAPI 3.1 document from these declarations and schemas in `OpenAPI`. |
| `Omunculus.Tool.Catalog`, `Manifest`, `Views`, `Overrides`, `Invoke`, `Omunculus.Skills` | Discover `tool.toml` / `hook.toml` folders, Agent Skills and MCP servers, parse manifests (including `chains`, `then`, `secrets`, named `schemas` and `[views.<key>]` tables), parse and hydrate a call's views — each a core `source` read from an anchor (`from`) with that source's options, scoped to the call's conversation — apply a run's `overrides` (`then`, `chains`, `schema`) to the catalog, and call a tool either as an Elixir module or as an external command fed JSON on stdin. `Manifest.card/1` is `- name: description [tags: a, b]`; no tags, no suffix. |
| `Omunculus.Tools.*`, `Omunculus.Hooks.Noop` | The builtin tools. Each has a manifest under `priv/tools/<name>/` and a module here; the builtin hooks (`on-request`, `on-notify`, `on-continue`, `on-break`) all use `Hooks.Noop`. The model tools that hand a work away (`work`, `done`, `break`, `request_access`) take a `report` and end the run through `then = ["end"]`; each work `work` creates may name its `agent` or its `workflow`, which the work keeps and goes through; `delegate` and `continue` are chain-only steps of `work` and `done`; `grant` and `cancel` are chain-only steps of `reply`, which omits null or empty options, answers with text and chains a chosen option when given; `forward` hands what the person said to a root work of the run's conversation still open, as a message that opens a run of it, and the store refuses a run's message to a work of another conversation; `reopen` sends a work below the run's own that broke back to its agent, another named at its depth, or, in a workflow, the agent of a stage it names up to its own, from which the work goes through the stages after again, with instructions, granting it on that work the names it lists that the parent could grant on a request, and ends the run, and delegating is refused while such a work waits on the parent; `config` and `overview` print the project's setup to a model as they do on the command line, logins' keys left out; `propose_config` loads the config one change of an item would make and, only when it loads, asks the person in a request whose `apply` option calls `configure` with it at the file's revision, ending the run; each refuses a change whose agents lack a step a tool of theirs that ends the run chains (`Tools.Steps`); `propose_pack` does the same for importing a pack, its `apply` option calling `pack`, and says each of the pack's agents at the depth and on the model it would run, and what its `environment/` holds; `escalate` is a model tool that merges named origins and ends its run; `reply` accepts recursive named parts, validates them before chaining effects, and retains human-only sealed and permanent grants through intermediaries. `ask` asks for any decision, its options named answers that call nothing, of the agent above or, with `to = person`, of the person; `request_access` asks in one request for every tool, path, directory and sandbox capability it lists, each option granting them all; `changes` lists, call by call, the files the calls of the run's work or of a work below it changed, or their unified diff, as `[store] changes` recorded them — from the command line, of the work named, with read access to its conversation — and `revert` puts those files back as they were before the work, refusing when one changed since; `skill` reads one of the skills the run has, which `assemble` lists under `## Skills`. `Tools.Session` rebuilds, from the work's closed runs, or for a run without a work from its conversation's closed runs that had none, the session a run continues: with `[policy] session_ttl_ms` and `session_max_bytes`, a run of the agent whose last run there paused (an answer, a request, children, a retry) recently goes on as the same conversation, under the instructions it started with, and is told only what happened since; a session that cannot be rebuilt exactly, or a hand-on (`continue`, `break`), starts over. A run without a work is shown its conversation's root works under `## Works` and, when its session starts over, what the person and the agent said there under `## Conversation`, each the newest that fits `[policy] conversation_bytes`. |
| `Omunculus.Sandbox` | Runs the code the model submits inside the execution sandbox and answers each `tools.<name>(args)` call it makes. |
| `Omunculus.Execution.*` | Starts every external process through Bubblewrap under an immutable per-run policy, with concurrency, queue, timeout and output limits. |
| `Omunculus.Mcp` | JSON-RPC to one MCP server, run through the execution sandbox, for discovery and calls. |
| `Omunculus.Model.Fake`, `Battery`, `OpenAI`, `OpenAIResponses`, `AnthropicMessages`, `Command` | Model adapters, picked by `api` in `[models.<name>]`. `api = "module"` names an Elixir adapter: `Fake` echoes the first prompt line, `Battery` is the scripted "count to 5" model. `openai-completions` posts to `/chat/completions`, `openai-responses` to `/responses`, `anthropic-messages` to `/messages`; with `stream = true` they read the reply as server-sent events through `Model.EventStream`. The two OpenAI adapters record the server's `usage` with each reply and keep it out of the next request. `command` runs an external program over the sandbox NDJSON protocol, where `{type: delta, text}` lines carry partial text. An adapter is a `(assembled, tools, call, record, delta, execution)` fun: `record` writes `EVENTS(model)`, `delta` publishes partial reply text on the store connection without recording it. |

### The run cycle

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
      until the model calls end (EVENTS(end)) or stops (EVENTS(model))
      EVENTS(end-run), RUNS.status = done
  → follow_up/3 makes the runs the ending call asked for due, runs the hooks
    of end, then makes the reaction runs of calling hooks due
  → a model that stopped without end on a work still open: a run with
    via = retry on that work, or, once [policy] max_retries is used up, a
    break (a child) or a request to the person with retry / cancel (a root)
  → the command returns when every run it opened, transitively, has finished
```

### Configuration

All configuration is TOML. The project file is `./omunculus.toml`, or the path `--config` names; the project root is its directory, or `[project] root`. The optional server uses its own TOML registry of project config paths, run and stream limits, and an optional TCP listener with JWT verification. There is no package config: a missing project file is `` no config at <path>; run `omunculus preset <name> --from <dir>` ``. The presets under `priv/presets/` (`default`, `codex-like`, `pi-like`) are copied into the project by the `preset` tool. Memberships are state in the store; role definitions are configuration.

### Tools, hooks and presets

A tool is a folder with `tool.toml` and either `module = "Elixir.Module"` or `command = ["./run"]`. A hook is the same with `hook.toml` and `events = [...]`. Discovery walks `[tools] paths` in order, then `[[mcp.servers]]`, then inline `[tools.<name>]` tables; the last declaration of a name wins. A name the `cli` or `harness` trigger dispatches that the catalog lacks is looked up among the package's `priv/tools` folders. The CLI and the model call the same contract: `in: {name, args, view, run_id, work_id, workspace, roots, config_path}`, `out: {ok, output, emit, chain}`.

`triggers` lists `model`, `cli` and `chain`, or is `harness` alone; only `model` tools become cards. A tool may chain others in the same call: the steps are `out.chain` (`[{name, args}]`) followed by the manifest's `then` (names run with empty args). The manifest's `chains` whitelists the names it may chain; every `then` name is in `chains`, and `end` is last. Each step must have the `chain` trigger, be have in the run's ceiling when there is a run, not already be on the chain path and not come after `end`; it is recorded as `EVENTS(tool)` with `via` = the tool that chained it. A refused or failed step fails the whole call and writes none of its emits.

## Layout

```text
bin/omunculus        shell wrapper: mise exec -- mix omunculus
bin/omunculus-gui    opens the window on a project of a running server's registry
gui/                 the window: QML on Quickshell, a client of the server's local socket
apps/mailbox/        the mailbox: a concept client on the window's controls, launched by apps/mailbox/run
lib/omunculus/       core, config, server, tool, tools, hooks, models, execution, store
lib/mix/tasks/       the omunculus, omunculus.presets and omunculus.socket mix tasks
priv/tools/          builtin tool and hook manifests
priv/presets/        default, codex-like, pi-like
priv/sandbox.js      tool-call bridge run by Omunculus.Sandbox
test/omunculus/      mirrors lib/; matrix_test.exs and spec_regression_test.exs are the scenario suites
test/support/        fixtures, store case, scripted model, chain tool, execution policy
                     fixtures, command model bridge, MCP server, Rust OpenAI stub
bench/               resident capacity benchmark
mise-tasks/          validate/regular, validate/sandbox, pre-commit, pre-push, benchmark/*
```

## Commands

```sh
mise install                    # toolchain from mise.toml
mix deps.get
mise run validate:regular       # mix test --exclude cargo --exclude sandbox
mise run validate:sandbox       # needs Linux with Bubblewrap namespaces
mise run pre-commit             # mix format --check-formatted
mise run pre-push               # validate:regular
mix compile --warnings-as-errors
bin/omunculus preset default --from priv/presets/default
bin/omunculus send "text"
bin/omunculus serve --config server.toml
bin/omunculus-gui --config server.toml [--project <id>]
mise run up                     # dev server and window; the server stops with the window
apps/mailbox/run --config server.toml [--project <id>]
```

### The window

`gui/` is a client of the server, like any other: it never opens the store or the TOML. The `Omunculus` singleton holds the project as the window sees it and makes every request through `curl` on the project's local socket; the conversation's event stream is `curl` on its WebSocket, whose frames it splits into events. It folds the events into threads: the main one, yours with the root agent, and one per work handed down, where its agent's runs show; a run at depth 0 belongs to the main thread, a deeper one to its work's. Requests with options have choice buttons; an escalated question with no top-level options has a text reply field, which omits `option` from the command. Requests and unread notes are not in threads: they hang from the work that made them on the orchestration map. It reads the snapshot again after each event. Views only bind that singleton. The controls and the theme are a copy of eco's overlay, Omarchy's voice session app. It needs Quickshell, `curl` with WebSocket support and a Wayland session; `bin/omunculus-gui` takes the server registry and a project id, which may be left out when the registry holds one project; `mix omunculus.socket` resolves the project's socket, and the launcher passes both as `OMUNCULUS_GUI_SOCKET` and `OMUNCULUS_GUI_PROJECT`.

### The mailbox

`apps/mailbox/` is a concept client beside the window, built on its controls: `apps/mailbox/gui` links to `gui/`, since Quickshell imports only from within the folder it runs, and the mailbox takes the window's theme, controls and `Requests.js` from there. A thread is a conversation with one agent of depth 0. A new thread needs its To, one agent of depth 0 that is not workflow-only, of one project, as the config tool prints them through `/v1/cli`; its first message names that agent, and every later one names it again. The thread shows, in order, what you wrote, what each run of an agent of depth 0 said (its model text and its comments), and each request whose arbiter is you, which, while pending, takes an option or a text answer through the reply endpoint. A message carries the files you pick, which `apps/mailbox/post-with-files` sends in base64 from a temporary file; a file a message or an agent's `attach` carries shows as a chip, which `apps/mailbox/open-attachment` saves to the downloads directory, beside a different file of the same name rather than over it, and opens. A thread is working while a run is open and waiting for you while such a request is pending; the folders are all threads, those waiting for you and those working, filtered by project. The `Mail` singleton reads `GET /v1/projects` on the socket it was opened on, then each project's conversations, each one's snapshot every few seconds and its events when the snapshot's cursor moved, all through `curl`; which messages you read is kept in Quickshell's state directory, and a word from an agent in a thread not on screen is announced with `notify-send`. Wide, the folders, the list and the thread sit side by side; narrower, the folders become a rail of icons; narrow, one pane shows at a time. `apps/mailbox/run` takes the server registry and, when it holds several projects, the id of the one whose socket it opens through, and passes that socket as `OMUNCULUS_MAILBOX_SOCKET`.

### The development environment

`dev/` holds a server registry with one project, `dev`, whose config is the default preset's agents on `openai/gpt-6-luna` through OpenRouter, with `[access]` roles; its root is `dev/workspace` and its store `dev/.omunculus/`, both ignored by git. Its tools and sandbox script are the checkout's `priv/`, and the server runs from the checkout, so the environment runs the current code. `config_test.exs` loads both files, so a change to the config format updates them in the same commit. The tasks are atomic:

| Task | Does |
| --- | --- |
| `dev:bootstrap` | creates `dev/workspace` and seeds the local administrator while the store does not exist |
| `dev:serve` | runs the server on `dev/server.toml`, with the variables of `.env` (`OPENROUTER_API_KEY`) in its environment |
| `dev:gui` | opens the window on the `dev` project of a running server |
| `dev:mailbox` | opens the mailbox on the `dev` project of a running server |
| `dev:reset` | deletes the store and the workspace |
| `up` | `dev:bootstrap`, then `dev:serve` in the background unless a server already answers, then `dev:gui`; a server it started stops when the window closes |

While the dev server runs, `bin/omunculus --config dev/omunculus.toml <command>` goes to it through the socket.

The eval runner answers free-text request envelopes with its simulated person, once per envelope, and returns text for intermediaries to distribute; named decisions/grants keep their task-defined answers, including through nested escalation; an envelope with grant provenance never falls back to the person model. It records one conversation exchange per answered envelope and follows replies until no answer is made or the execution timeout. The eval human-gated workers request sealed permissions through Father, who escalates to the configured human. The eval deploy mirror saves extensionless page URLs as `<path>/index.html` and preserves explicit filenames. Its network_to_person metric counts request envelopes received by a human, including escalations.

The CLI reads no environment variables. The config file, and with it the model of every agent, comes from `--config <path>` or `./omunculus.toml`.

## Premises

- **Performance is a reason to change.** If a change is correct and
  makes sense, do it even when the measured gain is 0.01 ms. Do not
  skip a worthwhile optimisation because the delta is small. Measure
  when the cost of being wrong is high; do not use "nobody can
  perceive it" as a veto.
- **Zero dead code.** Delete unused functions, types, imports, flags,
  and files. Do not leave a replacement beside the thing it replaces.
- **Zero duplicated code.** One implementation of a behaviour. Extract
  or share rather than copy.
- **Zero legacy code.** No compatibility shims, deprecated aliases,
  dual paths, or "keep the old one until later" leftovers. Finish the
  cutover in the same change that introduces the new path.
- **Comments state the code.** A comment names what the next lines
  do, or a constraint the type system cannot. It is not a tutorial,
  a history, or a design essay.
- **Documentation lives in `docs/`.** Guides, measurements, language
  traps, and "how this is meant to be used" go there — not in
  comments, not in commit messages as a substitute for a doc, and not
  in this file except as rules.
- **Clean up after every run.** A test, run, evaluation or benchmark
  ends by removing what it started, when it passes and when it fails:
  stop the processes, servers and environments it brought up; remove the
  containers, images, volumes and networks it created; delete the build
  caches, temporary files and scratch folders it wrote. Keep only the
  result it was meant to produce. Nothing it started is left using disk,
  CPU or memory.
- **English only.** Code, comments, commit messages, `docs/`,
  `README.md`, this file, mise task names and descriptions: English.

## Tooling: mise

mise owns the toolchain and every project command. Pin tools in
`mise.toml`. Run `mise install` before work. Invoke tools through
mise (`mise exec -- …` or, once defined, `mise run <task>`). Do not
call a system compiler or helper that is not the pinned one. Do not
add a parallel runner (Make, npm scripts, ad-hoc shell wrappers)
that duplicates a mise task.

### Tasks

Work lives in **scripts**, not in `mise.toml` bodies and not in
`mise-tasks/`. Each script is one job. mise **consumes** those
scripts: a `[tasks.name]` entry names the script, sets
`description` / `depends` / `env` / `sources` / `outputs` /
`usage` / `confirm`, and runs it. Git hooks and any other caller
run the same file. Do not duplicate the job as inline `run =`
shell, a file task, and a script.

- Put scripts under `scripts/`. Make them executable, with a
  shebang. Prefer `MISE_PROJECT_ROOT` when the script must know
  the repo root; otherwise relative paths from the project root
  (mise sets cwd to the directory of `mise.toml`).
- **Atomic:** one script, one responsibility. Compose larger work
  with `depends` (may run in parallel) or a `run` **array** of
  script invocations (sequential; a failure stops the rest,
  `set -e` for `sh`/`bash`/`zsh`). Aggregators (`check`, `bench`,
  `build`) only wire scripts together. The documented entry is
  `mise run <name>`; a hook calls `scripts/<name>`, not a second
  copy of the logic.
- **Idempotent:** running the same script twice with the same
  inputs leaves the tree in the same good state. Safe to re-run
  from a hook, CI, or `mise run`.
- Give every task a `description`. Use `alias` only when the short
  name is used often. Confirm destructive tasks with `confirm`.
- Declare `sources` and `outputs` when a task is skippable if
  inputs have not changed (builds). Use `sources` alone with
  `mise watch`.
- Arguments: a `usage` spec on the TOML task. Values arrive as
  `usage_*` environment variables. Do not use the deprecated Tera
  `arg()` / `option()` / `flag()` helpers.
- Do not add file tasks under `mise-tasks/` (or the other mise
  task directories). Do not keep a TOML task and a file task for
  the same name.
- List and inspect with `mise tasks ls` and
  `mise tasks info <name>`. Run with `mise run <name>`. Do not
  tell the user to `mise exec` a one-off that already has a task.
  Do not tell them to invoke `scripts/` when a task exists, except
  from git hooks and other non-mise entry points that must call
  the script directly.

## Documentation

Documentation is written for somebody using the project, one question
at a time, and kept true by the same tools that build it.

### The pages

- `README.md` is the front door, written for somebody installing the
  released program: what the project is in one paragraph, pictures of
  it working, Install (the release's installer, never development
  commands), Start here, the big ideas as short bold-led paragraphs
  each linking its page, the interface (keys, with a picture), What it
  does not do, Known limitations, What is broken (only while a defect
  is known), one line sending contributors to the design page,
  Requirements, license. Development and build commands live in the
  design page, not here.
- `docs/README.md` is the map: every page in the order somebody meets
  it, one line each on the question it answers, the shortest useful
  path, a "when you know what you want" table, and the conventions
  every page shares.
- `docs/how-to-*.md` holds one task per page. Each opens with
  "**The question:**" and says whether it is enough on its own, then
  "Before you start", then numbered steps, each with the command or
  the action and its real output, and ends with what can go wrong and
  where to go next. A page never explains a task that has its own page;
  it links it.
- `docs/screens.md` walks every screen in the order of use, with
  pictures, keys, and the screens that have none. It says how its
  pictures are made and what in them is pinned.
- `docs/cli.md` is generated from the program's own command
  definitions by a mise task, never edited by hand; `mise run check`
  fails when it is stale.
- `docs/what-does-not-work.md` exists only while a known defect is not
  fixed: every such defect, numbered, each with **What happens.** and
  **What to do in the meantime.**, and whether it was seen running or
  read in the code, with a "What is broken" section in `README.md`
  sampling it. No other page names a defect that is not there. When
  the last defect is fixed, the page and the README section go; when a
  known defect is left unfixed, both come back in the same change.
- Limits of the platform or of a provider are not defects: `README.md`
  lists them under "Known limitations", and each is said again on the
  page where somebody meets it.
- `docs/design.md` is for contributors: the model, the architecture,
  state on disk, protocols, packaging, what it is and is not, what was
  measured. Its sections are numbered and the numbers do not move: code
  and pages cite them as `docs/design.md §N`.

### Pictures

Pictures in `docs/img` are generated from the real program by a mise
task, against an isolated instance seeded with synthetic, versioned
fixtures — never the developer's own data, accounts or keys. Name them
`NN-<what>.png` in the order the screens page walks them. Look at every
picture a change produces. A picture that cannot be generated says so,
and where it came from.

### Discipline

- The documentation changes in the same change as the behaviour it
  describes: a new or changed command, screen, setting or defect
  updates its pages, pictures and `docs/cli.md` in that change.
- Facts come from the code or from running it. Outputs are real
  outputs. What was measured is said to be measured; what was only
  argued or read is said so in those words.
- Plain, short sentences: say what happens and what to do. No
  marketing, no promises of future work outside the defects page.
- Placeholders are named as placeholders the first time they appear.
- Every relative link, image and anchor resolves; `mise run check`
  runs a link check that fails when one does not.

## Commits (okt-task-commit)

Agents draft and create commits. The human owns publication: **never
`git push`**. When the tree is clean, say that a push is ready.

These rules inline the okt-task-commit playbook, the Conventional
Commits 1.0.0 grammar used with it, and the conventional-commits law.
There is nothing extra to fetch.

### Procedure

1. Read `git status` and `git diff --cached`. If nothing is staged,
   read the unstaged diff (`git diff` and untracked files).
2. Group hunks into **one intent per commit**. Split mixed trees with
   non-interactive staging only: `git add <path>` and
   `git restore --staged <path>`. Do not use `git add -p` or
   `git add -i`.
3. Derive **scope** from the paths touched (package, directory, or
   feature slug).
4. Draft the message (grammar below). Show every draft to the user
   **before** `git commit`.
5. Commit. Do not push. When the working tree is clean, suggest the
   user push when ready.

### Message grammar

```
<type>(<scope>)!: <subject>

<body>

<footer(s)>
```

- **type** (required): `feat`, `fix`, `docs`, `refactor`, `chore`,
  `test`, `build`, `ci`, `perf`. `feat` and `fix` are
  SemVer-significant. One type per commit: a feature and a fix are
  two commits.
- **scope**: noun in parentheses, from the paths. Omit only when no
  scope is honest.
- **!**: immediately before `:` for a breaking change
  (`feat(api)!: …`). Pair with a `BREAKING CHANGE:` footer.
- **subject**: English, imperative mood ("Add" not "Added"), ≤50
  characters, no trailing period, lowercase after the colon.
- **body** (optional): wrap at 72 columns. Explain the *why* the
  diff does not. Not a paste of the patch.
- **footers**: `Token: value` lines (`Refs: #123`,
  `BREAKING CHANGE: drops X`).

Never attribute a commit to an agent: no `Co-Authored-By: <model>`,
no `Generated with <tool>`, no model name in trailer or body. The
human running the session is the author. No opt-out. Other
`Co-Authored-By` trailers only if the user asked for that person in
this conversation.

Bad: `feat: add filter and fix duplicate insert` (two intents).
Good: `feat(filter): add priority option` then
`fix(insert): prevent duplicates`.

## This project

Omunculus is a local harness that orchestrates tool-using language models,
driven from a direct CLI or an optional HTTP server. It opens a SQLite store
per project, assembles a prompt for one run, lets the model call tools inside
the execution sandbox, records every step as an event, and applies the store
actions those tools emit. Works, conversations, memberships, requests,
notifications and workflow stages are state in the store; the harness only
follows them. It targets Linux, Elixir 1.17, OTP 27, Deno 2.9 and Bubblewrap
0.8 or newer, pinned in `mise.toml`.

The core is `lib/omunculus/`: the CLI and the project's cycle of runs; the
config loader; the harness, which discovers, authorizes, calls and records
tools and applies their actions; the run, which drives one model until it
ends; the ceiling, which decides what a run may call; the store, the only code
that touches SQL; the server and its `/v1` contract; the tool catalog and the
builtin tools under `priv/tools/`; the sandbox and every external process
under Bubblewrap; MCP servers; and the model adapters. Teams come as packs
(`priv/packs/system`, `packs/`); presets are in `priv/presets/`.

All configuration comes from the user's TOML: no hardcoded default for
anything the config file holds, and none stored in the database. Anything
that searches, filters or formats for the model is a tool, never harness
logic. The harness does not protect users from their own tools and hooks: it
guarantees the workflow sequence, the ceiling per stage and the store rules.

Clients reach a project only through the server’s `/v1` contract and never
read the store, the TOML, `lib/` or `priv/`. The core never names a client;
contract changes include the OpenAPI schema, tests and `docs/server.md`.

Commits stay local on the working branch; there are no pull requests. Before
committing, `mise run pre-commit` and `mise run validate:regular` pass and
`mix compile --warnings-as-errors` is clean. `mise run validate:sandbox`
needs Bubblewrap namespaces. `mise run up` starts the development server
(`dev/`).

Guides: `docs/README.md` is the map of every page; `docs/design.md` (the
model, each core module and the run cycle, in numbered sections), the
`docs/how-to-*.md` task pages, `docs/cli.md` (generated by
`mise run docs:cli`), `docs/config.md`, `docs/packs.md`, `docs/cycle.md`,
`docs/ceiling.md`, `docs/tools.md`, `docs/requests.md`, `docs/server.md`,
`docs/clients.md`,
`docs/development.md`, `docs/possibilities.md`, `docs/comparison.md`,
`docs/what-does-not-work.md`; `eval/README.md` (the behaviour benchmark) and
`bench/README.md` (the capacity benchmark). Setup: `README.md`.
