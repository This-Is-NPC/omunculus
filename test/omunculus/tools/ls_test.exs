defmodule Omunculus.Tools.LsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Ls

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "b.txt"), "b")
    File.write!(Path.join(root, "a.txt"), "a")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "ls",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "lists the default path sorted, directories suffixed with /", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Ls.run(input) == %{
             "ok" => true,
             "output" => "a.txt\nb.txt\nsub/",
             "emit" => []
           }
  end

  test "lists a given path", %{root: root} do
    input = %{@input | args: %{"path" => "sub"}, roots: [root]}

    assert Ls.run(input) == %{"ok" => true, "output" => "", "emit" => []}
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"path" => "../escape"}, roots: [root]}

    assert Ls.run(input) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape",
             "emit" => []
           }
  end

  test "no path is required, defaults to \".\"", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert %{"ok" => true} = Ls.run(input)
  end

  test "reports a missing directory", %{root: root} do
    input = %{@input | args: %{"path" => "missing"}, roots: [root]}

    assert Ls.run(input) == %{
             "ok" => false,
             "output" => "no such directory: missing",
             "emit" => []
           }
  end

  test "the builtin catalog discovers ls with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"ls" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.read"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "ls")
    input = %{@input | args: %{}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Ls.run(input)["output"]
  end
end
