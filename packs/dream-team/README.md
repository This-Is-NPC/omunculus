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
| copilot | 1, workflow only | reviews each item against its goal, the plan's checks and AGENTS.md |
| clerk | 1, workflow only | publishes the whole to homologation, then to production once the person grants promote |
| toolsmith | 2 | mise, scripts, the means to check and publish |
| tester | 2 | writes and runs the tests |
| editor | 2 | README.md and docs/ |
| language_lawyer | 2 | how a language, library or version is meant to be used |

The administrator first writes `docs/plan.md`: a `## base` item, the
structure every page shares, then a `## page: <name>` item per page, each
with what it shows and how to check it. Each item is a work of the
workflow `page` — build (surgeon), review (copilot) — handed down one at a
time, base first; then one work of the workflow `release` — publish, then
promote (clerk) — takes the whole out. The pack's tool `deliver`, the
administrator's way to conclude, refuses a build until every item and the
release came back done. A release that breaks because of what an item
built is not sent back to hold it: the administrator retires it, hands the
item down again through `page`, and then a new release. The pack requires
both workflows at the surgeon's depth; a project that composes teams may
change their stages in its own `[workflows.page]` and
`[workflows.release]`, as long as it requires them there.

## What it holds

```text
pack.toml       the agents, on the role `team`, the workflow, and the secrets
                of the deploy tools, on the providers `homologation` and
                `production`
tools/          deploy_preview (homologation), promote (production) and
                deliver, the administrator's done; _deploy, the script the
                two deploy tools run, which they read beside their own folders
workspace/      AGENTS.md, the rules every agent of the team follows
environment/    up and down: the two Dokku instances the deploy tools reach
tasks/          the tasks that show the team works, in the eval's format
images/         a portrait of each agent, <agent>.webp, 512 px square, its `image`
```

## Using it

1. Start its environment: `environment/up`. It needs Docker, starts the
   homologation and production Dokku instances on 127.0.0.1, gives each a
   key of its own under `environment/.state/keys` and a unix socket in
   `/var/tmp/omunculus-deploy`, which `environment/.state/sockets` links
   to. `environment/down` stops them.
2. In the project's `omunculus.toml`, give the deploy tools what they read:
   `OMUNCULUS_DEPLOY` in `[execution] environment`, set to the sockets
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

The network is the person's: `sandbox.network` is in every agent's
`human` list, and none holds it. `workspace/AGENTS.md` has the builders
pin the tools the machine already holds, at the version it holds, and
register that install with `mise link` (`mise link --force
node@<version> /usr` for the `/usr/bin/node` the runtimes give), so
`mise install` downloads nothing; only a tool the machine lacks makes the
surgeon or a helper ask, through `request_access` to `owner`, for
`sandbox.network`.

The deploy tools name each app after the root it is published from:
`<app>-<id>-hml` in homologation and `<app>-<id>` in production, `<id>`
the first six hex digits of the root's SHA-256, so two projects publish
apps of their own, and, with `[project] conversations`, so do two
conversations of one project, each working in its own folder
([config](../../docs/config.md#a-folder-per-conversation)).

No command reaches a container daemon: the Docker socket is let into
none, as it would give a command the machine. The image is checked
where it is published: `deploy_preview` has homologation build it and
answers with the build's output when it fails, which the clerk brings
back for the build to be fixed.

`promote` is in every agent's `human` list: only the person grants it, once
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
for example:

```toml
[policy]
request_routes = [{ name = "owner", via = ["origin"] }, { via = ["parent", "origin"] }]
```

Replace its destination with the participant who runs the machine when
that is not the conversation's origin. The lead answers received requests from the briefing or work goal and escalates all remaining questions together, preserving named origins; returned text is distributed with `reply`. Requests preserve waits on children. `break` stops failed work.
