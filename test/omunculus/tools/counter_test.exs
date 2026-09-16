defmodule Omunculus.Tools.CounterTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Counter

  @input %{
    name: "counter",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{input: %{@input | roots: [root]}, root: root}
  end

  test "the first call yields 1 and the second yields 2", %{input: input} do
    assert Counter.run(input) == %{"ok" => true, "output" => "1", "emit" => []}
    assert Counter.run(input) == %{"ok" => true, "output" => "2", "emit" => []}
  end

  test "the counter file holds the returned value", %{input: input, root: root} do
    Counter.run(input)
    Counter.run(input)

    assert File.read!(Path.join([root, ".omunculus", "counter"])) == "2"
  end

  test "no roots fails" do
    assert Counter.run(@input) == %{"ok" => false, "output" => "no root", "emit" => []}
  end

  test "the builtin catalog discovers counter in the bench group" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"counter" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["bench"]
  end

  test "the manifest wiring yields the same output as calling the module directly", %{
    input: input
  } do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "counter")

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == "1"
  end
end
