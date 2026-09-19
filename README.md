# omunculus

A local CLI harness for tool-using models. The store is one SQLite file, the
ceiling is the TOML, and the filesystem stays the filesystem.

There is no daemon and no chat window. `omunculus send "count to 5"` is a tool
call, the same contract the model uses, and what happens next is already in
the file: a prompt is recorded, a run opens, the model calls tools inside a
Bubblewrap sandbox, every step is an event, and the store applies whatever
those tools emit. Work, requests and notifications are rows. The harness
follows them.

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
bin/omunculus reply "granted" --request_id <id> --decision grant
bin/omunculus login --provider anthropic
```

Every verb is in [the command line](docs/cli.md). The file the verbs read is
[the TOML](docs/config.md). Shapes that file can take are
[possibilities](docs/possibilities.md). What a send actually does to the store
is [the cycle](docs/cycle.md). Who may call what is [the ceiling](docs/ceiling.md).
A folder of your own is [a tool](docs/tools.md).

## Requirements

- Linux, with Bubblewrap 0.8 or newer (`bwrap`) able to create user, mount,
  PID, IPC, UTS and network namespaces
- [mise](https://mise.jdx.dev/) for the pins in `mise.toml` (Elixir 1.17,
  OTP 27, Deno 2.9)
- A project `omunculus.toml` with `[execution]`, `[execution.sandbox]`,
  `[store]` and `[models]`, and every agent naming a model

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
