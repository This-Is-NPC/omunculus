# `omunculus`

Dispatch a tool by name.

Exit codes: 0, the run did what was asked; 1, a refusal, a usage error, a
missing config, or a tool that returned `ok` false. There is no exit 2. A
path that is not there, a store that will not open and a model that will not
answer are all 1, and the line on stderr is the reason.

The binary has no verbs of its own. `omunculus send` is the `send` tool,
`omunculus inbox` is the `inbox` tool: the same `{ name, args, view }` in and
`{ ok, output, emit }` out the model uses, with `trigger = cli`. Replacing
the folder named `send` replaces the command. A name the catalog does not
hold is a refusal.

`--config <path>` is the only flag that belongs to the binary, and it must
come first. Without it the file is `./omunculus.toml` in the working
directory. `bin/omunculus` always passes that path unless the first argument
is already `--config`. The project root is the directory of that file, or
`[project] root` resolved against it. The SQLite store is `[store] path`,
also resolved against the file.

A missing file is `no config at <path>; run 'omunculus preset <name> --from <dir>'`. The package does not load `priv/omunculus.toml` behind your back.
The one exception is a tool whose manifest set `config = false`, which is
how `preset` can write the file every other verb then reads. `preset` still
takes `--config` as the destination it writes to.

Arguments after the name are `--key value`, or one positional value mapped
onto the first `required` key in the tool's parameters. `omunculus send
"count to 5"` is `message`. A second bare word is a usage error. A `--key`
without a value is a usage error. Keys the schema did not list are still
passed through, which is how `send --work_id <id>` aims a message at a work
the manifest did not have to advertise as required.

Stdout is the tool's `output` and nothing else. Empty output is a successful
run that had nothing to print — `send` and `reply` are this — rather than a
missing result. Stderr is the formatted error; a tool that failed puts its
`output` there and exits 1.

## `omunculus preset`

- **Usage:** `omunculus preset <name> --from <dir>`
- **Config:** not required (`config = false`)

Copy a preset onto the config path.

`<name>` is recorded in the receipt (`preset <name> applied`). `--from` is
the directory that actually supplies the bytes: it must contain
`omunculus.toml`, and if it contains `tools/` that tree is copied beside the
file. `[tools] paths` and `[execution.sandbox] script` are rewritten to
absolute locations resolved against `--from`, so a checkout of
`priv/presets/default` keeps pointing at `priv/tools` and `priv/sandbox.js`
after the copy.

The three folders the package ships:

| `--from` | What it is |
| --- | --- |
| `priv/presets/default` | concierge / worker / reviewer, `fake` model, no shell |
| `priv/presets/codex-like` | Codex-shaped ceiling, plus a `bash` tool |
| `priv/presets/pi-like` | Pi-shaped ceiling, Anthropic OAuth already declared |

A `--from` that is not a directory, or that has no `omunculus.toml`, is
`unknown preset: <name>`.

## `omunculus send`

- **Usage:** `omunculus send <message> [--work_id <id>]`
- **Effect:** writes `PROMPTS(message)` and `EVENTS(prompt)`; then the
  harness opens a run

Deliver a message. It does not create a work and it does not copy the
message onto a title. If the model wants a work, it calls `work`.

`--work_id` aims the prompt at a work that already exists. A work in
`waiting` is reopened (`state = open`, waiting fields cleared) and
`EVENTS(work)` is written with `reason = reopened_by_prompt` before
`EVENTS(prompt)`. That includes `waiting = child`: the parent walks on
without the child.

The stdout of a successful send is empty. The assembled prompt and the
model's text are in the store; `prompt` prints the first of those.

## `omunculus prompt`

- **Usage:** `omunculus prompt [--run <id>]`
- **Effect:** read-only

Print the assembled prompt of a run. Without `--run`, the last run by
`started_at`. No runs is `no runs`. An id the store does not hold is
`unknown run <id>`. A run that never attached an assembled prompt is
`no assembled prompt`.

## `omunculus inbox`

- **Usage:** `omunculus inbox`
- **Effect:** read-only

List unread notifications, one per line: `id agent: body`. An empty list
prints `empty inbox` and still exits 0 — that is the answer, not a
failure to find one. Inbox does not wait on a decision and does not
park a work.

## `omunculus inbox_read`

- **Usage:** `omunculus inbox_read <inbox_id>`
- **Effect:** sets `INBOX.read_at`

Mark one notification read. The next `inbox` listing leaves it out.

## `omunculus reply`

- **Usage:** `omunculus reply <body> --request_id <id> --decision grant|deny [--scope agent|depth|stage|workspace]`
- **Effect:** comment + grant or deny on that request

Answer a request. `grant` on a work writes `ask.name` into `WORKS.grants`
(unless `--scope` names a TOML layer, in which case the file is rewritten
and `grants` is left alone), clears `waiting`, and the harness opens a run
on the same stage. `deny` leaves the work `waiting` — `waiting = access`,
`waiting_for` intact — and opens no run.

`--scope` is a permanent ceiling change. Workspace scope writes the
workspace's own file when `[workspaces.<name>] config` points at one.

## `omunculus comment`

- **Usage:** `omunculus comment <body> [--work_id <id>] [--request_id <id>] [--inbox_id <id>]`

Write a comment. At least one target. The store refuses a comment with none.

## `omunculus login`

- **Usage:** `omunculus login --provider <id> [--key <secret>] [--redirect_url <url>]`

Store a credential for an `[auth.<id>]` provider, in the JSON file
`[auth] store` names (mode 0600).

`api_key`: `--key` or a prompt on stdin (`api key: `). `oauth-code`: a
localhost callback, PKCE when the provider asked for it. `tool`: the
provider's `login` tool is dispatched instead (`cursor_login` is the
one the package ships).

A provider the TOML does not declare is `unknown auth provider: <id>`.
A model that needs a login and has none fails later with `not logged in
to <id>; run 'omunculus login --provider <id>'`.

## `omunculus logout`

- **Usage:** `omunculus logout --provider <id>`

Remove that provider's record from the auth store. The TOML is not
touched.

## `omunculus cursor_login`

Cursor's browser login, as the `tool` kind behind an `[auth]` provider
that names it. Same contract as `login`; the bytes it stores are Cursor's.

## Errors the binary names itself

These are formatted on stderr before a tool runs, or after the store
refuses to open:

| Line | When |
| --- | --- |
| `no config at <path>; run 'omunculus preset <name> --from <dir>'` | file missing |
| `omunculus.toml is missing [execution]; required keys: …` | table or keys absent |
| `omunculus.toml is missing [execution.sandbox]` | sandbox table absent |
| `omunculus.toml is missing [models]` | no adapters |
| `omunculus.toml is missing [store]` | no store path |
| `omunculus.toml agent <name> is missing model` | agent without `model` |
| `omunculus.toml is missing assemble` | no assemble tool named |
| `assemble returned an empty prompt` | assemble ran and produced nothing |
| `not logged in to <id>; run 'omunculus login --provider <id>'` | credential missing |

Anything else is `inspect` of the reason, or the tool's own `output`.
