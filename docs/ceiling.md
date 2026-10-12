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

The stage is on the work. `continue`, which `done` chains, writes the next one; the run the
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

Who answers an `emit` `request`. Its options are lists of tool calls; the
names the `grant` calls give are classified for the requester:

```text
a granted name blocked
            → deny; no REQUESTS row
only grant calls, every name have
            → already granted: <name>; no REQUESTS row
otherwise   → resolve the configured request route
```

`auto` only moves the unnamed bucket to askable. It does not skip
`REQUESTS` and does not write a grant on its own. Routing follows the
first matching `[policy] request_routes` rule, independently of whether
the receiving participant can authorize the option. A receiver answers
or escalates through the same linked request path. A sealed grant climbs
that route; only an authorized human may choose its grant option on the
original request, directly or through named reply parts. The arbiter's
`reply` chains chosen option calls under its ceiling; an agent needs each
of them as have in its run. See [request routing](config.md).

`pinned` intersects the same way `granted` does: an empty list on a layer
does not restrict. Tools in `pinned` ∩ effective become cards; the rest
of the effective set is `tool_search`. Without `tool_search` in the
effective set, `pinned` is ignored.

## Grants

A grant is the `grant` tool, a step `reply` chains from the chosen
option. It writes on the requester's **work**, not on the run:

1. `WORKS.grants` gains the granted name (`write`, `./secrets`, `sandbox.write`, …)
2. `EVENTS` `grant`

and the `reply` writes its body in `COMMENTS` on the request thread.

The old run does not gain the tool. The `reply` reopens the work and
prepares a run on the **same** stage; that run remounts and adds the
grant. `deny` reopens it too, without the name.

**Temporary** — no `scope`. The name enters only `WORKS.grants` of the
request's work. No work attached, no grant on any work. The TOML does not
change. The next run of this work (and of children, when they open) sees
it. Sibling works do not.

**Permanent** — `scope` = `agent`, `depth`, `stage` or `workspace`, only
from a person: the store refuses a scoped grant by an agent. The harness
rewrites the file on that layer before it opens the next run. Nothing is
written to `grants`. Every later run that falls on that layer gets the
access, in any work. A workspace with its own `config` file is written
there.

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
the default preset has `request_access` in `tools` and `sandbox.write` in
`human`: it may ask through the configured route, and it may not write
the workspace until a grant.

| Resource state | What the executor does |
| --- | --- |
| `sandbox.write = have` | the authorized workspace is writable |
| any other `sandbox.write` | the workspace is read-only for external commands |
| `sandbox.network = have` | Bubblewrap shares the host network namespace |
| any other `sandbox.network` | a network namespace with no host networking |

A grant does not change the policy of a run already open; only the
next run receives the new policy. Network access does not provide credentials, host environment
variables, home directories, SSH agents, desktop sockets, or write access
outside the workspace. A tool's own credentials come only from the
secrets the config binds to it ([Tool secrets](config.md#tool-secrets)),
and only its process receives them.

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
