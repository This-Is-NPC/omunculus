defmodule Omunculus.Tools.NotifyTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Notify

  @input %{
    name: "notify",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits a notify with the body" do
    input = %{@input | args: %{"body" => "preciso de ajuda"}}

    assert Notify.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "notify", "body" => %{"body" => "preciso de ajuda"}}]
           }
  end

  test "carries an optional work_id" do
    input = %{@input | args: %{"body" => "preciso de ajuda", "work_id" => "wrk_1"}}

    assert Notify.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "notify",
                 "body" => %{"body" => "preciso de ajuda", "work_id" => "wrk_1"}
               }
             ]
           }
  end

  test "refuses without a body" do
    assert Notify.run(%{@input | args: %{}}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "refuses a blank body" do
    assert Notify.run(%{@input | args: %{"body" => ""}}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers notify with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"notify" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "notify")
    input = %{@input | args: %{"body" => "preciso de ajuda"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Notify.run(input)["emit"]
  end
end
