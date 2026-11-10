# Clients

A client is any program that talks to the [server](server.md): a GUI, a TUI,
a web app, a script. The server's HTTP contract is the only thing a client
and the core share. It is versioned under `/v1` and described by the
OpenAPI document the server publishes at `/openapi.json`.

## The boundary

- A client reaches a project only through that contract: on the project's
  local socket, as the local user, or on the TCP listener with a signed JWT.
  It never opens the store, reads the TOML or calls code under `lib/` or
  `priv/`.
- The core never names a client. No endpoint, field or behaviour exists for
  one app; what a client needs is added to the contract for every client.
- `mise run validate:boundaries`, part of `mise run pre-commit`, refuses a
  tracked line of `apps/` that names `lib/`, `priv/`, `omunculus.toml` or
  the store, a line of `lib/` or `priv/` that names `apps/`, a line of
  `apps/kit/ui` that imports the client, an import under `apps/` whose path
  leaves its folder, and any link under `apps/` but an app's `kit` link. Since
  Quickshell imports only from within the folder an app runs, an app reaches
  no other app and the kit reaches no app.
- Apps call each other only through Quickshell IPC
  (`quickshell ipc --path apps/<app> call …`), never by importing.
- A launcher may find a project's socket with `mix omunculus.socket
  <server.toml> [<id>] [--any]`, which prints the id and the socket
  separated by a tab. The id may be left out while the registry holds one
  project; with `--any`, a registry of several prints an empty id and the
  socket of its first project by id. From there, `GET /v1/projects` lists
  every project of the registry with its socket.

## The setup, read through the config routes

A client reads a project's setup with `GET /v1/projects/{id}/config?whole=true`
and edits it item by item with `PUT` and `DELETE` on
`/v1/projects/{id}/config/{section}/{name}` ([the server](server.md)).
Other tools run over `POST /v1/call` on the project's local socket,
`{"name": <tool>, "args": {…}}`, with the arguments the
[command line](cli.md) lists. Two forms are printed whole for a client:

- the config route prints the setup as one JSON object: its `root`,
  `agents` (name, depth, model, `workflow_only`, the `granted`,
  `negotiable`, `human` and `deny` lists of its own layer, its text and
  the SHA-256 of its `image`, or null), `models` (name, `api`,
  `provider`, `model`, and nothing else of their tables), `workspaces`
  (name, root), the default `workspace` and `workflows` with their steps.
  For an editor it adds `document`: the `agents`, `models`, `workflows`,
  `workspaces`, `auth` providers and tool `secrets` by name and the
  `policy` and `access` tables, as the file writes them, but for a
  provider's literal `key`, which stays in the file; `literal_keys` names
  the providers that have one. It adds `revision`, the SHA-256 of the
  file's bytes, which a write takes back, and `names`, what a ceiling
  list may hold: the model tools, their groups and the sandbox resources.
- `overview` with `{"whole": true}` prints the project as it runs in each place a
  work can run. `places` holds each workspace, and the project root while
  no workspace is the default; a place has its `root`, whether it is the
  `default` and whether it lies `outside` the project, its own ceiling
  lists (`layer`), what it overlays (`changes`) and its `depths`. A depth
  has the `workflows` a work there may go through, each with its `name`,
  whether it is `required` there and its `stages` (name, `deny`, agent);
  whether the place `changed` them; and the `agents` a work goes to
  without a stage, an `idle` one being workflow-only. An agent has its
  `model` (name, id, api, `body`, whether the place `changed` it), the
  `key` of its provider (the provider and where its value comes from:
  `$VAR`, `omapass · <account>`, `command`, `stored login` or `in the
  file`, never the value), the names its layer lists, each with its
  `state` under the ceiling there (`have`, `askable`, `sealed`,
  `blocked`), a group's `members` and the `secrets` the config binds to
  it, the names its layer denies (`deny`) and, apart, its `skills`, each
  with its `description`, `state` and the tools its `allowed-tools` names
  (`uses`). Its `broken` lists, each with a `kind` (`tool` or `skill`), the
  `name` and the reason (`why`), what its layers name that the catalog
  lacks. The overview's own `broken` lists the `[secrets.<tool>]` bindings
  of a tool the catalog lacks. Neither checks tools while an `[[mcp.servers]]`
  entry exists, since a server's tools are known only by asking it; a model, a
  provider or an agent that is not declared never shows, since the config
  does not load. `unused_workflows` are those no place runs.

The config route loads the TOML in the harness's process; the sandbox hides
the file from external tools.

## The apps in this repository

`apps/` holds the clients that come with Omunculus, each a folder that
`apps/kit/run <app> --config <server.toml> [--project <id>]` opens on a
project, given as `OMUNCULUS_PROJECT` and its local socket as
`OMUNCULUS_SOCKET`. Without `--project`, a registry of one project opens on
it; of several, the console opens on the registry, with an empty
`OMUNCULUS_PROJECT` and the socket of one of its projects, while the mailbox
and the studio ask for `--project`:

| App | Is |
| --- | --- |
| [`apps/console`](console.md) | the window on one project: its conversations, each as threads of its agents' runs with their tool calls and the works they handed down, the progress of its works, and the team page, its agents as a tree of who handed work to whom with their works and requests; and a board of the works of every project of the registry, by state |
| [`apps/mailbox`](mailbox.md) | an e-mail client over every project: a thread is a conversation with one agent of depth 0, and its requests to you are e-mails you reply to |
| [`apps/studio`](studio.md) | the settings of a project: its flowchart on a canvas, then one item of the config at a time |

All are QML on Quickshell and share `apps/kit`:

- `apps/kit/ui`: the theme and the controls of the apps, taken from eco's
  kit and kept to what Omunculus shows. `Theme` holds the colours — text
  tones lifted to 4.5:1 on the background, `faint`, for a mark beside a
  text naming the same thing, as a tab's digit, to 3:1 — and the layout
  tokens every layout reads instead of numbers of its own:
  `Theme.space` (the window's margin `page`, `section`, `block`, `inset`,
  `insetTop`, `trail`, `gap`, `tight`, `line`, `row` and `cell`, with
  `pageShort`, `sectionShort` and `blockShort` for a window under 560 px
  tall), `Theme.size` (a header `strip`, a list `row` and a stacked one, a
  section `rule`, a `control` and a dense one, a `chip`, a bubble's `gutter`,
  `bubbleInset` and `measure`) and `Theme.type` (the pixel size and letter
  spacing of a `name`, `stamp`, `body`, `cardBody`, `kicker`, `meta`,
  `header`, `section`, `tab` and its digit, and `input`). `mise run
  check:spacing` (part of `mise run check`) fails on a margin, padding,
  spacing or height written as a number in the console or the kit, but 0, 1
  and a negative reach past an item; `scripts/check-spacing.allow` lists the
  kit's drawn geometry it leaves out.

  The controls: `Masthead`, the window's top line, the name (left out under
  560 px), the crumbs of where the window is, those that lead somewhere as
  links, and its tools on the right; `TabRail`, an app's pages in a fixed order down the left edge,
  ↑ ↓ Home End moving along it, with `PageBar`, the commands of the page on
  screen beside it, ranked by its `CommandRow` — BACK apart, the page's main
  action solid on the left, the others outlined on the right, the guarded
  ones last behind a hairline, those of one group joined as one control with
  the checked one lit — and the page's readout at its end, which gives way
  first. When the names do not fit, BACK is only its chevron and the actions
  take their short names, then all but the main one their icons, then the
  lowest ranked move into the `ActionMenu` of a `⋯` button; BACK and the main
  action stay. Under 700 px the rail is hidden and the bar's page switcher
  (when the app gives it its pages) lists the pages. `Tab` is a section
  switch, `01 CHAT`, underlined while shown. `TraceButton`, `IconButton` and
  `Chip` are the buttons; each with a `reason` reads disabled and says why
  on hover. `ChipStrip` keeps chips on one line that scrolls sideways;
  `TagChip` is a `#name` chip with an optional menu; `NoticeChip` a notice
  to follow or close; `ActionMenu` a view's rare actions behind `⋯`, in a
  `MenuPopup` of `ChoiceRow`s on a `PopupFrame`. `DataTable` lists records
  as rows of columns, stacked into lines under 700 px, grouped under section
  rules, with a status, tools on the right and an empty state. `ToastStack`
  shows what a window tells as toasts at its bottom right, each a
  `StatusMessage`: information closes itself, an error stays until closed.
  `Field`, `FieldError`, `TextBox`, `SyncedBox`, `NumberField`, `TextBlock`,
  `Dropdown` and `PickRow` are the form's inputs, `ProgressTrack` a fraction
  filled, `Panel`, `ModalDialog`, `ConfirmDialog` and `DialogFooter` the
  frames. `FlowCanvas` is a canvas that moves, zooms and pinches, with its
  `ZoomControl`. `Breakpoints.js` holds the widths the apps change their
  layout at (narrow under 700 px, wide from 1100, tight under 420) and the
  margins, control heights and indents at each; buttons, chips, captions
  and tips never grow past what holds them or the window, eliding or
  wrapping instead. `TextAudit`, when an app loads it, logs each text that
  escapes its box, the window or a clipping item, as a `text-fit:` line.
  `FilePicker` and `FileChip` are the files a message carries and a file
  attached in a conversation; `Portrait` an agent's picture, which the app
  fetched, or while it has none its initial in its colour; and `Prose`, what
  an agent wrote as Markdown as it was written, each line break kept and a
  line after a list that is no item of it a paragraph of its own, rather
  than more of the last item; an image shows as its alt text and is never
  loaded (`Markdown.js`); its web addresses, bare or linked, are links in
  the accent that the pointer turns over, an inline code span sits on a tint, Tab reaches, Left and Right pick
  and Enter opens with `xdg-open`, only http and https. It knows nothing of
  Omunculus.
