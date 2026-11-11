# The dream team

Takes a request from a conversation to a published app. It is the surgical
team of *The Mythical Man-Month*, ch. 3: one surgeon designs and writes what
matters, the others free them of the rest. The administrator asks until the
request is clear and plans it, the surgeon builds each item of the plan with
the helpers below, the copilot reviews each, and the clerk publishes the
whole to homologation, then to production once the person grants `promote`.

| Agent | Depth | Role |
|---|---|---|
| administrator | 0 | talks with the person until the work is ready, plans it and hands down each item |
| surgeon | 1 | builds each item of the plan, writing the code that matters |
| copilot | 1, workflow only | reviews each item, independently of the surgeon, against its goal, the plan's checks and AGENTS.md; with a design, against its handoff; without one, against the scope |
| clerk | 1, workflow only | publishes the whole to homologation, then to production once the person grants promote |
| toolsmith | 2 | mise, scripts, the means to check and publish |
| tester | 2 | writes and runs the tests |
| editor | 2 | README.md and docs/ |
| language_lawyer | 2 | how a language, library or version is meant to be used |

## Receiving work

The administrator takes a work from whoever asks, the person or the
agent of a team above. Its goal is all that was agreed, in full, in the
person's own words for names, prices and contacts, since the team has not
seen the conversation, and it says that the workspace's `AGENTS.md` is the
rule for how the work is built. Three kinds of goal are understood:

- **A build.** The goal may hold, from the sales desk, a block from `=== PROPOSAL FACTS` to `=== END PROPOSAL FACTS ===` composed from the proposal (sections for the client, pages, products and prices, contacts with the WhatsApp number, hours and address, colours, fonts and style, texts, pending and the design), which the plan and each item's goal repeat verbatim; only its PENDING items are pending. The goal gives what the site or app is for, what it must do
  and contain, and who it is for, and states the design: either it names
  `design/handoff.md`, the approved design the builders build from, or it
  says the client waived the design, and the team builds from the scope in
  the goal. A goal that says neither is asked about, not assumed.
- **An assessment.** The goal begins `Assessment only, build nothing:` and
  gives the scope as the client asked it (pages, features, content, what is
  pending, the timing hoped for, and `design/handoff.md` when there is an
  approved design). The administrator answers it itself, never through the
  workflow `page`, and delivers a written answer that opens with yes, no or
  partly, then the effort (the items and how large each is, never a date),
  what blocks it and what could be built instead.
- **A change to an earlier work.** The goal names it (title and id) and
  says what changes.

Missing information is asked with `ask` before anything is handed down.

## How it builds

The administrator first writes `docs/plan.md`: a line saying "Design:
approved (design/handoff.md)" or "Design: waived by the client", a
`## base` item, the structure every page shares (the layout, the
navigation, the styles, the `Dockerfile`, `deploy.toml` and the tooling),
then a `## page: <name>` item per page, each
with what it shows and how to check it. Each item is a work of the
workflow `page` — build (surgeon), review (copilot). Base is handed down
first and alone. Once it is done, page items are handed down together,
each batch only as large as the free run slots under
`[execution] max_concurrent`. Pages that do not fit are handed down only
after that batch has finished and released its slots. One work of the
workflow `release` — publish, then promote (clerk) — is handed down only
when every page item is done, and takes the whole out. The pack's tool
`deliver`, the
administrator's way to conclude, refuses a build until every item and the
release came back done. A release that breaks because of what an item
built is not sent back to hold it: the administrator retires it, hands the
item down again through `page`, and then a new release. The pack requires
both workflows at the surgeon's depth; a project that composes teams may
change their stages in its own `[workflows.page]` and
`[workflows.release]`, as long as it requires them there.

## What it holds

```text
pack.toml       the agents, on the role `team`, the workflows `page` and
                `release`, and the secrets
                of the deploy tools, on the providers `homologation` and
                `production`
tools/          the deploy tools — deploy_preview, deploy_status,
                deploy_logs, deploy_destroy (the preview environment) and
                promote (production) — and deliver, the administrator's
                done; _deploy, which they read beside their own folders: the
                neutral script they run and providers/, one executable per
                provider (dokku)
workspace/      AGENTS.md, the rules every agent of the team follows
environment/    up and down: the two Dokku instances the dokku provider reaches
tasks/          the tasks that show the team works, in the eval's format
images/         a portrait of each agent, <agent>.webp, 512 px square, its `image`
```

## The deploy contract

