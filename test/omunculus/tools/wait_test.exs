defmodule Omunculus.Tools.WaitTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Out, Wait}

  @input %{
    name: "wait",
    args: %{"report" => "Take your time; write when you decide."},
    view: %{},
    run_id: nil,
    work_id: "w1",
    workspace: nil,
    roots: []
  }

  test "emits wait with the report as its comment body" do
    assert Wait.run(@input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "wait",
                 "body" => %{"body" => "Take your time; write when you decide."}
               }
             ]
           }
  end

  test "a run without a work is told to answer instead, and a blank report is refused" do
    assert Wait.run(%{@input | work_id: nil}) == Out.fail(Out.no_work())
    assert Wait.run(%{@input | args: %{"report" => ""}}) == Out.fail("report required")
  end

  test "the builtin manifest is model-facing and ends the run through then" do
    assert %{"wait" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.chains == ["end"]
    assert manifest.then == ["end"]
    assert {:ok, result} = Invoke.call(manifest, @input)
    assert result.emit == Wait.run(@input)["emit"]
  end
end
