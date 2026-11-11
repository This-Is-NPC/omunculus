# How to measure course recovery

**The question:** how do I measure whether the steward recovers a stalled
permission cycle while the front desk stays the one that asks the client?

This page is enough on its own when you already hold a saved copy of a
stalled store. It measures one coordination checkpoint, not the full task's
acceptance or deployment. What the steward overlay changes is in
[the design](design.md#9-what-was-measured); the pack is
[course-recovery](../packs/course-recovery/README.md).

## Before you start

- A checkout with `mise install` and `mix deps.get` run in it
  ([the design](design.md#8-building-and-checking)).
- In `.env`, the keys of the providers whose models the source result's
  manifest and `eval/overlays/course-recovery.toml` name
  ([how to log in to a provider](how-to-log-in-to-a-provider.md)).
- A source result folder of a design-to-build run under the agency
  configuration of [Equivalent Exchange](../eval/README.md). It needs its
  `manifest.json`, the workspace of the execution at
  `executions/design-team__conversation__design-to-build/agency/1/project`,
  and `run-context/coordination-loop-at-cancellation.sqlite3`. That path is
  fixed in `eval/lib/recovery.ex`.
- The store copy must be taken under the current schema: a store from before
  accounts replaced request routes is refused when the project opens.
- No code writes `coordination-loop-at-cancellation.sqlite3`. It is a copy of
  the execution's store, taken by hand while the run was stalled in the
  cycle seen before escalation skipped agents that had answered the origin with text,
  before it was cancelled.
- `<result-folder>` below is a placeholder for that source folder. The source
  is only read.

## Steps

1. Check the correction and isolation contracts:

   ```console
   $ mise run eval:recovery:check
   [eval:recovery:check] $ scripts/check-course-recovery
   running 10 tests from ./packs/course-recovery/tools/_recovery/recovery_test.js
   a correction is an internal linked escalation, never a grant or client prompt ... ok (317µs)
   the supervisor must hold the pending canonical request ... ok (56µs)
   cross-conversation requests, other callers and resolved origins are refused ... ok (106µs)
   evidence includes only events from the current conversation ... ok (117µs)
   direct CLI projects without a conversation ID retain project-local request scope ... ok (69µs)
   routing facts, agent claims and delivery receipts are separate ... ok (120µs)
   unsupported pending-client claims are refused without effects and can be revised ... ok (135µs)
   canonical client receipts outside the recent window are accepted ... ok (7ms)
   closed, foreign, unrelated and non-front-desk receipts are refused ... ok (2ms)
   corrections require a successful evidence read and canonical origin citations ... ok (213µs)

   ok | 10 passed | 0 failed (19ms)
   ```

2. Replay isolated copies of the checkpoint, with and without the overlay:

   ```sh
   mise run eval:recovery --source <result-folder> --overlay eval/overlays/course-recovery.toml --k 5 --budget 20
   ```

   The output is not reproduced here: the replay needs a saved checkpoint
   and a provider, and neither is part of the tree.

   `--k` is the number of trials per arm (3 by default). `--budget` is the
   number of recorded model responses a trial may make (20 by default).
   Each trial prints a line: its arm, its number, its outcome, its model
   responses, its provider cost in USD and its seconds. Trials alternate
   which arm runs first. The outcome is `recovered`,
   `response_budget_exhausted` or `worker_exit_<code>`. The last line is
   the new result folder under `eval/results/`. It holds `manifest.json`,
   `summary.json`, `report.md`, and one folder per trial with its
   `omunculus.toml`, `events.jsonl`, `worker.log` and `metrics.json`.
   Trial projects and their processes are removed when the trial ends.

3. Read `report.md`. A trial recovers when `front-desk` authors a new question
   whose linked origins include the original unresolved permission. No
   client answer or production grant is executed. Compare the outcomes,
   response counts, costs and times of the two arms.

## What can go wrong

- `source needs its frozen cancellation snapshot`: the source folder has no
  `run-context/coordination-loop-at-cancellation.sqlite3`.
- A `worker_exit_*` outcome without the expected client request is a failed
  recovery or an execution error. Read that trial's worker log and events.
  The worker's exit code alone is not success.
- A trial that runs out of its budget is censored: recovery was not seen
  within that many responses. It says nothing about how long a model may
  take.
- Cold sessions and provider caching can change the measurements.

## Where to go next

To run the whole design-to-build task with the overlay, pass
`--overlay eval/overlays/course-recovery.toml` to `mise run eval:run`, as
[the eval guide](../eval/README.md) describes. That run keeps the original
task, simulated person, permission decisions and acceptance checks; its
result is separate from the checkpoint measurement above.
