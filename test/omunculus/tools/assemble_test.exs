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

  test "without pinned every catalog card is listed even past 12" do
    cards =
      for i <- 1..13 do
        name = if i == 1, do: "tool_search", else: "t#{i}"
        %{name: name, description: name, tags: [], groups: [], pinned: true}
      end

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- tool_search:"
    assert output =~ "- t4:"
    assert output =~ "- t13:"
    refute output =~ Out.more_tools(1)
  end

  test "with tool_search, unpinned cards collapse behind more_tools" do
    cards = [
      %{name: "tool_search", description: "search", tags: [], groups: ["catalog"], pinned: true},
      %{name: "comment", description: "note", tags: [], groups: ["store"], pinned: true},
      %{name: "read", description: "read", tags: [], groups: ["fs.read"], pinned: false}
    ]

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- tool_search:"
    assert output =~ "- comment:"
    refute output =~ "- read:"
    assert output =~ Out.more_tools(1)
  end

  test "without tool_search, pinned is ignored and every card is listed" do
    cards = [
      %{name: "comment", description: "note", tags: [], groups: ["store"], pinned: true},
      %{name: "read", description: "read", tags: [], groups: ["fs.read"], pinned: false}
    ]

    output = Assemble.run(%{@input | view: %{"catalog" => cards}})["output"]
    assert output =~ "- comment:"
    assert output =~ "- read:"
    refute output =~ "more tools"
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
