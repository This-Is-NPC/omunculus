defmodule Omunculus.Tools.ToolSearchTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Out, ToolSearch}

  @input %{
    name: "tool_search",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  @cards [
    %{name: "write", description: "Writes a file in the workspace.", tags: ["fs.write"]},
    %{name: "read", description: "Reads a file from the workspace.", tags: ["fs.read"]},
    %{
      name: "compact_comments",
      description: "Clear old comment history.",
      tags: ["compact"]
    }
  ]

  test "no filter lists every card sorted by name" do
    input = %{@input | view: %{"catalog" => @cards}}

    assert ToolSearch.run(input) == %{
             "ok" => true,
             "output" =>
               "- compact_comments: Clear old comment history. [compact]\n" <>
                 "- read: Reads a file from the workspace. [fs.read]\n" <>
                 "- write: Writes a file in the workspace. [fs.write]",
             "emit" => []
           }
  end

  test "q matches the name case-insensitively" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "WRITE"}}

    assert ToolSearch.run(input)["output"] ==
             "- write: Writes a file in the workspace. [fs.write]"
  end

  test "q matches the description case-insensitively" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "clear old"}}

    assert ToolSearch.run(input)["output"] ==
             "- compact_comments: Clear old comment history. [compact]"
  end

  test "q matches a tag case-insensitively" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "FS.READ"}}
    assert ToolSearch.run(input)["output"] == "- read: Reads a file from the workspace. [fs.read]"
  end

  test "tags requires every listed tag to be present" do
    cards = [
      %{name: "a", description: "a", tags: ["x", "y"]},
      %{name: "b", description: "b", tags: ["x"]}
    ]

    input = %{@input | view: %{"catalog" => cards}, args: %{"tags" => ["x", "y"]}}
    assert ToolSearch.run(input)["output"] == "- a: a [x, y]"
  end

  test "q and tags combine" do
    input = %{
      @input
      | view: %{"catalog" => @cards},
        args: %{"q" => "file", "tags" => ["fs.write"]}
    }

    assert ToolSearch.run(input)["output"] ==
             "- write: Writes a file in the workspace. [fs.write]"
  end

  test "nothing found" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "does not exist at all"}}

    assert ToolSearch.run(input) == %{
             "ok" => true,
             "output" => Out.no_tools_found(),
             "emit" => []
           }
  end

  test "view absent yields the same message" do
    assert ToolSearch.run(@input) == %{
             "ok" => true,
             "output" => Out.no_tools_found(),
             "emit" => []
           }
  end

  test "the builtin catalog discovers tool_search in the catalog group" do
    catalog = Catalog.unconfigured()

    assert %{"tool_search" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["catalog"]
    assert manifest.views == ["catalog"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "tool_search")
    input = %{@input | view: %{"catalog" => @cards}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == ToolSearch.run(input)["output"]
  end
end
