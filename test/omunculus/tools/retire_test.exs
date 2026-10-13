defmodule Omunculus.Tools.RetireTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Out, Retire}

  @input %{
    name: "retire",
    args: %{"work_id" => "w2", "report" => "the page comes first"},
    view: %{},
    run_id: nil,
    work_id: "w1",
    workspace: nil,
    roots: []
  }

  test "emits retire with the work and the report as its comment body" do
    assert Retire.run(@input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "retire",
                 "body" => %{"work_id" => "w2", "body" => "the page comes first"}
               }
             ]
           }
  end

  test "a run without a work is told to answer instead" do
    assert Retire.run(%{@input | work_id: nil}) ==
             %{"ok" => false, "output" => Out.no_work(), "emit" => []}
  end

  test "refuses without the work or the report" do
    for {key, output} <- [{"work_id", "work_id required"}, {"report", "report required"}] do
      assert Retire.run(%{@input | args: Map.delete(@input.args, key)}) ==
               %{"ok" => false, "output" => output, "emit" => []}
    end
  end

  test "the builtin manifest is model-facing and does not end the run" do
    manifest = Map.fetch!(Catalog.unconfigured(), "retire")

    assert manifest.triggers == ["model"]
    assert manifest.then == []
    assert {:ok, result} = Invoke.call(manifest, @input)
    assert result.emit == Retire.run(@input)["emit"]
  end
end
