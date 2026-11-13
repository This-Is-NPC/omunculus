# How to find what to improve

**The question:** how do I see where the project's works really deviate from the
workflows I declared, and have the refiner propose a change with the numbers and
the diagrams behind it?

This page stands alone for the command line. The refiner does the same through
the `process` tool.

## Before you start

- A project whose `omunculus.toml` loads and has run works through a workflow
  ([how to start a project](how-to-start-a-project.md)).
- For a proposal with diagrams, `[store] attachments`, which artifacts need.
- `<workflow>` is a placeholder for the name of one of your workflows.

## Steps

1. Ask what the works measurably did.

   ```sh
   omunculus process --workflow <workflow>
   ```

   You get the fitness (the share of works that followed the stages you
   declared), the deviations by kind with their works, conversations and runs,
   the most frequent variants and each activity's count, duration, cost and
   refusals. `--last 20` keeps the last twenty conversations.

2. Look for what a gate could enforce. Give both thresholds, numbers from 0 to 1:

   ```sh
   omunculus process --workflow <workflow> --support 0.6 --confidence 0.9
   ```

   A rule that the works that ended done keep and that cancelled works break
   (`broken by 3 of 4 cancelled works`) names a step worth a workflow stage or a
   tool's refusal.

3. Read the cases a number names with `omunculus runs --run <run id>`.

4. See the process. The same command draws it, as BPMN 2.0 on stdout:

   ```sh
   omunculus process --workflow <workflow> --bpmn as-is > as-is.bpmn
   omunculus process --workflow <workflow> --bpmn to-be > to-be.bpmn
   ```

   `as-is` is mined from the works; `to-be` is the workflow as the config
   declares it. Open either in [bpmn.io](https://bpmn.io).

5. Export the log for another tool, as OCEL 2.0 JSON:

   ```sh
   omunculus ocel --out exports/log.json
   ```

   The path is relative to the project's folder.

6. To have the refiner do the work, talk to it:

   ```sh
   omunculus send --agent refiner "Where do the works of <workflow> deviate, and what should change?"
   ```

   It calls `process` first, cites its numbers and cases, and proposes one
   change with `evidence`: the metric the change should move, its value now and
   the value expected. The request shows both. The as-is and to-be BPMN are kept
   as artifacts of the conversation, `<workflow>-as-is.bpmn` and
   `<workflow>-to-be.bpmn`, the to-be as the config would be once you apply the
   change.

## Troubleshooting

- `no work went through <workflow> in the log`: no work of that workflow is in the
  conversations read; drop `--last`, or check the name.
- `support and confidence are numbers from 0 to 1, given together`: give both.
- `the BPMN could not be kept`: the project has no `[store] attachments`, or the
  diagram is over `attachment_bytes`.

## Next

- [Tools](tools.md#process-mining): what `process` measures and how the diagrams are drawn.
- [Requests](requests.md#forms-and-effects): what the person sees in a proposal.
- [The system team](../priv/packs/system/README.md): the refiner and its skill.
