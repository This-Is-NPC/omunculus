Code.require_file("../../eval/lib/project.ex", __DIR__)

defmodule Omunculus.EvalOndemandTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Ceiling, Config, Fixtures}
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.{Out, ToolSearch}

  @overlay Path.expand("../../eval/overlays/improvements.toml", __DIR__)

  setup_all do
    {:ok, path} =
      EquivalentExchange.Project.build(
        Fixtures.tmp_dir(),
        "agency",
        {"fake", false},
        nil,
        %{},
        @overlay
      )

    {:ok, config} = Config.load(path)
    catalog = config.tools |> Catalog.discover() |> Catalog.with_trigger("model")
    %{config: config, catalog: catalog}
  end

  # What a run of `agent` at `stage` calls: its names, which of them it is
  # declared, and the catalog cards `tool_search` reads.
  defp run_view(config, catalog, agent, stage) do
    snapshot =
      Ceiling.mount(
        config,
        %{
          agent: agent,
          depth: config.agents[agent].depth,
          grants: [],
          stage: stage,
          workspace: Config.workspace_ceiling(config, nil),
          groups: Catalog.groups(catalog)
        },
        Map.keys(catalog)
      )

    names = snapshot.have |> Enum.filter(&Map.has_key?(catalog, &1)) |> Enum.sort()
    declared = Ceiling.declared(snapshot.pinned, names)

    cards =
      for name <- names do
        manifest = catalog[name]

        manifest
        |> Map.take([:name, :description, :tags, :groups, :parameters])
        |> Map.put(:pinned, name in declared)
      end

    {names, declared, cards}
  end

  defp stages(config) do
    for {_workflow, steps} <- config.workflows, step <- steps, do: {step.agent, step.ceiling}
  end

  test "every tool an agent may call is pinned or found by its own name", ctx do
    %{config: config, catalog: catalog} = ctx
    runs = for {agent, _} <- config.agents, do: {agent, nil}
    runs = Enum.uniq(runs ++ stages(config))

    for {agent, stage} <- runs do
      {names, declared, cards} = run_view(config, catalog, agent, stage)
      assert Enum.all?(declared, &(&1 in names))

      for name <- names, name not in declared do
        assert "tool_search" in declared, "#{agent} cannot search for #{name}"
        out = ToolSearch.run(%{args: %{"q" => name}, view: %{"catalog" => cards}})["output"]
        cut = Out.cut(out, config.tool_output_bytes)
        assert name in ToolSearch.found(cut), "#{agent} does not find #{name}"
      end
    end
  end

  test "the project manager finds proposal at the design stage", ctx do
    %{config: config, catalog: catalog} = ctx
    stage = Enum.find(config.workflows["engagement"], &(&1.name == "design"))
    {names, declared, cards} = run_view(config, catalog, "project-manager", stage.ceiling)

    assert "proposal" in names
    refute "proposal" in declared
    out = ToolSearch.run(%{args: %{"q" => "proposal"}, view: %{"catalog" => cards}})["output"]
    assert "proposal" in ToolSearch.found(out)
  end
end
