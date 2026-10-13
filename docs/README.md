# The documentation

Every page, in the order somebody meets it, with the question it answers.

## The pages

| Page | The question it answers |
| --- | --- |
| [The front door](../README.md) | What is omunculus, and how do I install and start it? |
| [How to start a project](how-to-start-a-project.md) | How do I get a project that answers a first message? |
| [How to log in to a provider](how-to-log-in-to-a-provider.md) | How do I put the agents on a real model, with my key? |
| [How to import a pack](how-to-import-a-pack.md) | How do I add a team that comes as a folder? |
| [How to run the server](how-to-run-the-server.md) | How do I serve a project so the apps can reach it? |
| [The screens](screens.md) | What does each screen of the apps show, and which keys does it take? |
| [The console](console.md) | How does the window on a project work? |
| [The mailbox](mailbox.md) | How does the mailbox over every project work? |
| [The studio](studio.md) | How do the project's settings work? |
| [The command line](cli.md) | What does each command take and print? |
| [The TOML](config.md) | What can `omunculus.toml` hold, and what does each key do? |
| [Possibilities](possibilities.md) | What shapes can a project take? |
| [The cycle](cycle.md) | What does a send do to the store, run by run? |
| [The ceiling](ceiling.md) | Who may call what, and how is it granted? |
| [Requests](requests.md) | How are questions and decisions routed, answered and escalated? |
| [Tools](tools.md) | How do I write a tool, and what do the builtin ones do? |
| [Packs](packs.md) | What is a pack, and how do teams work together? |
| [The server](server.md) | What is the `/v1` contract, and how is it served? |
| [Clients](clients.md) | What may a client of the server rely on? |
| [What does not work](what-does-not-work.md) | Which defects are known, and what do I do meanwhile? |
| [The design](design.md) | How is the code laid out, and why? For contributors. |
| [The development environment](development.md) | How do I run the apps on my own dev projects? For contributors. |
| [The comparison](comparison.md) | How does omunculus compare with other harnesses? |
| [Equivalent Exchange](../eval/README.md) | How is the system's behaviour measured? |
| [The capacity benchmark](../bench/README.md) | How many resident runs does one machine hold? |

## The shortest useful path

1. [How to start a project](how-to-start-a-project.md): a first message on
   the `fake` model.
2. [How to log in to a provider](how-to-log-in-to-a-provider.md): the
   agents on a real model.
3. [How to run the server](how-to-run-the-server.md), then
   [the screens](screens.md): the apps on it.

## When you know what you want

| You want to | Read |
| --- | --- |
| look up a command's flags | [the command line](cli.md) |
| look up a key of the file | [the TOML](config.md) |
| give an agent a tool, or take one away | [the ceiling](ceiling.md) |
| make agents go through stages | [the TOML](config.md#agents-policy-workflow), [possibilities](possibilities.md#3-a-named-sequence) |
| write a tool of your own | [tools](tools.md) |
| decide who answers an agent's question | [requests](requests.md) |
| write a client of your own | [clients](clients.md), [the server](server.md) |
| change the core | [the design](design.md) |

## Conventions

- A page answers one question; a task with a page of its own is linked,
  not explained again.
- Outputs are real outputs of the commands shown; a cut is marked `…`.
  What was only read in the code is said to be.
- `<name>` in a command or a path is a placeholder, named as one where it
  first appears.
- `bin/omunculus` is the command from a checkout; `omunculus` names the
  same binary in prose.
- [The command line](cli.md) is written by `mise run docs:cli` from the
  commands themselves; `mise run check` fails when it is stale or when a
  link of these pages does not resolve.
