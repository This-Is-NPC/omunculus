# omunculus

Omunculus is a local harness that orchestrates tool-using language models.
A project is one `omunculus.toml` and one SQLite store: you send a message,
a run opens, the model calls tools inside a Bubblewrap sandbox until it
ends, every step is recorded as an event, and the store applies what those
tools emit — works handed down to other agents, questions to you, grants.
It runs from the command line or behind an optional HTTP server.

## Install

There is no release and no installer yet. Omunculus runs only from a
checkout of this repository, as its contributors run it; the steps are in
[the design](docs/design.md#8-building-and-checking).

## Start here

[How to start a project](docs/how-to-start-a-project.md) takes an empty
folder to a first message answered, without a network. [The map of the
documentation](docs/README.md) lists every page by the question it answers.

## The big ideas

**A project is a file and a store.** All configuration is the TOML: agents,
models, logins, workflows, workspaces, ceilings. Nothing in the store is
configuration, and nothing the file holds has a default in code.
[The TOML](docs/config.md).

**A send is a cycle of runs.** A message opens a run; what the run's tools
emit asks for more runs, which open concurrently up to `[execution]
max_concurrent`; a command returns when every run it opened has finished.
[The cycle](docs/cycle.md).

**Agents hand work down.** Agents sit at depths. One at depth 0 talks with
you and hands works to the agents below it, or through the stages of a
workflow; a work that breaks goes back up. [Possibilities](docs/possibilities.md).

**A ceiling decides what a run may call.** Each layer — policy, workspace,
depth, stage, agent — narrows the tools a run has; what is left out is
blocked, or asked for through a request. [The ceiling](docs/ceiling.md).

**Questions are requests.** An agent asks a question, or for a permission,
through a request routed by the TOML to another agent or to you; the
answer resumes it. [Requests](docs/requests.md).

**Everything else is a tool.** Searching, filtering, assembling the prompt
and answering requests are tools, folders with a manifest, replaceable by
name. [Tools](docs/tools.md).

**Teams come as packs.** A pack is a folder of agents, workflows, tools and
workspace files, imported at a depth on your models.
[Packs](docs/packs.md).

**Clients use the server contract.** The server serves each project on a
local socket, and on TCP with signed tokens, under a versioned `/v1`
contract. [The server](docs/server.md), [clients](docs/clients.md).

## The interface

The command line is `omunculus <command> [--key value]`; every command is
in [the command line](docs/cli.md).

## What it does not do

- It hosts no model: it calls a provider's API, a program or an Elixir
  module ([the compatible providers](docs/config.md#compatible-providers)).
- The server has no chat page of its own; HTTP clients use its API.
- It does not protect you from your own tools and hooks: it guarantees the
  workflow sequence, the ceiling per stage and the store rules.
- It installs neither Bubblewrap nor the runtimes commands use.
- It does not migrate a store made by an older schema: it refuses to open
  it, and the store must be made again.

## Known limitations

- Linux only, with Bubblewrap: commands run in its namespaces.
- A root in `[execution] runtimes` exposes every binary it holds; it is no
  per-binary allowlist ([the TOML](docs/config.md#required-tables)).
- A project's socket path must fit in 107 bytes, or the server does not
  start ([how to run the server](docs/how-to-run-the-server.md)).
- A provider's rate limits and limits on requests in flight bound how many
  runs can call it at once.

## What is broken

Two defects are known; [what does not work](docs/what-does-not-work.md)
says what to do meanwhile:

1. Some refusals print as Elixir terms, as `send` without `--agent` in a
   project with several agents at depth 0.
2. The codex-like preset's `cursor` model names a program the preset does
   not ship.

Contributors start at [the design](docs/design.md).

## Requirements

- Linux, with Bubblewrap 0.8 or newer (`bwrap`) able to create user, mount,
  PID, IPC, UTS and network namespaces, and `flock`.
- [mise](https://mise.jdx.dev/), which installs the pinned Elixir 1.17,
  OTP 27 and Deno 2.9.
- `git`, only with `[store] changes`, which records the files each model
  call changed.

## License

Omunculus is available under the [MIT License](LICENSE).
