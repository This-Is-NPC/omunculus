# AGENTS.md

Instructions for any agent or person working in this repository. Everything here describes the code as it is on the current commit. If the code changes, change this file in the same commit.

## What Omunculus is

A local, CLI-only harness that orchestrates tool-using language models. It opens a SQLite store per project, assembles a prompt for one run, lets the model call tools inside the execution sandbox, records every step as an event, and applies the store actions those tools emit. Work items, access requests, notifications and workflow stages are state in the store; the harness only follows them.

Targets Linux, Elixir 1.17, OTP 27, Deno 2.9 and Bubblewrap 0.8 or newer. Tool versions are pinned in `mise.toml`.

## Architecture

The core is `lib/omunculus/`. Read these modules first, in this order.

| Module | Role |
| --- | --- |
| `Omunculus.CLI` | Entry point. `omunculus <name> [--key value]` dispatches a tool with trigger `cli`, then hands the resulting events to the harness. Reads `OMUNCULUS_PROJECT` and `OMUNCULUS_MODEL` from the environment. |
| `Omunculus.Project` | Opens `<project>/.omunculus/store.sqlite3` and holds the connection. |
| `Omunculus.Config` | Loads and validates `omunculus.toml`: policy (including `assemble`), depth layers, workspaces, agents, workflows, MCP servers and the required `[execution]` table (including `resources`). Also rewrites the file for permanent grants. |
| `Omunculus.Harness` | Discovers the catalog, checks the trigger, hydrates the views a manifest declares, invokes the tool, records `EVENTS(tool)`, and applies the emitted actions. Hooks on non-terminal events run immediately; hooks on events that end the run wait until `follow_up/2` has opened the next run. |
| `Omunculus.Run` | Opens one run: resolves the agent for the depth or workflow stage, mounts the ceiling, builds the execution policy, begins the run, dispatches the `assemble` tool, attaches `PROMPTS(assembled)`, drives the model, closes the run. |
| `Omunculus.Ceiling` | Intersects the policy, workspace, depth, agent and stage layers into the effective tool set of a run and classifies a name as have, askable, sealed or blocked. `pinned` intersects the same way and marks which effective tools become cards when `tool_search` is present. |
| `Omunculus.Store` and `Omunculus.Store.*` | The only code that touches SQL. `View` reads cuts of the tables. `Actions` applies emits (`comment`, `request`, `reply`, `work`, `delegate`, `continue`, `break`, `notify`, `prompt`, `compact`, ...). `Runs` and `Events` write the run lifecycle. `Schema` creates the seven tables. |
| `Omunculus.Tool.Catalog`, `Manifest`, `Invoke` | Discover `tool.toml` / `hook.toml` folders and MCP servers, parse manifests, and call a tool either as an Elixir module or as an external command fed JSON on stdin. `Manifest.card/1` is `- name: description [tags: a, b]`; no tags, no suffix. |
| `Omunculus.Tools.*` | The builtin tools. Each has a manifest under `priv/tools/<name>/` and a module here. |
| `Omunculus.Sandbox` | Runs the code the model submits inside the execution sandbox and answers each `tools.<name>(args)` call it makes. |
| `Omunculus.Execution.*` | Starts every external process through Bubblewrap under an immutable per-run policy, with concurrency, queue, timeout and output limits. |
| `Omunculus.Mcp` | JSON-RPC to one MCP server, run through the execution sandbox, for discovery and calls. |
| `Omunculus.Model.Fake`, `Battery`, `OpenAI`, `OpenAIResponses`, `AnthropicMessages`, `Command` | Model adapters. `fake` echoes the first prompt line. `battery` is the scripted "count to 5" model. `openai` posts to `/chat/completions`, `openai-responses` to `/responses`, `anthropic-messages` to `/messages`. `command` runs an external program over the sandbox NDJSON protocol. |

### The run cycle

```text
omunculus send "text"
  → tool send emits prompt → PROMPTS(message) + EVENTS(prompt)
  → follow_up opens a run
      Config.load, Catalog.discover, Ceiling.mount, Policy.build
      RUNS + EVENTS(start-run)
      assemble tool → PROMPTS(assembled) + EVENTS(tool)
      model → tool calls → EVENTS(tool) + emitted actions + hooks
      EVENTS(model), EVENTS(end-run), RUNS.status = done
  → follow_up opens the next run if an action asked for one
```

### Configuration

All configuration is TOML. The project file is `<project>/omunculus.toml`; when it is absent the harness currently loads `priv/omunculus.toml` from the package. Presets under `priv/presets/` are copied into the project by the `preset` tool. Nothing in the store is configuration.

### Tools, hooks and presets

A tool is a folder with `tool.toml` and either `module = "Elixir.Module"` or `command = ["./run"]`. A hook is the same with `hook.toml` and `events = [...]`. Discovery order is builtin (`priv/tools`), user (`~/.omunculus/tools`), MCP servers, then `<project>/tools`; the most specific wins on a shared name. The CLI and the model call the same contract: `in: {name, args, view, run_id, work_id, workspace, roots}`, `out: {ok, output, emit}`.

## Layout

```text
bin/omunculus        shell wrapper: mise exec -- mix omunculus
lib/omunculus/       core, tools, models, execution, store
lib/mix/tasks/       the omunculus mix task
priv/tools/          builtin tool and hook manifests
priv/presets/        codex-like, pi-like
priv/omunculus.toml  package default config
priv/sandbox.js      tool-call bridge run by Omunculus.Sandbox
test/omunculus/      mirrors lib/; matrix_test.exs and spec_regression_test.exs are the scenario suites
test/support/        fixtures, store case, MCP server, Rust OpenAI stub
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
OMUNCULUS_MODEL=fake bin/omunculus send "text"
```

Environment read by the CLI: `OMUNCULUS_PROJECT` (defaults to the current directory), `OMUNCULUS_MODEL` (`fake`, `battery`, `openai`), and for `openai` also `OMUNCULUS_OPENAI_URL`, `OMUNCULUS_OPENAI_MODEL`, optional `OMUNCULUS_OPENAI_KEY`.

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
