defmodule Omunculus.Tools.CompactCommentsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{CompactComments, Out}

  @input %{
    name: "compact_comments",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "load lists one line per comment in the comments view" do
    comments = [
      %{id: "cmt_1", author: "worker", body: "started", created_at: "t1"},
      %{id: "cmt_2", author: "reviewer", body: "ok", created_at: "t2"}
    ]

    input = %{@input | args: %{"op" => "load"}, view: %{"comments" => comments}}

    assert CompactComments.run(input) == %{
             "ok" => true,
             "output" => "cmt_1 worker: started\ncmt_2 reviewer: ok",
             "emit" => []
           }
  end

  test "load reports no comments when the list is empty" do
    input = %{@input | args: %{"op" => "load"}, view: %{"comments" => []}}

    assert CompactComments.run(input) == %{
             "ok" => true,
             "output" => Out.no_comments(),
             "emit" => []
           }
  end

  test "load reports no comments when the view is absent" do
    input = %{@input | args: %{"op" => "load"}}

    assert CompactComments.run(input) == %{
             "ok" => true,
             "output" => Out.no_comments(),
             "emit" => []
           }
  end

  test "commit emits a compact for the run's work_id" do
    input = %{@input | args: %{"op" => "commit", "summary" => "done"}, work_id: "wrk_1"}

    assert CompactComments.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{"type" => "compact", "body" => %{"work_id" => "wrk_1", "summary" => "done"}}
             ]
           }
  end

  test "commit keeps ids when given a non-empty list" do
    input = %{
      @input
      | args: %{"op" => "commit", "summary" => "done", "ids" => ["cmt_1", "cmt_2"]},
        work_id: "wrk_1"
    }

    assert CompactComments.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "compact",
                 "body" => %{
                   "work_id" => "wrk_1",
                   "summary" => "done",
                   "ids" => ["cmt_1", "cmt_2"]
                 }
               }
             ]
           }
  end

  test "commit drops ids when given an empty list" do
    input = %{
      @input
      | args: %{"op" => "commit", "summary" => "done", "ids" => []},
        work_id: "wrk_1"
    }

    assert %{"emit" => [%{"body" => body}]} = CompactComments.run(input)
    refute Map.has_key?(body, "ids")
  end

  test "commit without summary is a missing-args failure" do
    input = %{@input | args: %{"op" => "commit"}, work_id: "wrk_1"}

    assert CompactComments.run(input) == %{
             "ok" => false,
             "output" => "summary required",
             "emit" => []
           }
  end

  test "commit without a target work fails" do
    input = %{@input | args: %{"op" => "commit", "summary" => "done"}}

    assert CompactComments.run(input) == %{
             "ok" => false,
             "output" => "no work to compact",
             "emit" => []
           }
  end

  test "an op other than load or commit fails" do
    input = %{@input | args: %{"op" => "close"}}

    assert CompactComments.run(input) == %{
             "ok" => false,
             "output" => "op must be load or commit",
             "emit" => []
           }
  end

  test "the builtin catalog discovers compact_comments as a composite tool over comments" do
    catalog = Catalog.unconfigured()

    assert %{"compact_comments" => manifest} = catalog
    assert manifest.shape == "composite"
    assert manifest.views == ["comments"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "compact_comments")
    input = %{@input | args: %{"op" => "load"}, view: %{"comments" => []}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == CompactComments.run(input)["output"]
  end
end
