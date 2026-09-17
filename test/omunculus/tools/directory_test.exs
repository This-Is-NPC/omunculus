defmodule Omunculus.Tools.DirectoryTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Directory

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "b.txt"), "b")
    File.write!(Path.join(root, "a.txt"), "a")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "directory",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "lists one root, its entries sorted and indented, directories suffixed with /", %{
    root: root
  } do
    input = %{@input | roots: [root]}

    assert Directory.run(input, policy(input)) == %{
             "ok" => true,
             "output" => "#{root}\n  a.txt\n  b.txt\n  sub/",
             "emit" => []
           }
  end

  test "lists every root, one block each", %{root: root} do
    other = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(other)
    File.write!(Path.join(other, "c.txt"), "c")
    on_exit(fn -> File.rm_rf!(other) end)

    input = %{@input | roots: [root, other]}

    assert Directory.run(input, policy(input)) == %{
             "ok" => true,
             "output" => "#{root}\n  a.txt\n  b.txt\n  sub/\n\n#{other}\n  c.txt",
             "emit" => []
           }
  end

  test "no roots yields an empty output" do
    assert Directory.run(@input, policy(@input)) == %{"ok" => true, "output" => "", "emit" => []}
  end

  test "the builtin catalog discovers directory with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"directory" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == []
  end

  test "the manifest wiring yields the same output as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "directory")
    input = %{@input | roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input, policy(input))
    assert result.output == Directory.run(input, policy(input))["output"]
  end

  defp policy(input), do: ExecutionPolicyFixtures.policy(input.roots)
end
