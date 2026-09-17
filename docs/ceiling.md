# The ceiling

Not RBAC. Layers of ceiling; the **effective** set is the **intersection**.
A layer of config never widens another.

Before each run the harness reads the file now and the work now. It does
not reuse `RUNS.tools` from the previous run.

```text
ceiling = workspace ∩ depth ∩ stage(work.stage) ∩ agent
effective = (ceiling ∪ grants of this work ∪ grants of ancestors) − deny of any layer
RUNS.tools = effective
```

The stage is on the work. `continue` writes the next one; the run the
harness prepares after that emit already sees the new ceiling — tools in
or out — without anyone editing `grants`.

## Modes

Each layer (`workspace`, `depth`, stage, agent, `[policy]`) has a `mode`.
What was not named falls into one bucket.

| `mode` | Alias | What was not named |
| --- | --- | --- |
| `allowlist` | `deny` | blocked |
| `blocklist` | `allow` | have |
| `auto` | | askable — the agent above decides, through `REQUESTS` |

Lists, in any mode:

| List | Means |
| --- | --- |
| `granted` / `tools` | have — already usable |
| `negotiable` | askable — another agent |
| `human` | sealed — only the person, through `REQUESTS` |
| `deny` | blocked — nobody |
| `pinned` | card on the assembled prompt (does not classify have / askable) |

Precedence in the effective set: `deny` > `human` > `negotiable` >
`granted`. A layer that lists `human` beats `auto` on the others.

Who answers an `emit` `request`:

```text
blocked     → deny; no REQUESTS row
have        → already granted: <name>; no REQUESTS row
askable + an agent above with authority (have ∪ askable of theirs)
            → REQUESTS arbiter = that agent
askable with nobody above, or sealed
            → REQUESTS arbiter = human
```

`auto` only moves the unnamed bucket to askable. It does not skip
`REQUESTS` and it does not write a grant on its own. Depth 0 has nobody
above: the request goes to the person.

`pinned` intersects the same way `granted` does: an empty list on a layer
does not restrict. Tools in `pinned` ∩ effective become cards; the rest
of the effective set is `tool_search`. Without `tool_search` in the
effective set, `pinned` is ignored.

## Grants

A grant (agent above, or person) writes three things on the **work**, not
on the run:

1. `WORKS.grants` gains `ask.name` (`write`, `./secrets`, `sandbox.write`, …)
2. `EVENTS` `grant`
3. `COMMENTS` on the request thread

The old run does not gain the tool. `reply` grant prepares a run on the
**same** stage; that run remounts and adds the grant. `reply` deny does
not reopen the work.

**Temporary** — the default. `ask.name` enters only `WORKS.grants` of that
`work_id`. No work attached, no grant on any work. The TOML does not
change. The next run of this work (and of children, when they open) sees
it. Sibling works do not.

**Permanent** — `--scope agent|depth|stage|workspace` rewrites the file
on that layer. Nothing is written to `grants`. Every later run that falls
on that layer gets the access, in any work. A workspace with its own
`config` file is written there.

The harness does not copy `grants` onto a child at birth. At the opening
of a run it walks `parent_id`:

```text
grants(W) = W.grants ∪ grants(W.parent) if there is a parent
```

Not sideways, not to a cousin, not another `work_id`. `deny` on any layer
still cuts. A grant of `counter` does not pierce a `review` stage that
lists `deny = ["counter"]`.

## Sandbox resources

`sandbox.write` and `sandbox.network` are ceiling resources. They are
separate from the right to *call* a tool of a similar name. The worker in
the default preset has `request_sandbox` in `tools` and `sandbox.write` in
`negotiable`: it may ask, it may not write the workspace until a grant.

| Resource state | What the executor does |
| --- | --- |
| `sandbox.write = have` | the authorized workspace is writable |
| any other `sandbox.write` | the workspace is read-only for external commands |
| `sandbox.network = have` | Bubblewrap shares the host network namespace |
| any other `sandbox.network` | a network namespace with no host networking |

A grant ends the current run, so only the next run receives the new
policy. Network access does not provide credentials, host environment
variables, home directories, SSH agents, desktop sockets, or write access
outside the workspace.

The JavaScript coordinator has no direct workspace, network, environment
or process access. It can only call the tools authorized for this run.
MCP discovery and MCP calls are separate sandboxed sessions. Discovery
mounts the server implementation, runtime roots and private execution
files; it does not mount the workspace.

External grants are read-only. Runs that can write share the real
workspace, so concurrent changes to the same files are not isolated. The
executor enforces concurrency, queue, timeout and output limits. CPU,
memory, process-count and disk quotas are not configured.

`[execution] resources` is the universe. A name that is not on that list
is an error at load, not a resource the model can invent.
