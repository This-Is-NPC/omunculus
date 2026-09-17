defmodule Omunculus.Tools.WorkspacesTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Workspaces

  @input %{
    name: "workspaces",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "lists every workspace, marking the run's own with *" do
    items = [
      %{name: "one", root: "/abs/one", current: false},
      %{name: "two", root: "/abs/two", current: true}
    ]

    input = %{@input | view: %{"workspaces" => items}}

    assert Workspaces.run(input) == %{
             "ok" => true,
             "output" => "one /abs/one\ntwo /abs/two *",
             "emit" => []
           }
  end

  test "reports nothing when there are no workspaces" do
    input = %{@input | view: %{"workspaces" => []}}
    assert Workspaces.run(input) == %{"ok" => true, "output" => "", "emit" => []}
  end

  test "reports nothing when the key is absent" do
    assert Workspaces.run(@input) == %{"ok" => true, "output" => "", "emit" => []}
  end

  test "the builtin catalog discovers workspaces with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"workspaces" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == []
    assert manifest.views == ["workspaces"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "workspaces")
    input = %{@input | view: %{"workspaces" => []}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Workspaces.run(input)["output"]
  end
end
