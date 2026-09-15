defmodule Omunculus.Tools.BreakTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Break

  @input %{
    name: "break",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits break with the given body" do
    input = %{@input | args: %{"body" => "waiting on design review"}}

    assert Break.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{"type" => "break", "body" => %{"body" => "waiting on design review"}}
             ]
           }
  end

  test "does not forward stage or agent from args" do
    input = %{
      @input
      | args: %{"body" => "waiting on design review", "stage" => "review", "agent" => "worker"}
    }

    assert Break.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{"type" => "break", "body" => %{"body" => "waiting on design review"}}
             ]
           }
  end

  test "refuses without a body" do
    assert Break.run(%{@input | args: %{}}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "refuses a blank body" do
    assert Break.run(%{@input | args: %{"body" => ""}}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers break with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"break" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "break")
    input = %{@input | args: %{"body" => "waiting on design review"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Break.run(input)["emit"]
  end
end
