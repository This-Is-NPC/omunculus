defmodule Omunculus.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Read

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    File.write!(Path.join(root, "file.txt"), "hello\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "read",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "reads a file inside the root", %{root: root} do
    input = %{@input | args: %{"path" => "file.txt"}, roots: [root]}

    assert Read.run(input) == %{"ok" => true, "output" => "hello\n", "emit" => []}
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"path" => "../escape.txt"}, roots: [root]}

    assert Read.run(input) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape.txt",
             "emit" => []
           }
  end

  test "refuses without a path", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Read.run(input) == %{"ok" => false, "output" => "path required", "emit" => []}
  end

  test "reports a missing file", %{root: root} do
    input = %{@input | args: %{"path" => "missing.txt"}, roots: [root]}

    assert Read.run(input) == %{
             "ok" => false,
             "output" => "no such file: missing.txt",
             "emit" => []
           }
  end

  test "the builtin catalog discovers read with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"read" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.read"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "read")
    input = %{@input | args: %{"path" => "file.txt"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Read.run(input)["output"]
  end
end
