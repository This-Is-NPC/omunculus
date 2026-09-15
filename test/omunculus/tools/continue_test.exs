defmodule Omunculus.Tools.ContinueTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Continue

  @input %{
    name: "continue",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits continue with an empty body regardless of args" do
    assert Continue.run(@input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "continue", "body" => %{}}]
           }
  end

  test "ignores stage, agent and model given in args" do
    input = %{@input | args: %{"stage" => "review", "agent" => "worker", "model" => "gpt"}}

    assert Continue.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "continue", "body" => %{}}]
           }
  end

  test "the builtin catalog discovers continue with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"continue" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "continue")
    input = %{@input | args: %{"stage" => "review"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Continue.run(input)["emit"]
  end
end