The deploy tools know no hosting provider. What the build hands them, and
what they answer, is the same whichever provider publishes it.

**What the build produces.** A repository whose root holds, both committed, written by the base item's builder (the surgeon, or the toolsmith it asks) and checked by the review:

- a `Dockerfile`: the image is built from it, where it is published;
- `deploy.toml`, the descriptor:

```toml
app = "bakery"        # lowercase letters, digits and dashes, starting with a letter
port = 3000           # the port the image serves; the address answers on it
```

When the workspace's root already holds a design preview's two files (app
`design-<slug>`, serving `design/preview`, from the design team), the base
item replaces both with the site's own, the client's slug as the app, and the
review and the clerk's `publish` refuse a `design-<slug>` app, so the
release never publishes the design preview. That rule belongs to the
site's build; the design stage's own review requires `design-<slug>`.

The tools read the descriptor and the Dockerfile from the commit they
publish (`git show HEAD:deploy.toml`), never from the working tree, so what
is pushed is what was read. A key outside these two, a value that does not
fit, or a file that is not committed is refused with what to fix. The
descriptor holds no variable of the app: values the app needs are the
environment's, not the repository's, and no tool sets them.

**What the tools offer.** None takes the app: it is the descriptor's.

| Tool | Does |
|---|---|
| `deploy_preview` | publishes the commit at HEAD to the preview environment, records it as `refs/deploy/preview` in the workspace, and concludes the stage: comments the preview address and the commit, and continues |
| `deploy_status` | says whether the preview app is deployed and running, and its address; "not deployed" and "environment not reachable" are different answers |
| `deploy_logs` | reads the last `lines` (1 to 1000, 100 when left out) of the preview app's log, as the app wrote it |
| `deploy_destroy` | removes the preview app; an app that is already gone is not an error |
| `promote` | publishes to production the image the previewed commit built, with that commit's descriptor, and concludes the release; the person's grant, as below. Without a preview it refuses |

`deploy_status`, `deploy_logs` and `deploy_destroy` take the app's name from
the previewed commit's descriptor, so a descriptor edited or broken since
does not strand the preview app; before any preview they read HEAD's.

The preview app is `<app>-<id>-hml` and the production app `<app>-<id>`,
`<id>` the first twelve hex digits of the SHA-256 of the root it is
published from. Agents hold the preview's credentials only, so status, logs
and destroy never reach production. No manifest or message of the tools
names the provider, how it is reached or its credentials; a provider that
crashes or answers nothing is reported as "the deploy provider failed",
without what it printed.

**What a provider is.** An executable in `tools/_deploy/providers/`, named
for it, that the tools run as `<provider> <operation>` for `deploy`,
`promote`, `status`, `logs` or `destroy`. It reads on stdin
`{"environment": "preview" | "production", "app", "source", "root",
"commit", "port", "lines"}` (`source` is the preview app, for `promote`;
`lines`, for `logs`) and writes on stdout `{"ok", "output", "address"}`,
its own messages with nothing that names the provider. The provider is
chosen by configuration, `OMUNCULUS_DEPLOY_PROVIDER` in `[execution]
environment`; with it unset the tools answer that no provider is
configured. Each tool's secret `DEPLOY_KEY` is bound to the login
`homologation` or `production`, whatever a provider makes of it.

`dokku` is the one the pack has: it reaches the two instances of
`environment/` through the unix sockets under `OMUNCULUS_DEPLOY`, creates
the app, maps port 80 to the descriptor's port and builds the image from
the repository. A connection that fails is never taken for an absent app.
Its waits are constants in the script, in seconds: 5 for its credentials'
agent, 60 for a command, 600 for a build or a port change; the tool's
own `[execution] timeout_ms` still bounds the whole call.

The contract test, `test/omunculus/deploy_contract_test.exs`, runs the tools
against that provider with a stub that records its calls, and checks each
operation's calls and that the answers stay neutral.

## Using it

1. Start its environment: `environment/up`. It needs Docker, starts the
   homologation and production Dokku instances on 127.0.0.1, gives each a
   key of its own under `environment/.state/keys` and a unix socket in
   `/var/tmp/omunculus-deploy`, which `environment/.state/sockets` links
   to. `environment/down` stops them.
