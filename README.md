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
  PID, IPC, UTS and network namespaces, and `flock`.
- [mise](https://mise.jdx.dev/), which installs the pinned Elixir 1.17,
  OTP 27 and Deno 2.9.
- `git`, only with `[store] changes`, which records the files each model
  call changed.

## License

Omunculus is available under the [MIT License](LICENSE).
