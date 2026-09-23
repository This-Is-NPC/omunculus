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

  test "creates a work with a title and a goal" do
    input = %{@input | args: %{"title" => "Fix the parser", "goal" => "Done when it passes"}}

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "work",
                 "body" => %{"title" => "Fix the parser", "goal" => "Done when it passes"}
               }
             ]
           }
  end

  test "updates a work when work_id is given" do
    input = %{
      @input
      | args: %{"title" => "Renamed", "goal" => "Done when it passes", "work_id" => "wrk_1"}
    }

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "work",
                 "body" => %{
                   "title" => "Renamed",
                   "goal" => "Done when it passes",
                   "work_id" => "wrk_1"
                 }
               }
             ]
           }
  end

  test "creates a work under a parent when parent_id is given" do
    input = %{
      @input
      | args: %{"title" => "Subtask", "goal" => "Done when it passes", "parent_id" => "wrk_root"}
    }

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "work",
                 "body" => %{
                   "title" => "Subtask",
                   "goal" => "Done when it passes",
                   "parent_id" => "wrk_root"
                 }
               }
             ]
           }
  end

  test "ignores blank work_id and parent_id" do
    input = %{
      @input
      | args: %{
          "title" => "Task",
          "goal" => "Done when it passes",
          "work_id" => "",
          "parent_id" => ""
        }
    }

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "work",
                 "body" => %{"title" => "Task", "goal" => "Done when it passes"}
               }
             ]
           }
  end

  test "creates a work with an explicit workspace" do
    input = %{
      @input
      | args: %{"title" => "Task", "goal" => "Done when it passes", "workspace" => "app"}
    }

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "work",
                 "body" => %{
                   "title" => "Task",
                   "goal" => "Done when it passes",
                   "workspace" => "app"
                 }
               }
             ]
           }
  end

  test "ignores a blank workspace" do
    input = %{
      @input
      | args: %{"title" => "Task", "goal" => "Done when it passes", "workspace" => ""}
    }

    assert Work.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "work",
                 "body" => %{"title" => "Task", "goal" => "Done when it passes"}
               }
             ]
           }
  end

  test "refuses without a title" do
    assert Work.run(%{@input | args: %{}}) == %{
             "ok" => false,
             "output" => "title required",
             "emit" => []
           }
  end

  test "refuses without a goal" do
    assert Work.run(%{@input | args: %{"title" => "Fix the parser"}}) == %{
             "ok" => false,
             "output" => "goal required",
             "emit" => []
           }
  end

  test "refuses a blank goal" do
    assert Work.run(%{@input | args: %{"title" => "Fix the parser", "goal" => ""}}) == %{
             "ok" => false,
             "output" => "goal required",
             "emit" => []
           }
  end

  test "refuses a blank title" do
    assert Work.run(%{@input | args: %{"title" => "", "goal" => "Done when it passes"}}) == %{
             "ok" => false,
             "output" => "title required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers work with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"work" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "work")
    input = %{@input | args: %{"title" => "Fix the parser", "goal" => "Done when it passes"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Work.run(input)["emit"]
  end
end
