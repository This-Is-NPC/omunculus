# Tools

A tool is a folder. The harness discovers, authorizes, calls, records and
applies. It does not implement `read`, `send`, `assemble` or `prompt`.
Replacing a folder replaces the behaviour. A hook is the same folder with
`hook.toml` and `events = [...]`.

## Contract

Simple, composite, default and third-party: one shape.

```text
in:  { name, args, view, run_id, work_id, workspace, roots }
out: { ok, output, emit, chain }
```

`view` is the cut of the store the harness already resolved, from the
names the manifest listed (`views = ["comments"]`, or a `load` that
points at a cut). Without a declaration, `view` is empty. The tool does
not open SQLite.

`output` is what the model (or the CLI) reads from this call. It is not
`PROMPTS.assembled` — that is the `output` of the `assemble` tool after
the harness stored it.

`emit` is a list of store actions. Outside the catalog or outside the
schema, the tool failed and nothing is written.

```json
{
  "ok": true,
  "output": "text for the model",
  "emit": [{ "type": "request", "body": { "kind": "tool", "name": "write" } }]
}
```

`chain` is optional: a list of `{ "name": …, "args": { … } }` steps the
tool asks to run right after it, in the same call. See
[Chains](#chains).

Two contracts, not one:

1. **Model ↔ tool** — the manifest (`description`, `parameters`, tags).
   The harness does not standardise this.
2. **Tool ↔ store** — functions arrive in `in.view`; actions leave in
   `emit`. The harness publishes both.

`triggers` lists `model`, `cli` and `chain`, or is `harness` alone. A
tool without `model` stays out of the assembled prompt and out of
`tool_search`; the binary and chains still call the contract. `chain`
lets another tool chain it.

## On disk

```text
tools/read/tool.toml
tools/read/run          # optional; module = "…" is the other way
tools/on-request/hook.toml
```

```toml
name = "read"
kind = "tool"
shape = "simple"
triggers = ["model"]
description = "Reads a file."
tags = ["fs"]
groups = ["fs.read"]
command = ["./run"]

[parameters]
type = "object"
required = ["path"]
```

```toml
name = "on-request"
kind = "hook"
events = ["request"]
command = ["./run"]
```

`parameters` is the schema the model sees by default. `[schemas.<variant>]`
tables declare named alternatives, each a whole schema like `parameters`:

```toml
[schemas.short]
type = "object"
required = []
```

A layer of the TOML picks one with `overrides.<tool>.schema`
([Overrides](config.md#overrides)); the run then serves that variant as
the tool's `parameters`. The store rules on the arguments stay the same
whichever schema the model saw.

`run` reads JSON on stdin and prints JSON on stdout, in any language.
The next run that walks `[tools] paths` sees the folder. Builtin tools
may be an Elixir `module` returning the same `out`.

`shape` is `simple` (one call) or `composite` (`load` then `commit`, as
the tool's own schema defines). The harness sees two calls of the same
`name`.

Copy the folder into a path listed in `[tools] paths`. Inline
`[tools.<name>]` in the TOML is the same keys without a folder. MCP
servers contribute names after `paths` and before inline; the last `name`
wins. A name the ceiling listed that nobody exposed is blocked.

## Chains

A tool may ask that other tools run right after it, within the same call.
The steps are its `out.chain` followed by its manifest's `then`, each
`then` name run with empty args:

```toml
name = "done"
chains = ["comment", "continue", "end"]
then = ["end"]
```

`chains` lists the names the tool may chain. Every `then` name is in
`chains`, and `end`, when present, is the last of `then`; otherwise the
manifest does not load. A layer of the TOML may replace `then` or
restrict `chains` with `overrides.<tool>` ([Overrides](config.md#overrides));
the chain runs with the resolved values of its run.

Each step goes through the same contract as a call: the views its own
manifest declares, its `emit`, its `EVENTS(tool)` with `via` = the name
of the tool that chained it. A step's own `chain` and `then` run right
after it, under its own `chains`. The whole chain is refused when a step:

- is not in the `chains` of the tool that chained it;
- does not have `chain` in its `triggers`;
- is not have in the run's ceiling, when the chain runs in a run;
- is already on the path of tools that led to it;
- comes after `end`;
- fails.

The emits of the tool and of every step are applied in one transaction.
A refused chain writes none of them: the called tool is recorded as a
failed `EVENTS(tool)` whose `output` says which step failed and why. An
emit the store rejects writes nothing at all. Hooks react to the step
events like to any event, after the chain commits.

## Views and actions

Views the store will hydrate:

| View | Cut | Alias |
| --- | --- | --- |
| `comments.work` | comments of that work | `comments`, when the run is on a work |
| `comments.request` | of that request | `comments`, on a request |
| `comments.inbox` | of that inbox | `comments`, on an inbox |
| `events.run` | events of that run | `events` |
| `work` | that work row | |
| `runs.last` | the most recent run | CLI `prompt` |

Qualified names are canonical. A manifest copied from the spec with
`views = ["comments"]` still loads.

Actions the store will apply: `comment`, `request`, `notify`, `prompt`,
`inbox.read`, `reply`, `work`, `delegate`, `continue`, `break`, `end`,
`compact`, `comment.delete`. Have on a `request` does not open a row —
the output is `already granted: <name>`. Blocked is `deny`. `end` is the
only action that ends the run; it needs a run. `continue` does not name a
stage. `EVENTS` is append-only.

## What the model calls

The assembled prompt names the cards and says the tools are in
`tools.*`. The coordinator is the process `[execution.sandbox]`
described. Each `await tools.<name>(args)` is one trip through the
contract. `tool_search` returns cards; the code then calls the `name` it
wants. Schema and heavy data come back as `output` of a `load`, not as
description text.

The coordinator itself cannot read the workspace, open a network, see
the host environment or spawn a process. Those are tools, classified by
the ceiling, run in their own sandboxed sessions.

## Groups the default package uses

```text
fs.read   = read, ls, grep, find
fs.write  = write, edit
store     = comment, work, request_access, reply, notify
sandbox   = request_sandbox
sequence  = delegate, continue, break, end, done
catalog   = tool_search
cli       = send, inbox, inbox_read, prompt, login, logout
bench     = counter, counter_decrement
prompt    = assemble
```

`directory` and `workspaces` exist as folders and are not in `fs.read`.
`compact_comments` is on disk as a composite tool. `preset` is CLI-only
and `config = false`. A group name in an agent's `tools` list expands to
those names at ceiling mount.
