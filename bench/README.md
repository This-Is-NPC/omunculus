# Linear resident-agent benchmark

One run per hardware profile. The driver adds **one agent at a time**, keeps
all earlier ones alive and continues until OOM, an agent error, a startup hang
or process termination. There is no concurrency doubling, binary search,
per-point restart or p95 rejection.

| Profile | Aggregate CPU quota | RAM | Swap |
|---|---:|---:|---:|
| A | 100% (equivalent to 1 CPU) | 512 MiB | 0 |
| B | 200% (equivalent to 2 CPUs) | 1 GiB | 0 |

Pinned CPUs are optional (`--pin-cpus`). By default, the host scheduler picks
the available CPUs and the cgroup limits the aggregate processing time.

## Run

In a host terminal, inside the repository:

```sh
mise run benchmark:build
mise run benchmark:check
mise run benchmark:run
```

The last command runs A until it fails, cleans up its processes and runs B until
it fails. It uses the user systemd instance and delegation of `cpu`, `memory` and
`pids`; it only requires `cpuset` if `--pin-cpus` is requested. It does not change
the host configuration.

```sh
# Change only the linear cadence (one agent per minimum interval):
mise run benchmark:run --interval-ms 50

# 1 MiB of context per agent, instead of the default 64 KiB:
mise run benchmark:run --context-bytes 1048576

# Bounded functional test; not a measurement of the ceiling:
mise run benchmark:run --max-agents 3

# Regenerate the report:
mise run benchmark:report
```

The step is always 1. The default interval is 100 ms; the next creation also
waits for the previous one to mount its run. This way, a queue of requests not
yet started does not become a false count of resident agents. `--max-agents`
exists only for short verification; without it, the run continues until failure.

## What is measured

The driver is Elixir and calls the real `Project.open`, `Run.open`, context
assembly, permissions, persistence and OpenAI client. Each agent has its own
materialized context and its own SQLite connection, and shares the
database/workspace with the others. Admission is serialized until the run is
mounted; agents already admitted stay alive simultaneously, waiting on the model.

The simulated model is **the Rust stub from master**, copied unchanged from
`priv/benchmark_stub` at `3a484b6`; see [provenance](stub/PROVENANCE.md).
Its response is delayed by 24 hours, keeping the calls in flight during the
ramp. The client timeout is longer than that wait. The collector confirms
residency by cross-checking mounted runs against the real peak of concurrent
HTTP requests at the stub.

The benchmark driver's HTTP pool is explicitly configured for 65,536
connections, opened on demand, so the default of 50 connections does not
replace the hardware limit. This does not change the production client. FD/PID
limits inherited from the host are still recorded and may be the cause of failure.

The launcher/collector is also **Rust**. There is no Python in this benchmark.
The stub and collector are outside the budget; BEAM and its descendants enter
the cgroup before exec. CPU, memory, swap and ancestor limits are verified. The
collector survives the OOM to keep evidence and terminate only the group it
created. The release and the Rust binaries are built before measuring.

This is the observed ceiling of **resident agents waiting on the model**, not a
measurement of throughput or of hundreds of commands running simultaneously.
This number should not be generalized to agents running Python, Deno or heavy
CLIs. The database, page cache and all BEAM memory count against the budget.

## Results

`bench/results/` holds only the latest run and is gitignored.
A new run replaces that result. To keep a separate measurement, pass
`--output NEW_DIRECTORY` explicitly.
Binaries and build caches live in `_build/bench/native/`.

Measurement files:

- `manifest.json`: versions, hardware, inherited limits and parameters.
- `A/config.json` and `B/config.json`: configuration of each driver.
- `A/agents.ndjson` and `B/agents.ndjson`: linear creation/mount sequence.
- `A/samples.ndjson` and `B/samples.ndjson`: cgroup and stub every 250 ms.
- `A/result.json` and `B/result.json`: last confirmed number and stop reason.
- `summary.csv` and `report.md`: comparison of the two budgets.

The synthetic workspaces are discarded after each profile. Logs and samples
remain. `oom` is a budget failure; `agent_error` identifies a harness failure;
`exploration_limit` is an explicit test limit, not the machine's ceiling.
The last confirmed number is conservative due to the sampling interval.

The mount timeout for one agent is 30 seconds. This records a hang instead of
waiting indefinitely without adding agents. A user interruption is recorded as
an interruption, never as capacity.
