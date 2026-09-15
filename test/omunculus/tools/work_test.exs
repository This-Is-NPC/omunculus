defmodule Omunculus.Tools.WorkTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Work

  @input %{
    name: "work",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "creates a work with just a title" do
    input = %{@input | args: %{"title" => "Fix the parser"}}

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "work", "body" => %{"title" => "Fix the parser"}}]
           }
  end

  test "updates a work when work_id is given" do
    input = %{@input | args: %{"title" => "Renamed", "work_id" => "wrk_1"}}

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{"type" => "work", "body" => %{"title" => "Renamed", "work_id" => "wrk_1"}}
             ]
           }
  end

  test "creates a work under a parent when parent_id is given" do
    input = %{@input | args: %{"title" => "Subtask", "parent_id" => "wrk_root"}}

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{"type" => "work", "body" => %{"title" => "Subtask", "parent_id" => "wrk_root"}}
             ]
           }
  end

  test "ignores blank work_id and parent_id" do
    input = %{@input | args: %{"title" => "Task", "work_id" => "", "parent_id" => ""}}

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "work", "body" => %{"title" => "Task"}}]
           }
  end

  test "refuses without a title" do
    assert Work.run(%{@input | args: %{}}) == %{
             "ok" => false,
             "output" => "title required",
             "emit" => []
           }
  end

  test "refuses a blank title" do
    assert Work.run(%{@input | args: %{"title" => ""}}) == %{
             "ok" => false,
             "output" => "title required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers work with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"work" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "work")
    input = %{@input | args: %{"title" => "Fix the parser"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Work.run(input)["emit"]
  end
end
