defmodule Omunculus.Tools.ToolSearchTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.ToolSearch

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
    %{name: "write", description: "Escreve um arquivo no workspace.", tags: ["fs.write"]},
    %{name: "read", description: "Lê um arquivo do workspace.", tags: ["fs.read"]},
    %{
      name: "compact_comments",
      description: "Limpar histórico de comments antigos.",
      tags: ["compact"]
    }
  ]

  test "no filter lists every card sorted by name" do
    input = %{@input | view: %{"catalog" => @cards}}

    assert ToolSearch.run(input) == %{
             "ok" => true,
             "output" =>
               "- compact_comments: Limpar histórico de comments antigos. [compact]\n" <>
                 "- read: Lê um arquivo do workspace. [fs.read]\n" <>
                 "- write: Escreve um arquivo no workspace. [fs.write]",
             "emit" => []
           }
  end

  test "q matches the name case-insensitively" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "WRITE"}}

    assert ToolSearch.run(input)["output"] ==
             "- write: Escreve um arquivo no workspace. [fs.write]"
  end

  test "q matches the description case-insensitively" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "limpar histórico"}}

    assert ToolSearch.run(input)["output"] ==
             "- compact_comments: Limpar histórico de comments antigos. [compact]"
  end

  test "q matches a tag case-insensitively" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "FS.READ"}}
    assert ToolSearch.run(input)["output"] == "- read: Lê um arquivo do workspace. [fs.read]"
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
        args: %{"q" => "arquivo", "tags" => ["fs.write"]}
    }

    assert ToolSearch.run(input)["output"] ==
             "- write: Escreve um arquivo no workspace. [fs.write]"
  end

  test "nothing found" do
    input = %{@input | view: %{"catalog" => @cards}, args: %{"q" => "nada disso existe"}}

    assert ToolSearch.run(input) == %{
             "ok" => true,
             "output" => "nenhuma tool encontrada",
             "emit" => []
           }
  end

  test "view absent yields the same message" do
    assert ToolSearch.run(@input) == %{
             "ok" => true,
             "output" => "nenhuma tool encontrada",
             "emit" => []
           }
  end

  test "the builtin catalog discovers tool_search in the catalog group" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"tool_search" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["catalog"]
    assert manifest.views == ["catalog"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "tool_search")
    input = %{@input | view: %{"catalog" => @cards}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == ToolSearch.run(input)["output"]
  end
end
