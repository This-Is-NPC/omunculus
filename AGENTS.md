# Agent rules

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
apps/kit/run console --config server.toml [--project <id>]
mise run up                     # dev server and window; the server stops with the window
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

1. **Zero legacy code.** What a change replaces is deleted in the same commit. No fallbacks, no compatibility aliases, no old TOML keys accepted silently.
2. **Zero duplicated code.** If two places do the same thing, one calls the other or they become one. This includes tests and fixtures.
3. **Zero dead code.** A function, module, constant, manifest key or test nobody calls after the change is removed in the same commit. `mix compile --warnings-as-errors` must be clean; for public functions, grep for callers before committing.
4. **Document only what exists.** README, `docs/`, `@moduledoc` and this file describe behavior the code has on that commit. No "planned", no "soon", no section for an unimplemented feature.
5. **A comment is a statement about the code, not documentation.** It says what the adjacent line does or why, only when the code alone does not. Do not lift comments into documentation. Do not write a `@moduledoc` that narrates a spec.
6. **All configuration comes from the user's TOML.** No hardcoded defaults for anything that lives in the config file. No configuration stored in the database.
7. **Anything that searches, filters or formats for the model is a tool**, never harness logic. The harness discovers, authorizes, calls, records and applies.
8. **The harness does not protect users from their own tools and hooks.** It guarantees the workflow sequence, the ceiling per stage and the store rules. What a user's hook does with those is the user's responsibility.
9. **Clients and the core share only the server's contract.** An app under `apps/` reaches a project through the `/v1` HTTP contract on a socket and never reads the store, the TOML, `lib/` or `priv/`; the core never names an app, and what one needs is added to the contract for every client. `apps/kit/ui` imports nothing of `apps/kit/client`, the kit imports no app, and no app imports another; apps call each other only through Quickshell IPC. See `docs/clients.md`.

mise owns the toolchain and every project command. Pin tools in
`mise.toml`. Run `mise install` before work. Invoke tools through
mise (`mise exec -- …` or, once defined, `mise run <task>`). Do not
call a system compiler or helper that is not the pinned one. Do not
add a parallel runner (Make, npm scripts, ad-hoc shell wrappers)
that duplicates a mise task.

Code, comments, output strings, tool manifests, agent texts, test fixtures, README and `docs/` are in English.

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
