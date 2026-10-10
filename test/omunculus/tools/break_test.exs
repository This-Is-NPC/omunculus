defmodule Omunculus.Tools.BreakTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Break, Out}

  @input %{
    name: "break",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: "w1",
    workspace: nil,
    roots: []
  }

  test "a run without a work is told to answer instead" do
    input = %{@input | work_id: nil, args: %{"report" => "stuck"}}
    assert Break.run(input) == %{"ok" => false, "output" => Out.no_work(), "emit" => []}
  end

  test "emits break with the report as its comment body" do
    input = %{@input | args: %{"report" => "waiting on design review"}}

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
      | args: %{"report" => "waiting on design review", "stage" => "review", "agent" => "worker"}
    }

    assert Break.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{"type" => "break", "body" => %{"body" => "waiting on design review"}}
             ]
           }
  end

  test "refuses without a report" do
    assert Break.run(%{@input | args: %{}}) == %{
             "ok" => false,
             "output" => "report required",
             "emit" => []
           }
  end

  test "refuses a blank report" do
    assert Break.run(%{@input | args: %{"report" => ""}}) == %{
             "ok" => false,
             "output" => "report required",
             "emit" => []
           }
  end

  test "the builtin manifest is model-facing and ends the run through then" do
    catalog = Catalog.unconfigured()

    assert %{"break" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.chains == ["end"]
    assert manifest.then == ["end"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "break")
    input = %{@input | args: %{"report" => "waiting on design review"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Break.run(input)["emit"]
  end
end
