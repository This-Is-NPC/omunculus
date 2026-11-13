# Tools

A tool is a folder. The harness discovers, authorizes, calls, records and
applies. It does not implement `read`, `send`, `assemble` or `prompt`.
Replacing a folder replaces the behaviour. A hook is the same folder with
`hook.toml` and `events = [...]`.

## Contract

Builtin, default and third-party: one contract.

```text
in:  { name, args, view, run_id, work_id, workspace, roots, config_path }
out: { ok, output, emit, media, chain, instructions }
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

`media` is optional: images and PDFs to show the model with `output`
([Media](#media)).

`instructions` is optional: what the `assemble` tool puts before its
`output`, the part of a prompt that stays the same from run to run.

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

A `command` tool may set `keep_alive_ms`, a positive integer. The harness
then keeps its process between the calls of one run, so the tool holds
state the process needs, such as a language server. The contract changes
only in its framing: each call is one line of JSON on stdin, the `in`, and
the tool answers with one line of JSON on stdout, the `out`, until stdin
closes. The process is started under the run's policy by the first call and
ends after `keep_alive_ms` without a call, when the process that first
called it (the run's) ends, when a call fails or times out, or when it
exits; the next call starts it again. One run never reaches the
process of another. A call outside a run, or a tool without the key, gets
a process per call, which reads the same line until stdin closes. The
process holds no `max_concurrent` slot, so it never starves the run's own
calls; `[execution] max_resident` bounds the resident processes across the
project when set, and without it they are not counted. A call that runs past the policy's `timeout_ms` has what runs below
the process killed; a process that then answers within a second is kept
and the call fails, one that does not is stopped.

A tool only the CLI triggers (`triggers = ["cli"]`) may set
`config = false`; any other tool that sets it is refused. The command line
looks such a tool up among the package's own tools, before any config is
read, and runs it without a config file or a store, as `preset`, which
writes the file.

`run` reads JSON on stdin and prints JSON on stdout, in any language.
The next run that walks `[tools] paths` sees the folder. Builtin tools
may be an Elixir `module` returning the same `out`.

Inside the sandbox a tool's command reads, read-only, the whole folder of
`[tools] paths` its own folder was found in (a pack's `tools/`), so the
tools of one path may share what lies beside them: a folder without a
`tool.toml`, such as the dream team's `tools/_deploy`, which the
`run` of each deploy tool runs as `$(dirname "$0")/../_deploy/deploy <operation>`
and which holds the providers it chooses from.
Nothing outside that folder comes with it.

A `command` tool that authenticates declares the secrets its process
needs, by the name of a variable:

```toml
secrets = ["GH_TOKEN"]
```

The config binds each to an `[auth]` provider in `[secrets.<tool>]`
([Tool secrets](config.md#tool-secrets)). Before the process starts the
harness resolves the value and the sandbox hands it to that process alone,
as the read-only file `/run/secrets/GH_TOKEN`, which `GH_TOKEN_FILE`
names; a tool whose program wants a variable reads the file in its own
`run` script (`GH_TOKEN=$(cat "$GH_TOKEN_FILE") exec gh …`). The value is
masked as `***` in what the call returns, its emits and its errors before
anything is recorded, so the model never reads it. A module tool runs
inside the harness and declares none.

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
- is not among the tools the run has (`have` in its ceiling), when the chain runs in a run;
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
| `works` | the work (`relation = "self"`, the default), its `parent`, or its `children`, oldest first; `"conversation"`, from `run`: for a run without a work, the root works of its conversation, oldest first | `from` is `work` (default) or `args.<name>` with `within = "descendants"`, which reads only a work below the call's own; children take `state` (a list) and `since = "last_run"` (changed after the work's last closed run finished); `include` adds `last_comment`, `comments` or the closed `runs` with their record to each work |
| `comments` | the comments of the first of `from` among `work`, `request`, `inbox`, oldest first | `from` (default all three, in that order) |
| `runs` | `relation = "last_closed"`: the work's last closed run; `"opener"`: the run that opened the call's request — each with the message that opened it (`message`) and every event it recorded (`events`); `"conversation"`, from `run`: for a run without a work, the closed runs of its conversation that had none, oldest first, each with its record; `"recent"`: the project's last `limit` closed runs, of every conversation, newest first, each with its work's `work_title`, `work_state`, `work_workflow` and `work_stage` and its `events` | `relation` (required); `limit` (required for `recent`, a positive integer) |
| `events` | `relation = "run"`: the events of the call's run so far; `"cause"`: the event that made the call's run due; `"attachments"`: the files attached in the run's conversation, oldest first, each `{name, media_type, bytes, sha256}` with its `event_id`, `at` and `by` | `relation` (required) |
| `requests` | the request named by the `request_id` argument, or the call's request; `relation = "answered"`, from `run`: the closed requests the run's agent raised in its conversation but for the one that opened the run, oldest first, each with its `answer` (the option picked) and its `reply` | `from`; `relation` |
| `prompts` | `relation = "message"`: the prompt that opened the run; `"assembled"`: the assembled prompt of the run named by `from` (default `args.run`, then `latest_run`) | `relation` (required); `from` for `assembled` |
| `inbox` | unread notifications (default), or pending canonical requests received by the current depth-0 agent in its conversation, grouped by conversation | `relation = "unread"` with optional `from = ["work"]`; `relation = "received"` from `run` |
| `artifacts` | the artifact versions of the run's conversation, oldest first, each as its event describes it with `event_id`, `at`, `by` and `tool`, the tool that wrote it | `prefix` keeps the names that begin with it; `include = ["data"]` adds `data`, the decoded content of the latest version of each name when it is `application/json` |
| `memories` | the memory entries the run sees, oldest first: the project's, its agent's and its workspace's ([memory](#memory)) | from `run` |
| `catalog` | the cards of the run's effective `model` tools, each with its `parameters` and marked `pinned` (declared) or not | |
| `workspaces` | every configured workspace, its `root` and whether it is the call's | |
| `agents` | the agents and workflows a new work may name, one depth below the run (1 when the run has no work). The run's depth is the work's place in the tree, or its assignee's depth when that is deeper. Listed: the agents not `workflow_only`, none when that depth requires workflows, and each workflow as `{workflow, stages, required}` | `include = ["tools"]` gives each agent as `{name, tools}`, with the model tools its own ceiling has at that depth |
| `paths` | the path permissions of the run's ceiling | |
| `settings` | the `[settings.<key>]` table of the config, `<key>` being the view's own key; empty without one ([Settings](config.md#settings)) | |
| `grant_scopes` | the scopes a permanent `grant` may name (`agent`, `depth`, `stage`, `workspace`) | |
| `skills` | the Agent Skills the run's ceiling has, each its `name`, `description` and `dir` | |

Every read stays in the call's conversation and goes only through these
relations, but for the project's unread inbox and its recent runs. The harness computes `catalog`, `workspaces`, `agents`,
`paths`, `settings`, `grant_scopes` and `skills` only for a call that declares them. `assemble` renders `agents` under `## Agents` when the run has
the `work` card, each with the tools it has that the run has not, and
`skills` under `## Skills`, a line `name: description` each.

