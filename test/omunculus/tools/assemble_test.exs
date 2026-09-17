defmodule Omunculus.Tools.AssembleTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Assemble, Out}

  @input %{
    name: "assemble",
    args: %{"text" => "You are the concierge."},
    view: %{"catalog" => []},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "joins agent text, message and every catalog card" do
    view = %{
      "prompt" => %{body: "count to 5"},
      "catalog" => [
        %{name: "break", description: "Stops the stage.", tags: [], groups: ["sequence"]}
      ]
    }

    output = Assemble.run(%{@input | view: view})["output"]
    assert output =~ "You are the concierge."
    assert output =~ "## Message\ncount to 5"
    assert output =~ Out.tools_preamble()
    assert output =~ "- break: Stops the stage."
  end

  test "with tool_search and more than 12 cards keeps store/sequence/catalog" do
    cards =
      for i <- 1..13 do
        name = if i == 1, do: "tool_search", else: "t#{i}"
        groups = if i <= 3, do: ["store"], else: ["fs.read"]
        %{name: name, description: name, tags: [], groups: groups}
      end

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- tool_search:"
    assert output =~ Out.more_tools(10)
    refute output =~ "- t4:"
  end

  test "the builtin catalog discovers assemble with triggers == [\"harness\"]" do
    catalog = Catalog.unconfigured()
    assert %{"assemble" => manifest} = catalog
    assert manifest.triggers == ["harness"]
    assert "catalog" in manifest.views
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "assemble")
    assert {:ok, result} = Invoke.call(manifest, @input)
    assert result.output == Assemble.run(@input)["output"]
  end
end
