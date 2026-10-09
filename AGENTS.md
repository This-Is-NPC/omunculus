# AGENTS.md

Instructions for any agent or person working in this repository. Everything here describes the code as it is on the current commit. If the code changes, change this file in the same commit.

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
| `Omunculus.Config` | Loads and validates `omunculus.toml`: policy (including `assemble`, the required `max_retries` and the optional `last_run_output_bytes`, `tool_output_bytes` and `send_catalog`), depth layers, workspaces, agents, workflows (each layer with its per-tool `overrides`), models, `[auth]`, optional `[access]` role definitions, MCP servers, `[skills] paths`, `[secrets.<tool>]` (and an MCP server's `secrets`) binding the secrets a tool's process receives to `[auth]` providers, `[store]` and the required `[execution]` table (including `resources`, `max_concurrent`, `max_queue` and `queue_timeout_ms`). `Config.Layer` is one ceiling layer; `Config.Toml` encodes the file. Also rewrites the file for permanent grants and for `edit/5`, which writes one item a client edits (an agent, model, workflow, workspace, `auth` provider or tool `secrets`, or the `policy` or `access` table) while the file is at the revision `document/1` read and the result loads; either way it replaces the file whole through a temporary file. |
| `Omunculus.Harness` | Discovers the catalog, checks the trigger, hydrates the views a manifest declares, resolves the secrets a tool declares through `Omunculus.Secrets`, invokes the tool and the steps it chains with them, masks their values in what it returns, records `EVENTS(tool)` for each, and applies all their emitted actions in one transaction; a model's call whose actions the store refuses is recorded as failed, its output the refusal, and applies none of them. `end` is the only event that ends a run. Hooks of every other event run immediately; hooks of `end` wait until the run has closed and the runs its events ask for are due. `open_due/2` (after each model call) and `follow_up/3` (after the close) write permanent grants to the TOML before making runs due; a `reply` opens a run of the requester's work when that work is open, or, for a request from a run without a work, a run of that run's agent in its conversation. |
| `Omunculus.Run` | Opens one run, holding a slot of the execution limiter's `run` class (`[execution]` `max_concurrent`, `max_queue`, `queue_timeout_ms`): resolves the agent from the workflow stage, the work's assignee or the depth, mounts the ceiling, builds the execution policy (with `[policy] send_catalog` the model is sent every model tool of the catalog, so all agents' requests start alike, and may call only its own), begins the run with the event that made it due as its `cause_id`, dispatches the `assemble` tool, attaches `PROMPTS(assembled)`, drives the model until it calls `end` or stops, making the runs each call's actions ask for due at once, closes the run, then retries a work whose model stopped without `end`; over `max_retries` it breaks a child work and opens a request to the human, with `retry` and `cancel` options and an inbox entry, for a root work. A cancelled work opens no run; a work's own run does not open once the work is no longer open. |
| `Omunculus.Ceiling` | Intersects the policy, workspace, depth, agent and stage layers into the effective tool set of a run and classifies a name as have, askable, sealed or blocked. `pinned` intersects the same way and marks which effective tools become cards when `tool_search` is present. The same layers resolve the run's per-tool `overrides`, the most specific layer winning per key; the snapshot carries them. |
| `Omunculus.Store` and `Omunculus.Store.*` | The only code that touches SQL. `Connection` is the one process that owns the SQLite handle; every statement and transaction runs in it, so concurrent runs apply their transactions one after another, and it announces committed events to the processes subscribed to it. `Access` checks project and conversation memberships, scopes reads, and manages idempotent command receipts. `View` reads cuts of the tables. `Actions` applies emits (`comment`, `request`, `reply`, `grant`, `cancel`, `work`, `delegate`, `continue`, `break`, `end`, `notify`, `prompt`, `compact`, ...); a request carries named options of tool calls and its arbiter is resolved in the store. `Runs` and `Events` write the run lifecycle; `Runs.record_tools` records a call and its chained steps as one transaction; `Runs.unreported` decides a retry, break or request in one. `Schema` creates eleven tables. |
| `Omunculus.Operations` | Shares tool dispatch, human authorization and cycle follow-up between the direct CLI and HTTP commands. |
| `Omunculus.Server` and `Omunculus.Server.*` | Optional Bandit/Plug HTTP server. Its TOML registry maps project IDs to project configs and holds run/stream limits; an optional TCP listener (`host`, `port`) comes with `[auth]`, which maps JWT claims to human principals. Each project owns a persistent cycle, and `Server.Socket` serves it on `<store>.omunculus.sock` (mode 0600) as the local principal, the one the direct CLI uses; only there, `POST /v1/cli` runs a forwarded command line through `CLI.in_project/2`. The versioned contract exposes scoped conversations, snapshots, events, a WebSocket event stream (`Server.EventStream`) and typed commands; the core store enforces access. `OpenAPI.route` registers a Plug route and its operation together; `/openapi.json` renders an OpenAPI 3.1 document from these declarations and schemas in `OpenAPI`. |
| `Omunculus.Tool.Catalog`, `Manifest`, `Views`, `Overrides`, `Invoke`, `Omunculus.Skills` | Discover `tool.toml` / `hook.toml` folders, Agent Skills and MCP servers, parse manifests (including `chains`, `then`, `secrets`, named `schemas` and `[views.<key>]` tables), parse and hydrate a call's views — each a core `source` read from an anchor (`from`) with that source's options, scoped to the call's conversation — apply a run's `overrides` (`then`, `chains`, `schema`) to the catalog, and call a tool either as an Elixir module or as an external command fed JSON on stdin. `Manifest.card/1` is `- name: description [tags: a, b]`; no tags, no suffix. |
| `Omunculus.Tools.*`, `Omunculus.Hooks.Noop` | The builtin tools. Each has a manifest under `priv/tools/<name>/` and a module here; the builtin hooks (`on-request`, `on-notify`, `on-continue`, `on-break`) all use `Hooks.Noop`. The model tools that hand a work away (`work`, `done`, `break`, `request_access`, `request_sandbox`) take a `report` and end the run through `then = ["end"]`; `delegate` and `continue` are chain-only steps of `work` and `done`; `grant` and `cancel` are chain-only steps of `reply`, which chains the chosen option of a request; `skill` reads one of the skills the run has, which `assemble` lists under `## Skills`. |
| `Omunculus.Sandbox` | Runs the code the model submits inside the execution sandbox and answers each `tools.<name>(args)` call it makes. |
| `Omunculus.Execution.*` | Starts every external process through Bubblewrap under an immutable per-run policy, with concurrency, queue, timeout and output limits. A command's secrets reach its process alone, as read-only files at `/run/secrets/<NAME>` named by `<NAME>_FILE`, written into that process's temporary directory before it starts and removed with it; the policy never holds them. |
| `Omunculus.Mcp` | JSON-RPC to one MCP server, run through the execution sandbox, for discovery and calls. |
| `Omunculus.Model.Fake`, `Battery`, `OpenAI`, `OpenAIResponses`, `AnthropicMessages`, `Command` | Model adapters, picked by `api` in `[models.<name>]`. `api = "module"` names an Elixir adapter: `Fake` echoes the first prompt line, `Battery` is the scripted "count to 5" model. `openai-completions` posts to `/chat/completions`, `openai-responses` to `/responses`, `anthropic-messages` to `/messages`; with `stream = true` they read the reply as server-sent events through `Model.EventStream`. The HTTP adapters record the server's `usage` with each reply and keep it out of the next request; `anthropic-messages` marks two cache breakpoints, the end of the instructions and the end of the last turn. Each HTTP adapter merges the model's `body` table over the request it builds. `command` runs an external program over the sandbox NDJSON protocol, where `{type: delta, text}` lines carry partial text. An adapter is a `(prompt, tools, call, record, delta, execution)` fun, where `prompt` is an `Omunculus.Prompt`: the assembled `instructions`, which the HTTP adapters send apart from the run's `context` (a `system` message, the Responses `instructions`, a cached Anthropic `system` block) so the provider can reuse them from its cache; `record` writes `EVENTS(model)`, `delta` publishes partial reply text on the store connection without recording it. |

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

A tool is a folder with `tool.toml` and either `module = "Elixir.Module"` or `command = ["./run"]`. A hook is the same with `hook.toml` and `events = [...]`. Discovery walks `[tools] paths` in order, then the Agent Skills of `[skills] paths` (`SKILL.md` folders, each the catalog entry `skill.<name>` in the group `skills`), then `[[mcp.servers]]`, then inline `[tools.<name>]` tables; the last declaration of a name wins. A name the `cli` or `harness` trigger dispatches that the catalog lacks is looked up among the package's `priv/tools` folders. The CLI and the model call the same contract: `in: {name, args, view, run_id, work_id, workspace, roots, config_path}`, `out: {ok, output, emit, chain, instructions}`; `instructions` is what the `assemble` tool puts before its `output`, the part of a prompt that stays the same from run to run.

`triggers` lists `model`, `cli` and `chain`, or is `harness` alone; only `model` tools become cards. A tool may chain others in the same call: the steps are `out.chain` (`[{name, args}]`) followed by the manifest's `then` (names run with empty args). The manifest's `chains` whitelists the names it may chain; every `then` name is in `chains`, and `end` is last. Each step must have the `chain` trigger, be have in the run's ceiling when there is a run, not already be on the chain path and not come after `end`; it is recorded as `EVENTS(tool)` with `via` = the tool that chained it. A refused or failed step fails the whole call and writes none of its emits.

## Layout

```text
bin/omunculus        shell wrapper: mise exec -- mix omunculus
bin/omunculus-gui    opens the window on a project of a running server's registry
gui/                 the window: QML on Quickshell, a client of the server's local socket
lib/omunculus/       core, config, server, tool, tools, hooks, models, execution, store
lib/mix/tasks/       the omunculus, omunculus.presets and omunculus.socket mix tasks
priv/tools/          builtin tool and hook manifests
priv/presets/        default, codex-like, pi-like
priv/sandbox.js      tool-call bridge run by Omunculus.Sandbox
test/omunculus/      mirrors lib/; matrix_test.exs and spec_regression_test.exs are the scenario suites
test/support/        fixtures, store case, scripted model, chain tool, execution policy
                     fixtures, command model bridge, MCP server, Rust OpenAI stub
bench/               resident capacity benchmark
eval/                Equivalent Exchange, the behaviour benchmark: the Amestris preset,
                     its configurations, tasks and runner (mise run eval:run); each run
                     writes eval/results/<time>-<label>/, ignored by git
mise-tasks/          validate/regular, validate/sandbox, pre-commit, pre-push, up, dev/*, benchmark/*, eval/*
dev/                 the development environment: server registry and project config
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
```

### The window

`gui/` is a client of the server, like any other: it never opens the store or the TOML. The `Omunculus` singleton holds the project as the window sees it and makes every request through `curl` on the project's local socket; the conversation's event stream is `curl` on its WebSocket, whose frames it splits into events. It folds the events into threads: the main one, yours with the root agent, and one per work handed down, where its agent's runs show; a run at depth 0 belongs to the main thread, a deeper one to its work's. Requests and unread notes are not in threads: they hang from the work that made them on the orchestration map. It reads the snapshot again after each event. Views only bind that singleton. The controls and the theme are a copy of eco's overlay, Omarchy's voice session app. It needs Quickshell, `curl` with WebSocket support and a Wayland session; `bin/omunculus-gui` takes the server registry and a project id, which may be left out when the registry holds one project; `mix omunculus.socket` resolves the project's socket, and the launcher passes both as `OMUNCULUS_GUI_SOCKET` and `OMUNCULUS_GUI_PROJECT`.

### The development environment

`dev/` holds a server registry with one project, `dev`, whose config is the default preset's agents on `openai/gpt-6-luna` through OpenRouter, with `[access]` roles; its root is `dev/workspace` and its store `dev/.omunculus/`, both ignored by git. Its tools and sandbox script are the checkout's `priv/`, and the server runs from the checkout, so the environment runs the current code. `config_test.exs` loads both files, so a change to the config format updates them in the same commit. The tasks are atomic:

| Task | Does |
| --- | --- |
| `dev:bootstrap` | creates `dev/workspace` and seeds the local administrator while the store does not exist |
| `dev:serve` | runs the server on `dev/server.toml`, with the variables of `.env` (`OPENROUTER_API_KEY`) in its environment |
| `dev:gui` | opens the window on the `dev` project of a running server |
| `dev:reset` | deletes the store and the workspace |
| `up` | `dev:bootstrap`, then `dev:serve` in the background unless a server already answers, then `dev:gui`; a server it started stops when the window closes |

While the dev server runs, `bin/omunculus --config dev/omunculus.toml <command>` goes to it through the socket.

The CLI reads no environment variables. The config file, and with it the model of every agent, comes from `--config <path>` or `./omunculus.toml`.

## Premises

Every change follows these. They are not aspirational.

1. **Zero legacy code.** What a change replaces is deleted in the same commit. No fallbacks, no compatibility aliases, no old TOML keys accepted silently.
2. **Zero duplicated code.** If two places do the same thing, one calls the other or they become one. This includes tests and fixtures.
3. **Zero dead code.** A function, module, constant, manifest key or test nobody calls after the change is removed in the same commit. `mix compile --warnings-as-errors` must be clean; for public functions, grep for callers before committing.
4. **Document only what exists.** README, `@moduledoc` and this file describe behavior the code has on that commit. No "planned", no "soon", no section for an unimplemented feature.
5. **A comment is a statement about the code, not documentation.** It says what the adjacent line does or why, only when the code alone does not. Do not lift comments into documentation. Do not write a `@moduledoc` that narrates a spec.
6. **All configuration comes from the user's TOML.** No hardcoded defaults for anything that lives in the config file. No configuration stored in the database.
7. **Anything that searches, filters or formats for the model is a tool**, never harness logic. The harness discovers, authorizes, calls, records and applies.
8. **The harness does not protect users from their own tools and hooks.** It guarantees the workflow sequence, the ceiling per stage and the store rules. What a user's hook does with those is the user's responsibility.

## Language

Code, comments, output strings, tool manifests, agent texts, test fixtures and README are in English.

## Commits

Work happens as local commits on the working branch. There are no pull requests.

- **Conventional Commits.** `type(scope): imperative summary`. Types in use: `feat`, `fix`, `docs`, `chore`, `test`, `refactor`. Scope is the module or area (`harness`, `store`, `execution`, `tools`, `config`, `docs`). A breaking change to a contract or file format gets `!` after the scope.
- **One intention per commit.** A commit does one thing: one deviation fixed, one tool added, one document updated. Do not mix a refactor with a behavior change. Do not mix two items.
- **The body says why**, when the summary is not enough. It does not repeat the diff.
- **No AI trailers.** No `Co-Authored-By`, `Generated-with`, `Signed-off-by` for a model, or any other line attributing the commit to an assistant. This applies to commit messages, tags and any pull request description that may ever exist.
- Before committing: `mise run pre-commit` and `mise run validate:regular` pass; `mix compile --warnings-as-errors` is clean.
