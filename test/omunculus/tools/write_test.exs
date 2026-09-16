defmodule Omunculus.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Write

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "write",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "writes a file inside the root, creating parent dirs", %{root: root} do
    input = %{
      @input
      | args: %{"path" => "nested/dir/file.txt", "content" => "hi"},
        roots: [root]
    }

    assert Write.run(input) == %{"ok" => true, "output" => "", "emit" => []}
    assert File.read!(Path.join(root, "nested/dir/file.txt")) == "hi"
  end

  test "overwrites an existing file", %{root: root} do
    File.write!(Path.join(root, "file.txt"), "old")
    input = %{@input | args: %{"path" => "file.txt", "content" => "new"}, roots: [root]}

    assert Write.run(input) == %{"ok" => true, "output" => "", "emit" => []}
    assert File.read!(Path.join(root, "file.txt")) == "new"
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"path" => "../escape.txt", "content" => "hi"}, roots: [root]}

    assert Write.run(input) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape.txt",
             "emit" => []
           }
  end

  test "refuses without content", %{root: root} do
    input = %{@input | args: %{"path" => "file.txt"}, roots: [root]}

    assert Write.run(input) == %{"ok" => false, "output" => "content required", "emit" => []}
  end

  test "refuses without a path", %{root: root} do
    input = %{@input | args: %{"content" => "hi"}, roots: [root]}

    assert Write.run(input) == %{"ok" => false, "output" => "path required", "emit" => []}
  end

  test "the builtin catalog discovers write with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"write" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.write"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "write")
    input = %{@input | args: %{"path" => "wired.txt", "content" => "hi"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Write.run(input)["output"]
  end
end
