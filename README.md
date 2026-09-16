# Omunculus

Omunculus is a local workflow harness for tool-using agents. It targets Linux,
Elixir 1.17, OTP 27, Deno 2.9, and Bubblewrap 0.8 or newer.

## Runtime requirements

`bwrap` must be installed and the kernel must allow Bubblewrap to create its
user, mount, PID, IPC, UTS, and network namespaces. Omunculus verifies the
backend before starting a command and returns an execution error when the
required isolation cannot be created. It never retries that command on the
host.

Every project configuration declares the executable roots made available to a
run. A runtime root is read-only inside the sandbox and exposes the binaries it
contains; it is not a per-binary allowlist. Keep runtime installations outside
workspaces and in locations the sandboxed process cannot modify.

```toml
[execution]
backend = "bubblewrap"
runtimes = ["/usr"]
environment = ["LANG", "LC_ALL", "TERM"]
timeout_ms = 30000
max_output_bytes = 1048576
max_concurrent = 4
max_queue = 64
queue_timeout_ms = 30000
```

A project configuration must include this table. The executor does not install
Bubblewrap or language runtimes, and it does not support an older execution
configuration.

## Sandbox permissions

`sandbox.write` and `sandbox.network` are ceiling resources. They are separate
from the authorization to call a tool with a similar name.

| Resource state | Execution effect |
| --- | --- |
| `sandbox.write = have` | The authorized workspace is writable. |
| any other `sandbox.write` state | The workspace is read-only for external commands. |
| `sandbox.network = have` | Bubblewrap shares the host network namespace. |
| any other `sandbox.network` state | Bubblewrap creates a network namespace without host networking. |

A grant ends the current run, so only the next run receives the new policy.
Network access does not provide credentials, host environment variables, home
directories, SSH agents, desktop sockets, or write access outside the workspace.

The JavaScript coordinator has no direct workspace, network, environment, or
process access. It can only call the tools authorized for the current run. MCP
discovery and MCP calls run in separate sandboxed sessions. Discovery mounts
only its configured server implementation, runtime roots, and private
execution files; it does not mount the workspace.

External grants are read-only. Runs that can write share the real workspace, so
concurrent changes to the same files are not isolated. The executor enforces
concurrency, queue, timeout, and output limits. CPU, memory, process-count,
and disk quotas are not configured.

## Verification

Run the regular suite with:

```sh
mise exec -- mix test --exclude cargo --exclude sandbox
```

The `sandbox` tests require a Linux environment where Bubblewrap can create a
network namespace. Run them in that environment with:

```sh
mise exec -- mix test --include sandbox --exclude cargo
```

The live OpenAI-compatible model test additionally requires `--include
local_model`, `OMUNCULUS_OPENAI_URL`, and `OMUNCULUS_OPENAI_MODEL`.
