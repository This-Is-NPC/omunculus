# Tools

A tool is a folder. The harness discovers, authorizes, calls, records and
applies. It does not implement `read`, `send`, `assemble` or `prompt`.
Replacing a folder replaces the behaviour. A hook is the same folder with
`hook.toml` and `events = [...]`.

## Contract

Simple, composite, default and third-party: one shape.

```text
in:  { name, args, view, run_id, work_id, workspace, roots }
out: { ok, output, emit }
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

Two contracts, not one:

1. **Model ↔ tool** — the manifest (`description`, `parameters`, tags).
   The harness does not standardise this.
2. **Tool ↔ store** — functions arrive in `in.view`; actions leave in
   `emit`. The harness publishes both.

`triggers` is `model`, `cli`, `harness`, or `cli` and `model` together.
`harness` does not mix with the others. CLI-only stays out of the
assembled prompt; the binary still calls the contract.

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
`inbox.read`, `reply`, `work`, `delegate`, `continue`, `break`,
`compact`, `comment.delete`. Have on a `request` does not open a row —
the output is `already granted: <name>`. Blocked is `deny` and the run
ends. `continue` does not name a stage. `EVENTS` is append-only.

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
sequence  = delegate, continue, break
catalog   = tool_search
cli       = send, inbox, inbox_read, prompt, login, logout
bench     = counter, counter_decrement
prompt    = assemble
```

`directory` and `workspaces` exist as folders and are not in `fs.read`.
`compact_comments` is on disk as a composite tool. `preset` is CLI-only
and `config = false`. A group name in an agent's `tools` list expands to
those names at ceiling mount.
