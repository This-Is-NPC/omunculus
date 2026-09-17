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

  test "returns the next value from the counter view" do
    assert Counter.run(%{@input | view: %{"counter" => 0}}) == %{
             "ok" => true,
             "output" => "1",
             "emit" => []
           }

    assert Counter.run(%{@input | view: %{"counter" => 1}}) == %{
             "ok" => true,
             "output" => "2",
             "emit" => []
           }
  end

  test "requires the counter view" do
    assert Counter.run(@input) == %{
             "ok" => false,
             "output" => "counter view required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers counter in the bench group" do
    catalog = Catalog.unconfigured()

    assert %{"counter" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["bench"]
    assert manifest.views == ["counter"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "counter")
    input = %{@input | view: %{"counter" => 0}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == "1"
  end
end
