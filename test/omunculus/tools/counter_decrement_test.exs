defmodule Omunculus.Tools.CounterDecrementTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Counter, CounterDecrement}

  @input %{
    name: "counter_decrement",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "increments and decrements from the counter view" do
    counter_input = %{@input | name: "counter", view: %{"counter" => 0}}
    decrement_input = %{@input | view: %{"counter" => 2}}

    assert Counter.run(counter_input) == %{"ok" => true, "output" => "1", "emit" => []}
    assert CounterDecrement.run(decrement_input) == %{"ok" => true, "output" => "1", "emit" => []}
  end

  test "requires the counter view" do
    assert CounterDecrement.run(@input) == %{
             "ok" => false,
             "output" => "counter view required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers counter_decrement in the bench group" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"counter_decrement" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["bench"]
    assert manifest.views == ["counter"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "counter_decrement")
    input = %{@input | view: %{"counter" => 0}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == "-1"
  end
end