2. In the project's `omunculus.toml`, give the deploy tools what they read:
   `OMUNCULUS_DEPLOY_PROVIDER` and `OMUNCULUS_DEPLOY` in `[execution]
   environment`, the first set, in the server's environment or the command
   line's, to `dokku` and the second to the sockets
   folder itself, `/var/tmp/omunculus-deploy`, and that folder in
   `[execution] write` unless `[execution] host` shows commands the machine
   (a command sees only the folders it is given, so neither the link nor a
   folder left out reaches the sockets),
   and two logins whose keys are the instances' private keys, for example
   `[auth.homologation]` with `key = "$OMUNCULUS_HOMOLOGATION_KEY"` and
   `[auth.production]` with `key = "$OMUNCULUS_PRODUCTION_KEY"`.
3. Its agents commit as the person running it, and set no identity of
   their own: name `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
   `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` in `[execution]
   environment` and set them, in the server's environment or the
   command line's, to that person's name and email. Without
   `[execution] host` a command's home is the run's scratch, which holds
   no `.gitconfig`, so git has no other identity. The agents read it
   with `git var GIT_AUTHOR_IDENT`, as a commit does, and never ask for
   one.
4. Its agents work through `bash`, which the pack `requires` and does not
   bring: add the codex-like preset's tools (`priv/presets/codex-like/tools`)
   to the project's `[tools] paths`.
5. Import it: `omunculus pack --path <this folder> --models team=<model>
   --auth homologation=<login>,production=<login>`. It writes the pack to
   `[[packs]]` and copies `workspace/AGENTS.md` into the project's workspace.

`sandbox.network` is negotiable for every agent, not sealed to the person:
a builder's `request_access` for it goes to its parent (the toolsmith's,
tester's, editor's and language lawyer's to the surgeon, the surgeon's to
the administrator), which holds `grant` and answers with the grant. Only
a request routed to `owner` reaches the person. A tool the person's mise
already installed needs no network: with `[execution] read` naming the
mise installs folder and `[execution] variables` setting
`MISE_SHARED_INSTALL_DIRS` to it, a command resolves the pinned version
read-only ([config](../../docs/config.md#required-tables)).
`workspace/AGENTS.md` has the builders pin the tools the machine already
holds, at the version it holds, and register an install of the runtimes
with `mise link` (`mise link --force node@<version> /usr` for the
`/usr/bin/node` the runtimes give), so `mise install` downloads nothing.

A review sends back only a defect against the goal, the plan or the
handoff, naming the item to fix; wording, taste and minor content issues are notes for the next pass. When the
same item comes back from review twice with the same defect, the
administrator asks the owner (`to = "owner"`) rather than reopening it
again. Operational and internal decisions that must reach a human (a
build that will not converge, a tool or login the machine lacks)
use that route; the default route ends at the client.

The names come from the root, so two projects publish apps of their
own, and, with `[project] conversations`, so do two conversations of one
project, each working in its own folder
([config](../../docs/config.md#a-folder-per-conversation)).

No command reaches a container daemon: the Docker socket is let into
none, as it would give a command the machine. The image is checked
where it is published: `deploy_preview` has the preview environment build it and
answers with the build's output when it fails, which the clerk brings
back for the build to be fixed.

`promote` is in the clerk's `human` list: only the person grants it, once
they have seen the app in homologation. That grant is their approval of
it, the only one: the administrator asks for none after the release. The
clerk's request for it gives, written out, the homologation address
`deploy_preview` gave, since those who pass it on know no other address of
the built site; an answer in words without the grant is a question to the
clerk, which asks again with the address.

`deploy_preview` concludes the stage `publish` the same way: once it
publishes, it comments the homologation address and the commit on the
work and continues it, ending the run, and the stage denies `done`, so no
stage after it sees a release that published nothing. `promote` concludes
the release: once it publishes, it comments the production address on the
work and continues it, ending the run, and the stage `promote` denies
`done`. The release ends only with production published or with the
clerk's `break` saying why not; a project that composes its own
`[workflows.release]` keeps `deny = ["done"]` on both stages.

Questions use `ask`. What only the machine's operator can settle — a
tool, a login or a setting the machine lacks, as git's author identity —
the administrator and the surgeon ask through the logical route `owner`,
never toward whoever asked for the work, so the project configures it,
for example (`harness_route` sends the harness's own requests the same way):

```toml
[policy]
harness_route = "owner"
request_routes = [{ name = "owner", via = ["owners", "origin"] }, { via = ["parent", "origin"] }]
```

Replace its destination with the participant who runs the machine when
that is not the conversation's origin. The administrator answers received
requests from the work goal, the plan and the answers it knows and
escalates all remaining questions together, preserving named origins;
returned text is distributed with `reply`. Requests preserve waits on
children. `break` stops failed work.
