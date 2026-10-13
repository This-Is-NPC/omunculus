# omunculus

A local harness for tool-using models, with an optional HTTP server. The store is one SQLite file per project, the
ceiling is the TOML, and the filesystem stays the filesystem.

The CLI works directly without a server. `omunculus send "count to 5"` is a tool
call, the same contract the model uses, and what happens next is already in
the file: a prompt is recorded, a run opens, the model calls tools inside a
Bubblewrap sandbox until it calls `end` or stops, every step is an event, and
the store applies whatever those tools emit. Work, requests and notifications are rows. The harness
follows them: the runs they ask for open concurrently, up to `[execution]
max_concurrent`, and the command returns when all of them have finished.

## Install

From a checkout:

```bash
mise install
mix deps.get
```

`bin/omunculus` is the command. It runs through `mise exec`, so the Elixir,
OTP and Deno pins in `mise.toml` are the ones that run. There is no install
into `~/.local` yet.

A project will not start from an empty directory. Copy a preset in — that
writes `omunculus.toml` and is the one verb that does not need the file
already there:

```bash
bin/omunculus preset default --from priv/presets/default
bin/omunculus send "count to 5"
bin/omunculus prompt
```

`send` prints nothing on success. The model's text lives in the store; `prompt`
prints the assembled prompt of the last run. The default preset's model is
`fake`, which echoes the first line, so a first send is a cycle without a
network.

`codex-like` and `pi-like` are the other two folders under `priv/presets/`.
Each is a TOML and, for Codex, a `bash` tool — not a different harness.

## The binary

`omunculus <name> [--key value]` dispatches the tool named `<name>`. Flags
before the name: only `--config <path>`, and without it the file is
`./omunculus.toml` in the working directory. A missing file is a refusal,
not a fall-back to the package.

```bash
bin/omunculus send "look at the inbox"
bin/omunculus inbox
bin/omunculus reply "granted" --request_id <id> --option grant
bin/omunculus login --provider anthropic
```

Every verb is in [the command line](docs/cli.md). The file the verbs read is
[the TOML](docs/config.md). Shapes that file can take are
[possibilities](docs/possibilities.md). What a send actually does to the store
is [the cycle](docs/cycle.md). Who may call what is [the ceiling](docs/ceiling.md).
A folder of your own is [a tool](docs/tools.md).

## HTTP server

The optional [server](docs/server.md) opens configured projects and exposes conversations, commands, snapshots, events and a WebSocket event stream to any HTTP client: to the local user on a Unix socket next to each store, and, when it has a TCP listener, to web apps with signed JWTs. It publishes its OpenAPI contract at `/openapi.json`. Each project keeps its own SQLite store. The server has no built-in chat page.

## Clients

Any program that speaks the server's HTTP contract is a client; what it may
rely on is in [clients](docs/clients.md). The repository's own are under
`apps/`, each opened by `apps/kit/run <app>`. The console opens a window on a project of a running
[server](docs/server.md). It talks to the project's local socket, so it acts
as the local user:

```bash
bin/omunculus serve --config server.toml
apps/kit/run console --config server.toml --project demo
```

`--project` may be left out when the registry holds one project.

From a checkout, `mise run up` starts the development server on `dev/`,
whose agents use `openai/gpt-6-luna` through OpenRouter with the
`OPENROUTER_API_KEY` of `.env`; with it running, `mise run dev:console`,
`dev:studio` and `dev:mailbox` open the apps on it. `mise run dev:reset`
starts that project over.

It lists the conversations and follows the open one live as a chat between
you and the root agent: what each of you said and, on a line below each run,
what the agent did. A map shows the agents at work, each work handed down
joined to the one it came from; whatever an agent asked and still waits for,
and the notes it left you, hang from its node, with the options to answer.
The composer counts what waits on you and leads to the map. Opening a node
shows what that agent said and did, and writes to it. What the conversation
cost opens from its masthead. `apps/kit/run studio` opens the project's
settings, `apps/kit/run mailbox` a mailbox over every project. They need
[Quickshell](https://quickshell.org/), `curl` with WebSocket support and a
Wayland session.

## Requirements

- Linux, with Bubblewrap 0.8 or newer (`bwrap`) able to create user, mount,
  PID, IPC, UTS and network namespaces
- [mise](https://mise.jdx.dev/) for the pins in `mise.toml` (Elixir 1.17,
  OTP 27, Deno 2.9)
- A project `omunculus.toml` with `[execution]`, `[execution.sandbox]`,
  `[store]`, `[models]` and `[policy] max_retries`, every agent naming a
  model, and an assemble tool named in `[policy]` or on the agent
- `git`, only with `[store] changes`, which records the files each model call
  changed in a workspace it may write

The executor does not install Bubblewrap or language runtimes. A runtime root
in `[execution] runtimes` is read-only inside the sandbox and exposes the
binaries it contains; it is not a per-binary allowlist. Keep those
installations outside workspaces.

## Verification

```bash
mise run pre-commit            # mix format --check-formatted
mise run validate:regular      # mix test, excluding cargo and sandbox
mise run validate:sandbox      # needs a host where Bubblewrap can unshare
```

The [benchmark guide](bench/README.md) measures resident capacity by adding
one real run at a time.

## License

Omunculus is available under the [MIT License](LICENSE).
