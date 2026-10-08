# Tools

A tool is a folder. The harness discovers, authorizes, calls, records and
applies. It does not implement `read`, `send`, `assemble` or `prompt`.
Replacing a folder replaces the behaviour. A hook is the same folder with
`hook.toml` and `events = [...]`.

## Contract

Builtin, default and third-party: one contract.

```text
in:  { name, args, view, run_id, work_id, workspace, roots, config_path }
out: { ok, output, emit, chain }
```

`view` holds what the harness read for the call, one entry per
`[views.<key>]` table of the manifest (see [Views](#views)). Without a
declaration, `view` is empty. The tool does not open SQLite.

`output` is what the model (or the CLI) reads from this call. It is not
`PROMPTS.assembled` — that is the `output` of the `assemble` tool after
the harness stored it.

`emit` is a list of store actions. Outside the catalog or outside the
schema, the tool failed and nothing is written.

```json
{
  "ok": true,
  "output": "text for the model",
  "emit": [{ "type": "notify", "body": { "body": "need a look" } }]
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

A tool that works in steps, like `compact_comments` (`load` then
`commit`), takes the step as an argument of its own schema. The harness
sees two calls of the same `name`.

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

## Views

A view is a table of the manifest. Its key is the name the call reads it
under in `view`; `source` says what it reads, `from` where it starts —
a list of anchors, the first one present wins — and the rest are the
options of that source. A view whose anchors are all absent is left out.
A declaration the core does not know refuses the manifest.

```toml
[views.results]
source   = "works"
relation = "children"
state    = ["done", "cancelled", "waiting"]
since    = "last_run"
include  = ["last_comment"]
```

Anchors are the call's own: `work`, `run`, `request`, `inbox`, `prompt`;
`latest_run`, the most recently started run; `args.<name>`, a string
argument of the call.

| Source | Reads | Options |
| --- | --- | --- |
| `works` | the work (`relation = "self"`, the default), its `parent`, or its `children`, oldest first | `from` is `work` (default) or `args.<name>` with `within = "descendants"`, which reads only a work below the call's own; children take `state` (a list) and `since = "last_run"` (changed after the work's last closed run finished); `include` adds `last_comment`, `comments` or the closed `runs` with their record to each work |
| `comments` | the comments of the first of `from` among `work`, `request`, `inbox`, oldest first | `from` (default all three, in that order) |
| `runs` | `relation = "last_closed"`: the work's last closed run; `"opener"`: the run that opened the call's request — each with the message that opened it (`message`) and every event it recorded (`events`) | `relation` (required) |
| `events` | `relation = "run"`: the events of the call's run so far; `"cause"`: the event that made the call's run due | `relation` (required) |
| `requests` | the request named by the `request_id` argument, or the call's request | `from` |
| `prompts` | `relation = "message"`: the prompt that opened the run; `"assembled"`: the assembled prompt of the run named by `from` (default `args.run`, then `latest_run`) | `relation` (required); `from` for `assembled` |
| `inbox` | unread notifications, each with its first comment as `body`: of the project, or of the call's work with `from = ["work"]` | `from` |
| `counter` | the value the `counter` tools keep in `EVENTS` | |
| `catalog` | the cards of the run's effective `model` tools, each marked `pinned` or not | |
| `workspaces` | every configured workspace, its `root` and whether it is the call's | |
| `agents` | the agents a new work may name, below the run's work (depth 0 without one), not `workflow_only`, none when that depth has a workflow | `include = ["tools"]` gives each as `{name, tools}`, with the model tools its own ceiling has at that depth |
| `paths` | the path permissions of the run's ceiling | |
| `grant_scopes` | the scopes a permanent `grant` may name (`agent`, `depth`, `stage`, `workspace`) | |

Every read stays in the call's conversation and goes only through these
relations. The harness computes `catalog`, `workspaces`, `agents`,
`paths` and `grant_scopes` only for a call that declares them. `assemble` renders `agents` under `## Agents` when the run has
the `work` card, each with the tools it has that the run has not.

## Actions

Actions the store will apply: `comment`, `request`, `notify`, `prompt`,
`inbox.read`, `reply`, `grant`, `cancel`, `work`, `delegate`,
`continue`, `break`, `end`, `compact`, `comment.delete`. A `request`
carries a `reason` and `options`, a map from option name to a list of
`{name, args}` tool calls. Options made only of `grant` calls whose
names the run already has do not open a row — the output is
`already granted: <name>`. A granted name that is blocked is `deny`.
`reply` takes `request_id`, `option` and `body`; `grant` takes
`request_id`, `name`, `kind` and an optional `scope`, which only a
person may give; `cancel` takes `request_id` and cancels the request's
work. `end` is the only action that ends the run; it needs a
run. `continue` does not name a stage. `EVENTS` is append-only.

`work` and `delegate` may name the new work's `agent`: it must be one of
the agents the `agents` view lists for that depth, and is refused when
the depth has a workflow. Unnamed, the new work goes to the workflow's
first stage, or to the depth's first agent in name order. A parent that
delegated waits for all its children: a child that closes or is
cancelled reopens it once each of its children is done or cancelled, a
child that breaks reopens it at once.

## Creating works

The model creates works with the `work` tool: a `report` and the `works`
to create, each with a `title`, a `goal`, and optionally an `agent` and a
`workspace`.

- In a run on a work W it chains `comment` with the report on W, one
  `delegate` per item — children of W, one depth below — and `end`.
- In the run `send` opens, which has no work, it takes exactly one item
  and emits the `work` action: the store creates the root work at depth 0
  with the report as its first comment, links the run to it and opens
  the root's run once this run has ended.

`delegate` is only a chain step (`triggers = ["chain"]`), so an agent
with `work` needs `delegate`, `end` and `comment` as have too; the
`sequence` group carries `work`, `delegate` and `end`. The manifest's
`[schemas.staged]` drops `agent` from the items, for the layer whose new
works land on a depth with a workflow:

```toml
[policy.depth.0.overrides.work]
schema = "staged"

[policy.depth.1]
workflow = "delivery"
```

## Handing control away

Every model tool that hands the work to someone else carries a `report`
and ends the run through its manifest's `then = ["end"]`, so the agent
needs `end` as have too.

| Tool | Writes | Then |
| --- | --- | --- |
| `work` | see [Creating works](#creating-works) | `end` |
| `done` | chains `comment` with the report and `continue` | `end` |
| `break` | emits `break`, which parks the work with the report as its comment | `end` |
| `request_access` | emits a `comment` with the report on the run's work, then `request` with the options `grant_agent`, `grant_depth`, `grant_stage`, `grant_workspace`, `deny` and, on a work, `grant` | `end` |
| `request_sandbox` | the same, with `kind = resource` | `end` |

`continue` is only a chain step (`triggers = ["chain"]`): the model
concludes or advances a work with `done`, which needs `comment`,
`continue` and `end` as have. `break` needs no `comment`: the `break`
action writes the report on the work itself. The request tools emit the
comment and the request themselves, so the report precedes the request in
`EVENTS`; in a run without a work they emit only the request. A request
for a name the run already has opens no row and still ends the run.

## Answering a request

`reply` takes a `request_id`, an `option` and a `body`. It reads the
`request` view, emits the `reply` action and chains the option's calls,
each with the request's `request_id` added to its args. The steps run
under the chain rules: the builtin `reply` has
`chains = ["grant", "cancel"]`, the steps are checked against the replying agent's
ceiling (from the command line, against none), and the reply with every
step commits or none does.

| Tool | Emits |
| --- | --- |
| `grant` | `grant`: the name enters the request's work's `WORKS.grants`, or, with a `scope`, the harness rewrites that TOML layer |
| `cancel` | `cancel`: the request's work becomes `cancelled` |

Both are chain-only (`triggers = ["chain"]`). An option with no call,
such as `deny` or the harness's `retry`, only reopens the work, whose
next run opens. A request may list any tool in its options, but the
builtin `reply` only chains those two. To answer with other tools, ship your own `reply` folder with a
wider `chains`; the most specific folder wins.

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
store     = comment, request_access, reply, grant, notify
sandbox   = request_sandbox
sequence  = work, delegate, continue, break, end, done, cancel
catalog   = tool_search
cli       = send, inbox, inbox_read, prompt, login, logout, cursor_login, preset
bench     = counter, counter_decrement
prompt    = assemble
```

`directory` and `workspaces` exist as folders and are not in `fs.read`.
`preset` is CLI-only
and `config = false`. A group name in an agent's `tools` list expands to
those names at ceiling mount.
