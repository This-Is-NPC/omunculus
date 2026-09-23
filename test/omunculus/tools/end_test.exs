defmodule Omunculus.Tools.EndTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.End

  @input %{
    name: "end",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits end with an empty body" do
    assert End.run(@input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "end", "body" => %{}}]
           }
  end

  test "the builtin catalog discovers end in the sequence group with triggers == [\"model\"]" do
    assert %{"end" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["sequence"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    manifest = Map.fetch!(Catalog.unconfigured(), "end")

    assert {:ok, result} = Invoke.call(manifest, @input)
    assert result.emit == End.run(@input)["emit"]
  end
end
