# AGENTS.md

The overview of the project and the rules for any agent or person working in
this repository. How the code behaves is documented in `docs/`, not here. A
change updates, in the same commit, the document of `docs/` that describes
what it changes, and this file when it changes the overview, the layout, the
commands or the rules.

## What Omunculus is

A local harness with a direct CLI and an optional HTTP server that
orchestrates tool-using language models. It opens a SQLite store per project,
assembles a prompt for one run, lets the model call tools inside the
execution sandbox, records every step as an event, and applies the store
actions those tools emit. Work items, conversations, memberships, requests,
notifications and workflow stages are state in the store; the harness only
follows them.

Targets Linux, Elixir 1.17, OTP 27, Deno 2.9 and Bubblewrap 0.8 or newer.
Tool versions are pinned in `mise.toml`.

## Architecture

The core is `lib/omunculus/`; read these modules (under `Omunculus.`) first,
in this order.
[docs/architecture.md](docs/architecture.md) details each one and the run
cycle.

| Module | Responsible for |
| --- | --- |
| `CLI` | the direct entry point; forwards to a running server's socket ([cli](docs/cli.md)) |
| `Project` | one project's store connection, config path, cycle and file lock |
| `Cycle` | the runs a command opens, one run per work at a time ([cycle](docs/cycle.md)) |
| `Config` | loading, validating and rewriting `omunculus.toml` ([config](docs/config.md), [packs](docs/packs.md)) |
| `Harness` | discovering, authorizing, calling and recording tools, applying their actions |
| `Run` | one run: agent, ceiling, prompt, model loop, retry or break ([cycle](docs/cycle.md)) |
| `Ceiling` | the effective tool set and overrides of a run ([ceiling](docs/ceiling.md)) |
| `Participant`, `RequestRoutes`, `RequestOptions` | request identities, routes and replies ([requests](docs/requests.md)) |
| `Store`, `Store.*` | the only SQL: access, views, actions, runs, events, schema |
| `Attachments` | files attached to conversations, kept by SHA-256 |
| `Operations` | dispatch and follow-up shared by the CLI and the server |
| `Server`, `Server.*` | the optional HTTP server and its `/v1` contract ([server](docs/server.md)) |
| `Tool.*`, `Skills` | catalog, manifests, views, overrides and invocation ([tools](docs/tools.md)) |
| `Tools.*`, `Hooks.Noop` | the builtin tools and hooks ([tools](docs/tools.md)) |
| `Sandbox`, `Execution.*` | code mode and every external process, under Bubblewrap ([ceiling](docs/ceiling.md)) |
| `Mcp` | MCP servers, run in the sandbox |
| `Model.*` | the model adapters ([config](docs/config.md#models-and-auth)) |

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
mise-tasks/          validate/regular, validate/sandbox, validate/boundaries, pre-commit, pre-push, up, dev/*, benchmark/*, eval/*
dev/                 the development environment: server registry and project config
```

## Commands

```sh
mise install                    # toolchain from mise.toml
mix deps.get
mise run validate:regular       # mix test --exclude cargo --exclude sandbox
mise run validate:sandbox       # needs Linux with Bubblewrap namespaces
mise run pre-commit             # validate:boundaries, then mix format --check-formatted
mise run pre-push               # validate:regular
mix compile --warnings-as-errors
bin/omunculus preset default --from priv/presets/default
bin/omunculus send "text"
bin/omunculus serve --config server.toml
apps/kit/run console --config server.toml [--project <id>]
mise run up                     # the dev server; the apps open with dev:console, dev:studio, dev:mailbox
apps/kit/run mailbox --config server.toml [--project <id>]
apps/kit/run studio --config server.toml [--project <id>]
```

## Documentation

| Document | Covers |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | each core module in detail, and the run cycle |
| [docs/cli.md](docs/cli.md) | the binary, its verbs, presets and its errors |
| [docs/config.md](docs/config.md) | the TOML, table by table |
| [docs/packs.md](docs/packs.md) | importing teams as packs, the system team |
| [docs/cycle.md](docs/cycle.md) | what a send does to the store: runs, assemble, works, requests |
| [docs/ceiling.md](docs/ceiling.md) | the ceiling layers, grants and sandbox resources |
| [docs/tools.md](docs/tools.md) | the tool contract, manifests, chains, views and the builtin tools |
| [docs/requests.md](docs/requests.md) | requests: routing, options, escalation, inbox |
| [docs/server.md](docs/server.md) | the HTTP server, its socket, contract and event stream |
| [docs/clients.md](docs/clients.md) | the client boundary and the apps' kit |
| [docs/console.md](docs/console.md) | the console app |
| [docs/mailbox.md](docs/mailbox.md) | the mailbox app |
| [docs/studio.md](docs/studio.md) | the studio app |
| [docs/development.md](docs/development.md) | the development environment under `dev/` |
| [docs/possibilities.md](docs/possibilities.md) | shapes the TOML can take |
| [docs/comparison.md](docs/comparison.md) | Omunculus compared with other harnesses |
| [eval/README.md](eval/README.md) | Equivalent Exchange, the behaviour benchmark |
| [bench/README.md](bench/README.md) | the resident capacity benchmark |

## Premises

Every change follows these. They are not aspirational.

1. **Zero legacy code.** What a change replaces is deleted in the same commit. No fallbacks, no compatibility aliases, no old TOML keys accepted silently.
2. **Zero duplicated code.** If two places do the same thing, one calls the other or they become one. This includes tests and fixtures.
3. **Zero dead code.** A function, module, constant, manifest key or test nobody calls after the change is removed in the same commit. `mix compile --warnings-as-errors` must be clean; for public functions, grep for callers before committing.
4. **Document only what exists.** README, `docs/`, `@moduledoc` and this file describe behavior the code has on that commit. No "planned", no "soon", no section for an unimplemented feature.
5. **A comment is a statement about the code, not documentation.** It says what the adjacent line does or why, only when the code alone does not. Do not lift comments into documentation. Do not write a `@moduledoc` that narrates a spec.
6. **All configuration comes from the user's TOML.** No hardcoded defaults for anything that lives in the config file. No configuration stored in the database.
7. **Anything that searches, filters or formats for the model is a tool**, never harness logic. The harness discovers, authorizes, calls, records and applies.
8. **The harness does not protect users from their own tools and hooks.** It guarantees the workflow sequence, the ceiling per stage and the store rules. What a user's hook does with those is the user's responsibility.
9. **Clients and the core share only the server's contract.** An app under `apps/` reaches a project through the `/v1` HTTP contract on a socket and never reads the store, the TOML, `lib/` or `priv/`; the core never names an app, and what one needs is added to the contract for every client. `apps/kit/ui` imports nothing of `apps/kit/client`, the kit imports no app, and no app imports another; apps call each other only through Quickshell IPC. See `docs/clients.md`.

## Language

Code, comments, output strings, tool manifests, agent texts, test fixtures, README and `docs/` are in English.

## Commits

Work happens as local commits on the working branch. There are no pull requests.

- **Conventional Commits.** `type(scope): imperative summary`. Types in use: `feat`, `fix`, `docs`, `chore`, `test`, `refactor`. Scope is the module or area (`harness`, `store`, `execution`, `tools`, `config`, `docs`). A breaking change to a contract or file format gets `!` after the scope.
- **One intention per commit.** A commit does one thing: one deviation fixed, one tool added, one document updated. Do not mix a refactor with a behavior change. Do not mix two items.
- **The body says why**, when the summary is not enough. It does not repeat the diff.
- **No AI trailers.** No `Co-Authored-By`, `Generated-with`, `Signed-off-by` for a model, or any other line attributing the commit to an assistant. This applies to commit messages, tags and any pull request description that may ever exist.
- Before committing: `mise run pre-commit` and `mise run validate:regular` pass; `mix compile --warnings-as-errors` is clean.