- `apps/kit/client`: `Http`, which makes each request to a socket through
  `curl` or saves its answer into a file, posts a message with files through
  `post-with-files` and saves and opens an attached file through
  `open-attachment`, the scripts beside it, `AgentImages`, which keeps the
  agents' images in Quickshell's cache, and `Requests.js`, the helpers
  that read a request's status and participants, the decisions it gathers
  from below and the option a reply chose, the request holding a question
  as it climbs and the works it climbed from, whether the harness opened it
  and the questions it then passes on, and build a reply; `Progress.js`,
  which derives from a conversation's state and stage events where its
  works are, nested by stage and level, with what each does, waits on and
  spent, and fits one-line stages and phrases to a width in characters;
  `Team.js`, which lays those works out as the team page's tree of agents,
  what shows and what folds, and moves through it by key;
  `Calls.js`, which groups a run's tool calls into rows and reads the diff
  of an edit or a write from its args; `Phrases.js`, which says a tool call
  in plain words and in brief; `Events.js`, which says any event in one
  plain sentence for the log, and tells a hook's call from a tool's; `Project`, the project a window is on, or
  only the registry it was opened on, and whether the server answers, which
  the console and the studio share; `Notices`, what a window tells, as its
  `ToastStack` shows them, with a pinned error while the server does not
  answer, which the three apps use; and `Model.js`, which reads the text a
  model event carries.

Each app reaches the kit through a `kit` link to `apps/kit/`, since
Quickshell imports only from within the folder it runs. The kit imports no
app.
