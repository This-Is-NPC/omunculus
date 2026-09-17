defmodule Omunculus.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Edit

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    File.write!(Path.join(root, "file.txt"), "hello world\n")
    File.write!(Path.join(root, "dup.txt"), "same same\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "edit",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "replaces a unique occurrence", %{root: root} do
    input = %{
      @input
      | args: %{"path" => "file.txt", "old" => "world", "new" => "there"},
        roots: [root]
    }

    assert Edit.run(input, policy(input)) == %{"ok" => true, "output" => "", "emit" => []}
    assert File.read!(Path.join(root, "file.txt")) == "hello there\n"
  end

  test "refuses when the old text is not found", %{root: root} do
    input = %{
      @input
      | args: %{"path" => "file.txt", "old" => "missing", "new" => "x"},
        roots: [root]
    }

    assert Edit.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "old text not found",
             "emit" => []
           }
  end

  test "refuses when the old text is ambiguous", %{root: root} do
    input = %{
      @input
      | args: %{"path" => "dup.txt", "old" => "same", "new" => "x"},
        roots: [root]
    }

    assert Edit.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "old text is ambiguous: 2 matches",
             "emit" => []
           }
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{
      @input
      | args: %{"path" => "../escape.txt", "old" => "a", "new" => "b"},
        roots: [root]
    }

    assert Edit.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape.txt",
             "emit" => []
           }
  end

  test "refuses without old", %{root: root} do
    input = %{@input | args: %{"path" => "file.txt", "new" => "b"}, roots: [root]}

    assert Edit.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "old required",
             "emit" => []
           }
  end

  test "reports a missing file", %{root: root} do
    input = %{
      @input
      | args: %{"path" => "missing.txt", "old" => "a", "new" => "b"},
        roots: [root]
    }

    assert Edit.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "no such file: missing.txt",
             "emit" => []
           }
  end

  test "the builtin catalog discovers edit with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"edit" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.write"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    File.write!(Path.join(root, "wired.txt"), "hello world\n")
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "edit")

    input = %{
      @input
      | args: %{"path" => "wired.txt", "old" => "hello", "new" => "hi"},
        roots: [root]
    }

    direct_input = %{input | args: %{input.args | "path" => "file.txt"}}
    direct = Edit.run(direct_input, policy(direct_input))
    assert {:ok, result} = Invoke.call(manifest, input, policy(input))
    assert result.output == direct["output"]
    assert File.read!(Path.join(root, "wired.txt")) == "hi world\n"
  end

  defp policy(input), do: ExecutionPolicyFixtures.policy(input.roots, writable: true)
end