## Skills

A skill ([Skills](config.md#skills)) reaches the model in two steps. The
assembled prompt names each skill the run has, with its description,
under `## Skills`. The `skill` tool gives one: with `name`, its
`SKILL.md` and the files of its folder; with `file` too, that file of
the folder, read through links and refused when it leads outside. Both
`skill` and every skill are in the group `skills`, so an agent that
lists `skills` has the tool and all of them; one that lists
`skill.<name>` has that skill alone, and needs `skill` to read it. The
tool reads in the harness's process, since a skill's folder is outside
the sandbox; the scripts a skill ships are not run.

## Memory

Memory keeps what an agent learned beyond the conversation: a lesson or a
fact for later conversations ([the model](design.md#11-memory)). It is not
a skill. A skill is a procedure someone wrote down, read as it is; memory
is what agents found out, kept as short entries. The three tools are in the
group `memory`, and none is in a default layer.

An entry has a `scope`, a `kind`, a `text` and its source.

| Field | Values |
|---|---|
| `scope` | `project`, for every run; `agent`, for runs of the agent that remembered it; `workspace`, for runs on works in the workspace it was made in |
| `kind` | `fact`, `preference`, `procedure` or `pitfall` |
| source | the conversation, work and run that taught it, who wrote it and when, recorded by the store |

| Tool | Does |
|---|---|
| `remember` | Keeps `text` under a `scope` and `kind`. The same text in that scope and kind, compared without case, is not kept twice: the output names the entry that stands. A scope the run has no key for (`workspace` on a run without a work in a workspace) is refused. |
| `recall` | Lists the entries the run sees, each with its id, scope, kind, text and source. `query` matches its words in the text: entries matching more words come first, the newer first among equals, and an entry matching none is left out. Without `query`, the newest. `scope` and `kind` narrow, `limit` caps the list (10 when omitted). |
| `forget` | Ends the entry `id` that `recall` shows. The run must see it. To change an entry, forget it and remember the new text. |

Entries are `memory` events, so they are kept with the store and cannot be
edited. With [`[policy] memory_bytes`](config.md#required-tables), `assemble`
puts the newest entries that fit under `## Memory` in the context, after
the instructions, which stay the same from run to run; without it the
prompt holds none and an agent calls `recall`.

## Attachments

With `[store] attachments` ([config](config.md)), a conversation keeps
files: those a message carries ([server](server.md)) and those a run
attaches. `assemble` lists them under `## Attachments`, each with its
name, media type, size, who attached it and its `sha256`.
`read_attachment` reads one by its `sha256`, refused when the file is not
attached in the run's conversation; an image or a PDF is shown to the
model ([Media](#media)), another file that is not text is refused with its
size. `attach` keeps a file
under the run's roots, read through the same checks as `read`, with the
media type its name suggests and an optional `note`; the conversation
keeps it as it was then, whatever the workspace does after. Or it hands
over an artifact by reference: `artifact` names it and `version` the
number, the latest when omitted; the person receives exactly that
version, with the note `<name> version <n>` unless one is given, and under
the file name `name` gives when it does (the artifact's own otherwise; the
artifact keeps its key). It takes
`path` or `artifact`, never both.

## Artifacts

An artifact is a named, typed, versioned document of a conversation
([the model](design.md#10-artifacts)). It needs `[store] attachments`, as
an attachment does. A version is never changed: a change is the next one,
numbered by the store. A name keeps its kind, a lowercase word the pack
chooses (`proposal`, `brief`, `design`, `handoff`, `preview`); the core
keeps no list.

| Tool | Does |
| --- | --- |
| `put_artifact` | Writes the next version. `name` (a file name without a directory) and `kind`, then `data`, a JSON object kept as `application/json`, `content` text with its `media_type`, or `base64` bytes with its `media_type` (an image, a PDF); an optional `note`; an optional `base`, the number of the version it builds on (0 for none), which refuses the write when another version came since. Content equal to the latest version's (same SHA-256 and media type) makes no new version: the call succeeds and the output names the version that stands. A kind, name, size or `base` the store would refuse fails the call. The output names the version. |
| `get_artifact` | Reads a version: `name`, and `version`, the latest when omitted. An image or a PDF is shown to the model ([Media](#media)); another version that is not text is refused with its size. |
| `list_artifacts` | Lists each artifact with its kind and versions, newest last; `kind` keeps those of one kind. |
| `attach` | With `artifact`, gives the person that version ([attachments](#attachments)). |

The first three are the group `artifacts`. `attach` is in none, so an
agent that lists the group cannot give the person anything: its ceiling
decides which agents may. `assemble` does not list
artifacts: an agent reads them with `list_artifacts`.

A version is not an attachment. Until an agent attaches it, the person's
conversation does not show it, and the operator lists every version
through the server ([server](server.md#artifacts)). A tool that makes
documents, such as a pack's, emits the `artifact` action: `name`, `kind`,
`media_type`, `content` and an optional `note`. The store keeps the
content, numbers the version and records an `artifact` event, unless the content
equals the latest version's (same SHA-256 and media type), which then
stands and records nothing; it refuses a
kind that differs from the name's and a
content past `[store] attachment_bytes`, and a `base` (an integer, 0 for
none) that is not the number of the name's latest version. Runs the CLI
starts without `[access]` have no conversation and share one set of
artifacts. The event
records the `tool` that emitted it, which a pack's gate may check to
accept only what its own tool wrote. A tool that needs a version's data
declares `[views.artifacts]` with `include = ["data"]`, and a `prefix`
to read fewer names.

`attach` hands over any version the agent names; the core does not tell a
document for the person from data for the agents, since kinds are the
pack's. A pack that keeps internal data in an artifact renders a document
of its own for the person, as the sales desk does, and tells its agents
to attach that.

## Artifacts in a bucket

Two tools copy artifacts to and from the S3-compatible bucket `[settings.s3]` names
([the TOML](config.md#artifacts-in-a-bucket)). They are in no group: the
ceiling decides which agents have them.

| Tool | Does |
| --- | --- |
| `push_artifacts` | Uploads every version of this conversation's artifacts (`name` keeps one artifact). Each content is the object `<prefix>/objects/<sha256>`, and each version a record `<prefix>/conversations/<conversation>/<name>/<version>.json`, the version as its event describes it. What the bucket already holds is skipped, so the call may be repeated. A `chain` step too. |
| `pull_artifacts` | Restores the versions the bucket holds for a conversation (`conversation`, this one when omitted) that this conversation lacks, as `artifact` actions in order, each checked against its SHA-256. A name restores only the versions after the ones it has, so a repeat restores nothing more. Text and bytes come back as they were; a version that follows a gap in the numbers is left out and named. |

Both fail, writing nothing, when there is no `[settings.s3]` table or a key of it is not valid, a credential does
not resolve or the bucket refuses. A sync that follows every write is a
hook on `artifact` that chains `push_artifacts`:

```toml
name = "on-artifact"
kind = "hook"
events = ["artifact"]
module = "Omunculus.Hooks.Noop"
chains = ["push_artifacts"]
then = ["push_artifacts"]
```

It runs in the harness, outside the sandbox, as `omapass` and a `!` key do:
no secret reaches a process of the run. The core knows neither the bucket
nor the tools; the store keeps the record of what each call did.

## Actions

Actions the store will apply: `comment`, `request`, `notify`, `prompt`,
`attach`, `artifact`, `memory`, `inbox.read`, `escalate`, `reply`, `grant`, `cancel`, `work`, `delegate`,
`continue`, `break`, `wait`, `reopen`, `retire`, `end`, `compact`, `comment.delete`, and `hold`, which the
harness writes to open the review of a tool call an
[interceptor](requests.md#interception) holds and a tool's own emit does not
need. A `request`
carries a `reason` and `options`, a map from option name to a list of
`{name, args}` tool calls. Options made only of `grant` calls whose
names the run already has do not open a row — the output is
`already granted: <name>`. A granted name that is blocked is `deny`.
In an agent's run opened by the answer to its own request, a `request` or
`escalate` with that request's reason, whitespace aside, is refused
(`asked_again`): the answer stands. `escalate` takes `reason` and `origins`,
a map of distinct part names to received request IDs. It creates a linked request without overwriting a
parent's child wait. `reply` takes `request_id`, `body`, optional `option`
and recursive named `parts`; `grant` takes
`request_id`, `name`, `kind` and an optional `scope`, which only a
person may give; `cancel` takes `request_id` and cancels the request's
work; `retire` takes `work_id` and `body` and cancels a work below the
run's own that broke, with the body as its comment, in a `cancel` event
(see [A work below that broke](#a-work-below-that-broke)). `end` is the only action that ends the run; it needs a
run. On a work's own run (no named agent) the store refuses `end` while,
after the call's other actions, the work is still open and nothing will
run it again: no request of the work pending, no run of it due since the
run began (a next stage, a message, a child back that woke it). The
refusal tells the model to hand the work on — `done`, `ask`, `work` or
`break`, and on a root work `wait` — and, when a child that broke waits on the run, to reopen it or
break first. A run without a work, a named agent's run, and a call whose
other actions leave the work waiting, done or cancelled end freely.
`wait` takes `body` and parks a root work, one no other work handed
down, until its person's next message reopens it (`waiting = message`),
with the body as its comment; it is refused on a work below another
(`not_root`), on a work not open, and while a child that broke waits on
it. `continue` does not name a stage. While a child that broke waits on the
work, the store refuses `continue`, `delegate` and `end` alike, with one
refusal telling the model to reopen the child, retire it or break the work: `done`,
or a tool that moves the work to its next stage, cannot close or hand on
a work and leave the broken child parked for good. `prompt` and `attach` take
`attachments`, each `{name, media_type, bytes, sha256}` checked against
the file `Omunculus.Attachments` keeps; `attach` needs a run. `EVENTS` is append-only.

`work` and `delegate` may name the new work's `agent` or its `workflow`,
not both, each one the `agents` view lists for that depth. Where the
depth requires workflows an agent is refused, and an unnamed work goes
through the only one, or is refused when there are several. Elsewhere an
unnamed work goes to the depth's only agent, and is refused when it has
several. A work named into a workflow starts at its first stage and goes
through its stages. A parent that
delegated waits for all its children: a child that closes or is
cancelled reopens it once each of its children is done or cancelled, a
child that breaks reopens it at once.

## Creating works

The model creates works with the `work` tool: a `report` (as every ending tool takes it) and the `works`
to create, each with a `title`, a `goal`, and optionally an `agent` or a
`workflow`, and a `workspace`.

- In a run on a work W it chains `comment` with the report on W, one
  `delegate` per item — children of W, one depth below the run, which is
  the work's place in the tree or its assignee's depth when that is
  deeper — and `end`.
- In the run `send` opens, which has no work, it takes exactly one item
  and emits the `work` action: the store creates the root work at depth 0
  with the report as its first comment, links the run to it and opens
  the root's run once this run has ended. Where depth 0 requires no
  workflow and depth 1 requires one, a run without `delegate` opens that
  workflow as the root; naming an agent is refused.

`delegate` is only a chain step (`triggers = ["chain"]`), so an agent
with `work` needs `delegate`, `end` and `comment` as have too, but for
one that never holds a work — at a depth that requires workflows, on none
of their stages, or at a free depth whose depth below requires a workflow
it does not delegate — whose `work` runs `end` alone; the
`sequence` group carries `work`, `delegate` and `end`. The manifest's
`[schemas.staged]` drops `agent` and `workflow` from the items, leaving
each its title, goal and workspace, for the layer whose new
works land on a depth that requires one workflow:

```toml
[policy.depth.0.overrides.work]
schema = "staged"

[policy.depth.1]
workflows = ["delivery"]
```

## Workspaces of projects

`project` tells an existing project from a new one. `list` prints the
workspaces as JSON, each with its `name`, `path` and the `client` and
`summary` of its table. `create` takes a `name` (lowercase letters,
digits, `-` and `_`) and optionally a `client` and a `summary`: it makes
the folder `<[project] workspaces_dir>/<name>`, runs `git init` there and
writes `[workspaces.<name>]` with the same write `configure` makes
([config](config.md#workspaces)). It is refused without `workspaces_dir`,
for a name already a workspace or a folder, and when the config would not
load with the new workspace; then nothing is left behind. Every run reads
the config again, so the next run sees the workspace. The agent binds
work to it by naming it as the `workspace` of the work it opens with
`work` ([Creating works](#creating-works)), or of a `delegate`.
`project` is in no group: list it in an agent's tools.

## Handing control away

Every model tool that hands the work to someone else carries a `report`
(one shape, [the report](cycle.md#the-report)) and ends the run through
its manifest's `then = ["end"]`, so the agent needs `end` as have too.
`retire` takes its report as plain text. A command tool, pack tools such as
`deliver`, `next_stage` and `wait_client` included, takes it the same way
with `report = {"$ref" = "report"}` and the view `report_required`: the
harness checks the object and renders it before the process runs, so
`args.report` is the text of the comment.

| Tool | Writes | Then |
| --- | --- | --- |
| `work` | see [Creating works](#creating-works) | `end` |
| `done` | chains `comment` with the report and `continue` | `end` |
| `break` | emits `break`, which parks the work with the report as its comment | `end` |
| `wait` | emits `wait`, which parks a root work with the report as its comment until the person's next message | `end` |
| `request_access` | emits a `comment` with the report on the run's work, then `request` with the options `grant_agent`, `grant_depth`, `grant_stage`, `grant_workspace`, `deny` and, on a work, `grant` | `end` |

`continue` is only a chain step (`triggers = ["chain"]`): the model
concludes or advances a work with `done`, which needs `comment`,
`continue` and `end` as have. `break` and `wait` need no `comment`: their
actions write the report on the work themselves. The request tools emit the
comment and the request themselves, so the report precedes the request in
`EVENTS`; in a run without a work they emit only the request. A request
for a name the run already has opens no row and still ends the run.

## Reading a work below

`read_work` takes a `work_id`. Its `target` view reaches only a work
below the run's own; any other id refuses the call. It returns the work's
title, agent, state, stage and goal, every comment on it, and the record
of each of its closed runs as `## Last run` shows one, without the call
that assembled each run's prompt. `## Children` and `## Results` name
each child's work id.

## Merging a work below

`merge` takes a `work_id`: a done work handed down from the run's own
that worked in a git worktree ([config](config.md#a-worktree-per-work)).
It merges the branch `work/<work_id>` into the run's root with a merge
commit: the run's worktree when its own work is isolated too, else the
workspace's checkout. The root must be writable in the run (`sandbox.write`).
When the merge conflicts, `merge` undoes it, so nothing merges, and the
call fails naming the conflicting paths. Other refusals (a work that is
not done, or not below the run's, or a root git cannot merge into, such
as one with uncommitted changes the merge would overwrite) fail the call
with the reason. Like every tool, it reaches an agent only through the
ceiling; no preset includes it.

## A work below that broke

A child that broke waits on its parent's run, which decides it with one
of three model tools. `reopen` takes `work_id`, `instructions` and
optionally `agent`, `stage` and `grant`: the work goes back to its agent,
another of its depth, or, in a workflow, the agent of a stage up to its
own, with the instructions as its comment; the parent waits on its
children again and the run ends. `retire` takes `work_id` and a `report`:
the work is cancelled with the report as its comment and the run goes
on — the parent, free of the broken work, may hand out what must come
first and a new work after it, or waits on its other children when some
are not back. `break` passes the parent's own work up. With `[policy]
max_reopens`, a `reopen` past the limit opens a request instead, to
whoever gave the parent its work, its reason the `past_limit` text the tool wrote,
and the parent waits on the answer ([the cycle](cycle.md#work)). Only a work that
broke can be reopened or retired: a work that is done stays done, and
what it did is changed by a new work. Either refuses any other work with
`not_broken` or `not_a_child`.

## Answering a request

`reply` takes `request_id`, a nonempty `body`, optional `option` and
recursive `parts`. It reads the canonical `request` view, including named
`origins`, emits the `reply` action and chains the chosen options' calls,
each with the request's `request_id` added to its args, using the origin ID for a named part. The steps run
under the chain rules: the builtin `reply` has
`chains = ["grant", "cancel", "configure", "pack"]`, the steps are checked against the replying agent's
ceiling (from the command line, against none), and the reply with every
step commits or none does.

| Tool | Emits |
| --- | --- |
| `grant` | `grant`: the name enters the request's work's `WORKS.grants`, or, with a `scope`, the harness rewrites that TOML layer |
| `cancel` | `cancel`: the request's work becomes `cancelled` |

Both are chain-only (`triggers = ["chain"]`). An option with no call,
such as `deny` or the harness's `retry`, only reopens the work, whose
next run opens. A request may list any tool in its options, but the
builtin `reply` only chains the four tools listed above. To answer with other tools, ship your own `reply` folder with a
wider `chains`; the most specific folder wins.

Text alone chains nothing and grants nothing. A named decision requires its
option; saying "approved" does not select `approve`. Parts are keyed by the
escalated request's origin names and contain `body`, optional `option` and
nested `parts`. Validation and authorization apply recursively; an invalid
part refuses the entire reply. Omitted parts return to pending.

The model-only `escalate` tool emits the common action and chains `end`. Its
origins must be pending, addressed to the caller and in one conversation.
The new request keeps immutable origin links and original effect targets.
Its reply either answers named origins transactionally or resumes the
intermediary for distribution, including while its work waits on children.

## What the model calls

The assembled prompt names the cards and says the tools are in
`tools.*`. The coordinator is the process `[execution.sandbox]`
described. Each `await tools.<name>(args)` is one trip through the
contract. `tool_search` returns cards; the code then calls the `name` it
wants, among the tools it was declared. Schema and heavy data come back as `output` of a `load`, not as
description text.

The coordinator itself cannot read the workspace, open a network, see
the host environment or spawn a process. Those are tools, classified by
the ceiling, run in their own sandboxed sessions.

## On-demand schemas

A schema is the biggest part of a tool for the model. With `tool_search`
effective and a `pinned` that leaves some tools out
([the ceiling](ceiling.md)), a run is declared only the schemas of the
`pinned` tools and of `tool_search`; `Ceiling.declared/2` is the one place
that decides it, for the adapters' `tools` and for the cards.

`tool_search` lists the cards of the run's effective `model` tools that
match `q` and `tags`. `q` is split into words, and a card matches when every
word is found, in any case, in its name, its description or one of its tags.
Each one the run was not declared gets, on the line
after its card, `schema <name>: <JSON schema>`. From that call on, the run
may call it; before, the call is refused (`has no schema in this run yet`).
A tool outside the ceiling is not in the catalog the search reads, so it is
never found, and a call to it is refused as not the run's. Whether a project
works this way is its TOML: without `pinned`, or without `tool_search` in the
effective set, every schema is declared and nothing changes.

The schema comes back as a tool result, after the stable prefix, instead of
growing the `tools` array. All three adapter protocols cache a prefix that
starts with the tools: Anthropic Messages caches tools, then `system`, then the
messages up to a `cache_control` block; OpenAI Chat Completions and Responses
cache the longest identical prefix (`prompt_cache_key` routes it), and the
tools come first in it. A tool added to the array mid-run changes the first
bytes and drops the cache of the instructions and of every message after it;
a tool result only extends the end. The cost is that the model calls a tool
its `tools` array does not list; the name and schema are in the result it
just read.

A model that finds a tool this way may send an argument as text, having no
schema in its `tools` array: JSON text for an object or array, "8080" for an
integer or number, "true" for a boolean. The harness converts it when the
tool's schema types the argument so; anything ambiguous stays for the tool
to refuse.

Limits: a `command` model and `code_mode` bind only the declared tools, so
they cannot call one found later. With `send_catalog`, a run is sent the
declared tools only. A search with no `q` returns every schema of the
catalog, cut to `[policy] tool_output_bytes`.

## Media

A model sees images and PDFs, not only text. A tool's `out` may carry
`media`, a list of parts, each a `media_type` and where the bytes are:

| Field | Bytes |
| --- | --- |
| `data` | base64, in the part |
| `sha256` | a file kept in `[store] attachments` |
| `path` | a file under the run's roots, read through the same checks as `read` |

A part may also have a `name`. Exactly one of `data`, `sha256` and `path`
is given.

`read` of an image or a PDF, `read_attachment`, `get_artifact` of a
binary version and `browser_check` return parts. A command tool does the
same by printing `media` in its `out`. The supported types are
`image/png`, `image/jpeg`, `image/gif`, `image/webp` and
`application/pdf`; `read` and its kin tell them by their first bytes.

The harness keeps each part's bytes once in `[store] attachments`, under
their SHA-256, within `[policy] media_bytes` and `[store] attachment_bytes`
([config](config.md)). The recorded call holds a reference, `name`,
`media_type`, `bytes` and `sha256`, not the bytes: the store already keeps
them, so the log does not carry them again. A part the harness cannot keep
is left out, and the call's `output` says why: no `media_bytes`, no
`[store] attachments`, too large, a path outside the roots, or bytes that
cannot be read.

Each adapter turns the same part into its provider's content:
`anthropic-messages` into `image` and `document` blocks in the
`tool_result`; `openai-responses` into `input_image` and `input_file`
items in the `function_call_output`; `openai-completions` into
`image_url` and `file` parts of a user message after the tool messages,
because a tool message holds text alone. A model's `media_types` in
`[models.<name>]` ([config](config.md#the-adapters)) lists what it takes;
a part of another type is not sent, and the result says which types the
model takes. Under `code_mode` a call returns text, with the count of the
media it did not show.

A session that continues ([config](config.md)) does not send the media of
earlier runs again: the output of that call says it was shown.

## Editing files

`write` replaces a file whole. `edit` takes a `path` and a list of
`{old, new}` spans: each `old` must appear once in the file as it was
before the call, apart from the others; otherwise nothing is written and
the error names the failing item (`edits[2]: old text not found`).
`patch` takes one `patch` string of files in a small format, written whole
or not at all:

```text
*** Begin Patch
*** Add File: notes.md
+first line
*** Update File: src/app.ex
@@
 context line
-old line
+new line
*** Delete File: old.txt
*** End Patch
```

A hunk is matched as the lines it keeps and removes, once in the file and
apart from the other hunks, with the matching of `edit` (`hunk[1]: old
text not found`, prefixed with the file). It needs at least one such line.
An added file must not exist. A failed write puts back the files already
written. Each path follows the sandbox and workspace rules, and `edit` and
`patch` refuse a file that changed since the run last read it. The files
each call changed are recorded for `changes` and `revert` like those of
`write`.

After they write, `write`, `edit` and `patch` format each file they wrote
(not one `patch` deleted) with the command `[settings.format]` gives for its
extension ([Settings](config.md#formatting-after-a-write)). The command runs in the
workspace root, inside the run's sandbox, under the run's policy, so it can
write only where the run can. Without the table, or without the file's
extension in it, nothing runs. The call's output says in words when the
formatter changed the file, so the model reads it again before it edits it,
and when the formatter failed (its exit status and what it printed, cut to
`[execution] max_output_bytes`); the file stays as it was written, and the
call still succeeds. The files formatting changed are recorded by `changes`
like the rest.

## Shell

`bash` (shipped by the `codex-like` preset) runs a command as an `sh`
script in the run's shell: one `sh` in the run's sandbox, started by the
first call and kept by the same mechanism as `keep_alive_ms`
([Tools](#tools)), with no idle end: it lives until the run's process
ends. The calls of a run share the shell's directory, variables, functions
and background jobs, and the sandbox is built once. A call may name a
`workdir`, relative to the workspace root, to change to first. Its stdin is
closed. Stdout and stderr come back together, in the order written, up to
`[execution] max_output_bytes`; the rest is cut and the output says so.

A call takes `timeout_ms`, `[execution] timeout_ms` without one. A longer
one than `max_timeout_ms` of `[settings.bash]` is refused with that limit;
without the key the limit is `[execution] timeout_ms`. A command that runs
past its timeout is killed with whatever it started, and the output says
so; the shell stays open, in the directory and with the variables the
command left. A shell that does not answer after the kill, such as one in
a loop of builtins, is killed too, and the output says the next call
starts a new shell with its state reset. `exit` in a command ends the
shell the same way. With `[execution] host`, the shell keeps what it
writes under the person's home apart from the run's other commands, which
share theirs, so neither waits for the other's overlay.

## Code intelligence

`lsp` asks the language server declared for a file's extension
([Settings](config.md#settings)). It is not in a group: name it in an
agent's `tools`. `path` is relative to the workspace root; `line` and
`column` count from 1.

| `action` | Needs | Answers |
| --- | --- | --- |
| `diagnostics` | `path` | `path:line:col severity [source code] message`, one per line, or `no diagnostics` |
| `definition` | `path`, `line`, `column` | `path:line:col  <source line>` of each definition |
| `references` | `path`, `line`, `column` | the same, for each use and the declaration |
| `hover` | `path`, `line`, `column` | the type or documentation the server gives, cut at 2000 characters |
| `symbols` | `path` | `kind name line:col`, indented by nesting |

A list is cut at 100 lines (`(+N more)`). The tool sends the file as it is
on disk before each call, so an edit is seen by the next one; after an
edit, `diagnostics` shows what broke. It waits up to 15 seconds for the
server to publish diagnostics of a file it has just been told about, and
a request unanswered for 30 seconds fails the call.

The tool is a `command` tool with `keep_alive_ms = 120000`: the language
server starts inside the run's sandbox, in the workspace root, on the
first call, is initialised once, and lives with the tool's process
([On disk](#on-disk)), until two minutes pass without a call. A server
takes seconds to start and index, and a run uses it in bursts; two minutes
keeps it through the model's thinking between edits and frees its
execution slot soon after. The server sees what the run's policy lets any
tool see: a server that needs a writable cache or the network needs the
run's `sandbox.write` or `sandbox.network` grant, and its executable must
be in a runtime of the policy.

## Looking at a web page

`browser_check` closes the build, look, fix loop for web work. In one call
it starts the dev server in the run's sandbox, waits for its port, loads
pages in a headless Chromium and stops the server. It is not in a group:
name it in an agent's `tools`.

| Argument | Meaning |
| --- | --- |
| `url` | The page as one `http://` URL, such as `http://app.localhost:8080/pricing`. Its host, port (80 when missing) and path stand for `host`, `port` and `paths` (when `paths` is left out). Needed when `port` is not given |
| `port` | The port the server listens on, on `127.0.0.1`. Needed when `url` is not given |
| `host` | The host name the pages are loaded by, for a server that tells sites apart by it, such as `app.localhost`; `127.0.0.1` by default |
| `command` | The dev server command, run through `sh`; left out, a server already listening on `port` is used |
| `cwd` | Where the command runs, relative to the workspace root |
| `paths` | URL paths to load; `["/"]` by default |
| `viewports` | `WIDTHxHEIGHT` sizes, such as `1440x900` and `390x844`; `["1440x900"]` by default. A width under 500 emulates a phone |
| `steps` | Checks run on each page after it loads: `click` and `wait_for` take a `selector`, `fill` a `selector` and a `value`, `expect_text` a `text` |
| `full_page` | Screenshot the whole page |
| `ready_timeout_ms` | How long to wait for the port; 30000 by default |

`url` and `port` or `host` must agree: the call is refused with a sentence
naming both when `url` says one port or host and the argument another.

Per path and viewport the output gives the HTTP status, the title, the
console errors and uncaught exceptions, the requests that failed or
answered 400 or more, the visible headings, links and buttons, whether the
page is wider than the viewport, and each step that failed. The call fails
when a page answers 400 or more, did not load, or a step failed; console
errors are reported and do not fail it. A call that fails still stops the
server.

Each screenshot is shown to the model ([Media](#media)), so it sees the
page as well as the outline. It is also saved as a PNG at
`.browser_check/<path>-<W>x<H>.png` in the workspace, which needs
`sandbox.write`; without it the page is still checked and shown, and the
output says the screenshot was not saved. `attach` with that `path` gives
the person the image.

It is a Deno script that speaks the DevTools protocol to the Chromium it
finds on `PATH` (`chromium`, `chromium-browser`, `google-chrome-stable`,
`google-chrome`), with `--no-sandbox` since the Bubblewrap sandbox is the
boundary. The policy's `runtimes` must hold both `deno` and the browser, as
`/usr` does. It needs no grant beyond the run's own: the server and the
browser talk over the loopback of the sandbox, which exists without
`sandbox.network`, so only a page that loads something from the internet
needs that grant, and its failed requests show up in the output when it is
missing.

## Scheduled jobs

A job runs a message, or a tool with no model, on a schedule. Jobs are data
in the store ([how to schedule a job](how-to-schedule-a-job.md)); two builtin
tools reach them.

`jobs` is the command line's tool and the call an approved proposal chains.
`action` is `list`, `show`, `history`, `preview`, `create`, `edit`, `duplicate`, `pause`,
`resume`, `run`, `archive` or `read`; `--name` is the job. A job aims at one
target: `agent` (of depth 0) or `workflow`, each with a `message`, or `tool`
with `args`. `schedule` is a 5-field cron expression, `every 30m`, `every 2h`
or `daily at 09:00`, read in `timezone`. Optional: `conversation_id` (fires go
there, and whoever reads it reads the job; it cannot change later),
`workspace`, `condition` (a tool run before each fire, as the owner, with no model; it prints
`{"run": true}`, or `{"run": false, "reason": "..."}` to skip the fire, with `"pause": true` to also pause the job)
with `condition_args`, `end_at`, `owner` (an `[accounts]` name or an
agent; else whoever creates the job) and `delivery` (`owner_inbox`, below).
`list`, `show` and `history` read the `jobs` view source; `preview` (`schedule`,
`timezone` and `agent` or `workflow`) prints the next three fires and an estimate
of the cost of a fire, or says there is no history to estimate from; `history` shows the
newest 50 events. Each other action emits one `job` action, which the store
applies as `Omunculus.Jobs.write/3`: it is refused without `[jobs]`, past
`max_jobs`, for a schedule faster than `min_interval_minutes`, for a name
taken, and in a run that a job's fire opened (a run with `via = job`, or below
one), so a job cannot make jobs. It needs `job.create` (create, duplicate),
`job.manage` (edit, pause, resume, run, archive) or `job.read` (the reads,
`read`) on the job's conversation, else on the project.

`propose_job` is the model's way to create one. It checks the job as `jobs
create` would, then asks: a request to whoever gave the agent its work, with
the job in words and its next fires, and the options `approve` (calls `jobs
create` with the proposal and the request's id), `edit` (calls nothing; the
reply says what to change) and `deny`. A job approved is owned by `owner`, else
by whoever approves it. It refuses a proposal the person already answered
without approving, and one from a run that a job's fire opened, before it asks. Where `[jobs] agent_may_create` is true the job is created
at once and nothing is asked. It works from any conversation, which is how a
mailbox sends one: the card is an ordinary request.

**Delivery.** A job whose `delivery` is `owner_inbox` hands the final reply of
each fire to its owner as a message of the job's thread, with the job as
sender (`Jobs.messages/2`; the API in [the server](server.md#jobs)).

## Groups the default package uses

```text
fs.read   = read, ls, grep, find
fs.write  = write, edit, patch
store     = comment, request_access, reply, grant, notify, read_work
sequence  = work, delegate, continue, break, wait, end, done, cancel, ask, escalate, forward, reopen, retire
catalog   = tool_search
memory    = remember, recall, forget
skills    = skill, and every skill.<name> of [skills] paths
cli       = send, jobs, inbox, inbox_read, prompt, config, configure, model_test, omapass, overview, tools, pack, login, logout, cursor_login, preset, version, update, setup
configuring = config, overview, propose_config, propose_pack
scheduling  = propose_job
assembly  = assemble
artifacts = put_artifact, get_artifact, list_artifacts
```

`directory` and `workspaces` exist as folders and are not in `fs.read`.
`preset` is CLI-only
and `config = false`. A group name in an agent's `tools` list expands to
those names at ceiling mount. A name is a tool or a group, never both:
discovery skips, and logs, a tool named as a group.

`ask` and `escalate` have both model and CLI triggers. `ask` takes a question
and optional named options, the answers the receiver is to pick among, which
an escalation keeps on its origin (omit them for a free-text answer). The CLI supplies
an existing `conversation_id` and may spell options as a JSON array.
`escalate` takes reason and a JSON/object map of named origins. Optional `to`
on `ask`, `request_access` or `escalate` names an `[accounts]` name or an agent. The same actions authenticate human authors from the
command context and agent authors from their run. Their manifest `end` step
ends model runs; with no run, that step emits nothing. Human request creation
needs send access, escalation needs reply access and matching received origins.
