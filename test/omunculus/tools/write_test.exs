defmodule Omunculus.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Write

  setup do
    root = Omunculus.Fixtures.tmp_dir()
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

    assert Write.run(input, policy(input)) == %{"ok" => true, "output" => "", "emit" => []}
    assert File.read!(Path.join(root, "nested/dir/file.txt")) == "hi"
  end

  test "overwrites an existing file", %{root: root} do
    File.write!(Path.join(root, "file.txt"), "old")
    input = %{@input | args: %{"path" => "file.txt", "content" => "new"}, roots: [root]}

    assert Write.run(input, policy(input)) == %{"ok" => true, "output" => "", "emit" => []}
    assert File.read!(Path.join(root, "file.txt")) == "new"
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"path" => "../escape.txt", "content" => "hi"}, roots: [root]}

    assert Write.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape.txt",
             "emit" => []
           }
  end

  test "rejects roots supplied outside the execution policy", %{root: root} do
    outside = Omunculus.Fixtures.tmp_dir()

    input = %{@input | args: %{"path" => "file.txt", "content" => "hi"}, roots: [outside]}

    assert Write.run(input, policy(%{input | roots: [root]})) == %{
             "ok" => false,
             "output" => "path outside roots: file.txt",
             "emit" => []
           }

    refute File.exists?(Path.join(outside, "file.txt"))
  end

  test "says a run without sandbox.write cannot write", %{root: root} do
    input = %{@input | args: %{"path" => "file.txt", "content" => "hi"}, roots: [root]}

    assert Write.run(input, ExecutionPolicyFixtures.policy(input.roots)) == %{
             "ok" => false,
             "output" => "path is not writable: file.txt; writing needs sandbox.write",
             "emit" => []
           }
  end

  test "refuses a read-only path of a writable root", %{root: root} do
    File.mkdir_p!(Path.join(root, "kept"))
    input = %{@input | args: %{"path" => "kept/file.txt", "content" => "hi"}, roots: [root]}

    policy =
      ExecutionPolicyFixtures.policy(input.roots,
        writable: true,
        read_only: [Path.join(root, "kept")]
      )

    assert Write.run(input, policy) == %{
             "ok" => false,
             "output" => "path is not writable: kept/file.txt",
             "emit" => []
           }
  end

  test "refuses without content", %{root: root} do
    input = %{@input | args: %{"path" => "file.txt"}, roots: [root]}

    assert Write.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "content required",
             "emit" => []
           }
  end

  test "refuses without a path", %{root: root} do
    input = %{@input | args: %{"content" => "hi"}, roots: [root]}

    assert Write.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "path required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers write with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"write" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.write"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "write")
    input = %{@input | args: %{"path" => "wired.txt", "content" => "hi"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input, policy(input))
    assert result.output == Write.run(input, policy(input))["output"]
  end

  defp policy(input), do: ExecutionPolicyFixtures.policy(input.roots, writable: true)
end
