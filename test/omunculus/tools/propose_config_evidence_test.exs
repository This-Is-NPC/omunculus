defmodule Omunculus.Tools.ProposeConfigEvidenceTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Artifacts, Config, Fixtures, ProcessFixtures, Store}
  alias Omunculus.Tool.Views
  alias Omunculus.Tools.ProposeConfig

  @evidence %{
    "metric" => "fitness of delivery",
    "before" => 0.5,
    "expected" => 0.9,
    "workflow" => "delivery"
  }

  @value %{
    "steps" => [
      %{"name" => "to_do", "agent" => "worker"},
      %{"name" => "review", "agent" => "reviewer", "deny" => ["write", "bash"]}
    ]
  }

  setup %{conn: conn} do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, ProcessFixtures.config())
    ProcessFixtures.seed(conn)
    %{path: Fixtures.config_path(dir)}
  end

  # The log as the tool's manifest declares it, read for the call's own args.
  defp propose(ctx, args, artifacts \\ []) do
    args = Map.merge(%{"item" => "workflows.delivery", "value" => @value, "reason" => "r"}, args)
    {:ok, specs} = Views.parse(%{"log" => %{"source" => "log"}})

    scope = %{
      run_id: nil,
      work_id: nil,
      request_id: nil,
      inbox_id: nil,
      prompt_id: nil,
      args: args,
      computed: %{}
    }

    {:ok, view} = Views.hydrate(ctx.conn, specs, scope)

    ProposeConfig.run(%{
      config_path: ctx.path,
      args: args,
      view: Map.put(view, "artifacts", artifacts)
    })
  end

  test "evidence writes the BPMN pair as artifacts, before the request", ctx do
    assert %{"ok" => true, "emit" => [as_is, to_be, request]} =
             propose(ctx, %{"evidence" => @evidence})

    assert %{
             "type" => "artifact",
             "body" => %{"name" => "delivery-as-is.bpmn", "kind" => "bpmn"} = body
           } = as_is

    assert body["media_type"] == "application/bpmn+xml"
    assert body["content"] =~ "<bpmndi:BPMNDiagram"
    assert body["content"] =~ "to_do (9)"

    assert %{
             "type" => "artifact",
             "body" => %{"name" => "delivery-to-be.bpmn", "content" => content}
           } = to_be

    assert content =~ "the stage denies: bash, write"
    assert content =~ "agent: reviewer"

    assert %{"type" => "request", "body" => %{"reason" => reason}} = request

    assert reason =~
             "Evidence: the metric is fitness of delivery, 0.5 now, expected 0.9 after this change."

    assert reason =~ "- delivery-as-is.bpmn version 1: as-is, mined from the log"
    assert reason =~ "- delivery-to-be.bpmn version 1: to-be, as the config would declare it"
  end

  test "the to-be is the workflow as the change would leave it, the as-is as the works went",
       ctx do
    %{"emit" => [%{"body" => as_is}, %{"body" => to_be} | _]} =
      propose(ctx, %{"evidence" => @evidence})

    refute as_is["content"] =~ "bash, write"
    assert to_be["content"] =~ "bash, write"

    {:ok, config} = Config.load(ctx.path)

    refute Omunculus.Process.Bpmn.to_be("delivery", config.workflows["delivery"], config.agents) =~
             "bash, write"
  end

  test "the artifacts of a proposal with the same evidence are not written again", ctx do
    %{"emit" => [%{"body" => as_is}, %{"body" => to_be}, _]} =
      propose(ctx, %{"evidence" => @evidence})

    {:ok, config} = Config.load(ctx.path)

    versions =
      for body <- [as_is, to_be] do
        {:ok, meta} =
          Artifacts.put(config.store, body["name"], "bpmn", body["media_type"], body["content"])

        Map.merge(meta, %{"kind" => "bpmn", "version" => 1})
      end

    assert %{"ok" => true, "emit" => [%{"type" => "request", "body" => %{"reason" => reason}}]} =
             propose(ctx, %{"evidence" => @evidence}, versions)

    assert reason =~ "- delivery-as-is.bpmn version 1:"
  end

  test "without evidence the request is as it was", ctx do
    assert %{"ok" => true, "emit" => [%{"type" => "request", "body" => %{"reason" => reason}}]} =
             propose(ctx, %{})

    refute reason =~ "Evidence"
  end

  test "evidence needs its metric, its values and a workflow", ctx do
    for bad <- [
          Map.delete(@evidence, "metric"),
          Map.delete(@evidence, "before"),
          Map.delete(@evidence, "expected")
        ] do
      assert %{
               "ok" => false,
               "output" => "evidence needs a metric (text) and its before and expected values"
             } =
               propose(ctx, %{"evidence" => bad})
    end

    assert %{"ok" => false, "output" => "evidence needs the workflow its BPMN pair shows"} =
             propose(ctx, %{"evidence" => Map.delete(@evidence, "workflow")})

    assert %{"ok" => false, "output" => "evidence is a table: metric, before, expected, workflow"} =
             propose(ctx, %{"evidence" => "better"})
  end

  test "evidence names a workflow the config has, that works went through", ctx do
    assert %{
             "ok" => false,
             "output" => "evidence names workflow nope, which the config would not have"
           } =
             propose(ctx, %{"evidence" => %{@evidence | "workflow" => "nope"}})

    {:ok, empty} = Store.open(":memory:")
    {:ok, raw} = Store.log(empty, nil)

    assert %{
             "ok" => false,
             "output" =>
               "no work went through delivery in the log, so there is no as-is to attach"
           } =
             ProposeConfig.run(%{
               config_path: ctx.path,
               args: %{
                 "item" => "workflows.delivery",
                 "value" => @value,
                 "reason" => "r",
                 "evidence" => @evidence
               },
               view: %{"log" => raw}
             })
  end

  test "last limits the log the as-is is mined from", ctx do
    %{"emit" => [%{"body" => as_is} | _]} =
      propose(ctx, %{"evidence" => Map.put(@evidence, "last", 1)})

    assert as_is["content"] =~ "to_do (5)"
  end
end
