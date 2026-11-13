defmodule Omunculus.Tools.ProcessTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Fixtures, ProcessFixtures, Store}
  alias Omunculus.Tools.Process, as: ProcessTool

  setup %{conn: conn} do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, ProcessFixtures.config())
    Map.merge(ProcessFixtures.seed(conn), %{config_path: Fixtures.config_path(dir)})
  end

  defp call(ctx, args) do
    {:ok, raw} = Store.log(ctx.conn, args["last"])
    ProcessTool.run(%{args: args, view: %{"log" => raw}, config_path: ctx.config_path})
  end

  defp output(ctx, args) do
    assert %{"ok" => true, "output" => output} = call(ctx, args)
    output
  end

  test "it reports fitness and the deviations of each kind, with their cases", ctx do
    output = output(ctx, %{})

    assert output =~ "fitness 0.50 (4 of 8 works follow them)"
    assert output =~ "- skipped stage: 1 work"
    assert output =~ "- repeated stage: 1 work"
    assert output =~ "- out of order: 1 work"
    assert output =~ "- ended outside its last stage: 1 work"
    assert output =~ "work #{ctx.works.skipped} (conversation #{hd(ctx.conversations)}, runs "
    assert output =~ "(to_do before review)"
  end

  test "it names the variants, the activities and what they cost", ctx do
    output = output(ctx, %{})

    assert output =~
             "- 3 works: enter to_do > read > write > bash > continue > enter review > read > continue > work done"

    assert output =~ "- read: 11 times, mean 1.0 s, p90 1.0 s"
    assert output =~ "- bash: 6 times"
    assert output =~ "1 refused"
    assert output =~ "- model reply: 17 times"
    assert output =~ "$7.1000"
  end

  test "workflow and last narrow the works", ctx do
    assert output(ctx, %{"last" => 1}) =~ "3 works in the last 1 conversations"
    assert output(ctx, %{"workflow" => "delivery"}) =~ "8 works of workflow delivery"
  end

  test "without thresholds it says the rules were not mined", ctx do
    assert output(ctx, %{}) =~ "Rules: not mined; give support and confidence"
  end

  test "with thresholds it gives the rules and the cancelled works that break them", ctx do
    output = output(ctx, %{"support" => 0.6, "confidence" => 0.9})

    assert output =~
             "Rules of the works that ended done (support >= 0.6, confidence >= 0.9; 1 work cancelled)"

    assert output =~
             "- response(write, bash): support 0.80, confidence 1.00, broken by 1 of 1 cancelled works"

    assert output =~ "work #{ctx.works.cancelled} (conversation "
  end

  test "support and confidence come together, from 0 to 1", ctx do
    assert %{"ok" => false} = call(ctx, %{"support" => 0.5})
    assert %{"ok" => false} = call(ctx, %{"confidence" => 0.5})
    assert %{"ok" => false} = call(ctx, %{"support" => 2, "confidence" => 0.5})
  end

  test "an unknown workflow and a last that is not a count are refused", ctx do
    assert %{"ok" => false, "output" => "no workflow nope in the config"} =
             call(ctx, %{"workflow" => "nope"})

    assert %{"ok" => false} = call(ctx, %{"last" => 0})
  end

  test "bpmn gives the workflow as the config declares it, or as the works went", ctx do
    assert %{"ok" => true, "output" => to_be} =
             call(ctx, %{"workflow" => "delivery", "bpmn" => "to-be"})

    assert to_be =~ "name=\"to_do (worker)\""
    assert to_be =~ "<bpmndi:BPMNDiagram"

    assert %{"ok" => true, "output" => as_is} =
             call(ctx, %{"workflow" => "delivery", "bpmn" => "as-is"})

    assert as_is =~ "name=\"to_do (9)\""
    assert as_is =~ "exclusiveGateway"
  end

  test "bpmn needs a workflow, and a work that went through it", ctx do
    assert %{"ok" => false, "output" => "bpmn needs a workflow"} = call(ctx, %{"bpmn" => "to-be"})

    assert %{"ok" => false, "output" => "bpmn is as-is or to-be"} =
             call(ctx, %{"workflow" => "delivery", "bpmn" => "x"})

    {:ok, empty} = Store.open(":memory:")
    {:ok, raw} = Store.log(empty, nil)

    assert %{"ok" => false, "output" => "no work went through delivery in the log"} =
             ProcessTool.run(%{
               args: %{"workflow" => "delivery", "bpmn" => "as-is"},
               view: %{"log" => raw},
               config_path: ctx.config_path
             })
  end

  test "an empty log has nothing to report", ctx do
    {:ok, empty} = Store.open(":memory:")
    {:ok, raw} = Store.log(empty, nil)

    assert %{"ok" => true, "output" => output} =
             ProcessTool.run(%{args: %{}, view: %{"log" => raw}, config_path: ctx.config_path})

    assert output =~ "0 works"
    assert output =~ "Variants: none."
    assert output =~ "Activities: none."
  end

  test "with a workflow every section is of its works and the works below them, nothing else",
       ctx do
    [conversation | _] = ctx.conversations
    # A descendant of a delivery work, another workflow's work, and a root
    # system run of no workflow, each with a call of its own.
    ProcessFixtures.extra_work(ctx.conn, conversation, nil, ctx.works.done_a, [
      {:run, "worker"},
      {:model, 0.0, 1},
      {:tool, "below", 1}
    ])

    ProcessFixtures.extra_work(ctx.conn, conversation, "other", nil, [
      {:run, "worker"},
      {:model, 0.0, 1},
      {:tool, "elsewhere", 1}
    ])

    ProcessFixtures.extra_work(ctx.conn, conversation, nil, nil, [
      {:run, "steward"},
      {:model, 0.0, 1},
      {:tool, "config", 1},
      {:refused, "propose_config", 1}
    ])

    scoped = output(ctx, %{"workflow" => "delivery", "support" => 0.1, "confidence" => 0.1})
    assert scoped =~ "- below: 1 times"
    assert scoped =~ "- read: 11 times"
    for outside <- ["elsewhere", "config", "propose_config"], do: refute(scoped =~ outside)

    all = output(ctx, %{})
    for inside <- ["below", "elsewhere", "config", "propose_config"], do: assert(all =~ inside)
  end
end
