defmodule Omunculus.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Grep

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "a.txt"), "hello world\nbye\n")
    File.write!(Path.join(root, "sub/b.txt"), "hello again\n")
    File.write!(Path.join(root, "bin.dat"), <<0xFF, 0xFE, 0x00>>)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "grep",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "finds matches recursively under the default path", %{root: root} do
    input = %{@input | args: %{"pattern" => "hello"}, roots: [root]}

    assert Grep.run(input) == %{
             "ok" => true,
             "output" => "a.txt:1:hello world\nsub/b.txt:1:hello again",
             "emit" => []
           }
  end

  test "skips files that are not valid UTF-8", %{root: root} do
    input = %{@input | args: %{"pattern" => "."}, roots: [root]}

    result = Grep.run(input)
    refute result["output"] =~ "bin.dat"
  end

  test "no matches returns an empty string", %{root: root} do
    input = %{@input | args: %{"pattern" => "nope"}, roots: [root]}

    assert Grep.run(input) == %{"ok" => true, "output" => "", "emit" => []}
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"pattern" => "hello", "path" => "../escape"}, roots: [root]}

    assert Grep.run(input) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape",
             "emit" => []
           }
  end

  test "refuses without a pattern", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Grep.run(input) == %{"ok" => false, "output" => "pattern required", "emit" => []}
  end

  test "refuses an invalid regex", %{root: root} do
    input = %{@input | args: %{"pattern" => "("}, roots: [root]}

    assert %{"ok" => false, "output" => output, "emit" => []} = Grep.run(input)
    assert output =~ "invalid pattern"
  end

  test "the builtin catalog discovers grep with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"grep" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.read"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "grep")
    input = %{@input | args: %{"pattern" => "hello"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Grep.run(input)["output"]
  end
end
