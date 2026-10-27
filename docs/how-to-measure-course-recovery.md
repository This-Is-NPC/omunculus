# Measure experimental steward recovery

**The question:** Can the steward recover an internal request loop while
keeping the front desk responsible for client content? This page is enough
when a frozen hybrid result already exists. It measures the coordination
checkpoint, not the full site's acceptance or deployment.

## Before you start

Use the configured Anthropic credentials in `.env`. A source result must have
`run-context/coordination-loop-at-cancellation.sqlite3`, its manifest and its
execution workspace. The source is read only. `<result-folder>` below is a
placeholder for that folder.

The experimental pack is [course-recovery](../packs/course-recovery/README.md).
The existing system pack supplies the steward. The overlay restricts its
operational tools and adds the course-correction skill. No core module changes.
The overlay selects the configured `haiku` model for this steward.

Normal `ask`, `request_access` and `escalate` tools select named question routes.
Private chain steps run their original builtin modules, preserving argument
validation, grants and end behavior. A front-desk model escalation alone
selects the client route. The unnamed route used by the harness fallback goes
to the steward. It cannot deliver a raw fallback to the client.

The steward reads the skill and `recovery_case`, then uses `correct_course`
to escalate corrective instructions and the original permission envelope back
to the front desk. The front desk writes the client question. Neither the
skill nor the correction tool grants permission or changes configuration.

`recovery_case` separates the canonical origin map, recorded routing events and
agent claims. Its recent window is not complete history. A claim that the
client was asked needs an explicit canonical request receipt: a pending human
request from the front desk, linked to the original permissions, with its
recorded event ID. Supply `client_request_id` to inspect that receipt even
when it is outside the recent window.

`correct_course` requires a successful evidence read, cited origin event IDs
and a `client_delivery` classification. `pending` requires a verified receipt;
`unverified` must not claim that the client is already waiting. A refusal emits
no action and does not end the steward's run, allowing it to revise the claim.
These checks validate structured claims; free-text interpretation by the
steward and front desk is still measured, not guaranteed by those checks.

## Steps

1. Check the routing and isolation contracts:

   ```sh
   mise run eval:recovery:check
   ```

   The current contract suite reports `12 passed | 0 failed`.

2. Compare isolated copies of the same checkpoint:

   ```sh
   mise run eval:recovery --source <result-folder> --overlay eval/overlays/course-recovery.toml --k 5 --budget 20
   ```

   Each trial prints its arm, outcome, recorded model responses, provider USD
   and seconds. Trials alternate which arm runs first. The result folder keeps
   the configuration, new events, worker log, metrics, manifest and report.
   Trial projects and their processes are removed when the trial ends.

3. Read the report. Recovery requires a new question authored by `sales` whose
   linked origins include the original unresolved permission. No client answer
   or production grant is executed. Compare success counts, response counts,
   provider cost and time. A response budget bounds only this diagnostic probe;
   it is not an elapsed-time limit or a rejection of slow local inference.

## What can go wrong

A `worker_exit_*` result without the expected client request is a failed
recovery or execution error; inspect its worker log and events. The worker
exit code alone is not success. A response-budget exhaustion is censored: it
says recovery was not observed within that many responses. It says nothing
about how long a model is allowed to take. Cold sessions and provider caching
can influence the measurements. The full hybrid quality eval remains a
separate measurement with unchanged task checks.

## Where to go next

Use [the eval guide](../eval/README.md) for the full task. Enable the overlay
explicitly and put the coordinators on Haiku. The overlay assigns the steward
to Haiku. Keep
`--timeout infinity` and the local model's `timeout_ms = "infinity"`.

To run the complete design-to-build case with the validated recovery pack,
start the deploy environment described in the eval guide, then run these in
separate terminals:

```sh
mise run eval:run -- --model haiku --overlay eval/overlays/course-recovery.toml --configuration agency --task design-to-build --k 1 --jobs 1 --timeout infinity --label recovery-full-haiku
mise run eval:run -- --model local --agent-model sales=haiku --agent-model seller=haiku --agent-model administrator=haiku --agent-model design-lead=haiku --agent-model steward=haiku --agent-model auditor=haiku --agent-model refiner=haiku --overlay eval/overlays/course-recovery.toml --configuration agency --task design-to-build --k 1 --jobs 1 --timeout infinity --label recovery-full-hybrid
```

The overlay removes receive deadlines for both Haiku and the local model.
It forwards `MISE_STATE_DIR` so sandboxed tools use the same trust state when
the runner uses a private mise directory. Sandbox command limits remain configured. Each run has its own store,
workspace and configuration; deployed app names are scoped to its project.
The full case keeps the original task, simulated person, permission decisions,
production mirror and acceptance checks. Its quality result is separate from
the checkpoint recovery measurement above.
