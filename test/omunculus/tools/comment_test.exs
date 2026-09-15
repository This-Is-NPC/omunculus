defmodule Omunculus.Tools.CommentTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Comment

  @input %{
    name: "comment",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "comments on the work_id given in args" do
    input = %{@input | args: %{"body" => "looks good", "work_id" => "wrk_1"}}

    assert Comment.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "comment",
                 "body" => %{"work_id" => "wrk_1", "body" => "looks good"}
               }
             ]
           }
  end

  test "falls back to the run's own work_id when args omit it" do
    input = %{@input | args: %{"body" => "looks good"}, work_id: "wrk_2"}

    assert Comment.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "comment",
                 "body" => %{"work_id" => "wrk_2", "body" => "looks good"}
               }
             ]
           }
  end

  test "prefers an explicit work_id in args over the run's own work_id" do
    input = %{@input | args: %{"body" => "looks good", "work_id" => "wrk_1"}, work_id: "wrk_2"}

    assert Comment.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "comment",
                 "body" => %{"work_id" => "wrk_1", "body" => "looks good"}
               }
             ]
           }
  end

  test "refuses without a body" do
    assert Comment.run(%{@input | args: %{}, work_id: "wrk_1"}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "refuses a blank body" do
    assert Comment.run(%{@input | args: %{"body" => ""}, work_id: "wrk_1"}) == %{
             "ok" => false,
             "output" => "body required",
             "emit" => []
           }
  end

  test "refuses when there is no target at all" do
    assert Comment.run(%{@input | args: %{"body" => "looks good"}}) == %{
             "ok" => false,
             "output" => "no work to comment on",
             "emit" => []
           }
  end

  test "the builtin catalog discovers comment with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"comment" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "comment")
    input = %{@input | args: %{"body" => "looks good"}, work_id: "wrk_3"}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == Comment.run(input)["emit"]
  end
end
