defmodule Omunculus.Tools.FindTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Find

  setup do
    parent = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    root = Path.join(parent, "root")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "a.txt"), "a")
    File.write!(Path.join(root, "sub/b.txt"), "b")
    File.write!(Path.join(parent, "outside.txt"), "outside")
    on_exit(fn -> File.rm_rf!(parent) end)
    %{root: root, parent: parent}
  end

  @input %{
    name: "find",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "matches a wildcard pattern under the default path", %{root: root} do
    input = %{@input | args: %{"pattern" => "**/*.txt"}, roots: [root]}

    assert Find.run(input) == %{
             "ok" => true,
             "output" => "a.txt\nsub/b.txt",
             "emit" => []
           }
  end

  test "drops results that escape the roots via ..", %{root: root} do
    input = %{@input | args: %{"pattern" => "../*.txt"}, roots: [root]}

    assert Find.run(input) == %{"ok" => true, "output" => "", "emit" => []}
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"pattern" => "*.txt", "path" => "../escape"}, roots: [root]}

    assert Find.run(input) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape",
             "emit" => []
           }
  end

  test "refuses without a pattern", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Find.run(input) == %{"ok" => false, "output" => "pattern required", "emit" => []}
  end

  test "the builtin catalog discovers find with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"find" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.read"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "find")
    input = %{@input | args: %{"pattern" => "*.txt"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Find.run(input)["output"]
  end
end
