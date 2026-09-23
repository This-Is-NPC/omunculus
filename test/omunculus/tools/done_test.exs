defmodule Omunculus.Tools.DoneTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Fixtures, Project, Run, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Done

  test "chains a comment with the report and continue" do
    assert Done.run(%{args: %{"report" => "counted"}}) == %{
             "ok" => true,
             "output" => "",
             "emit" => [],
             "chain" => [
               %{"name" => "comment", "args" => %{"body" => "counted"}},
               %{"name" => "continue", "args" => %{}}
             ]
           }
  end

  test "fails without a report" do
    assert %{"ok" => false, "output" => "report required"} = Done.run(%{args: %{}})
  end

  test "the builtin manifest chains comment, continue and end, with end as its then" do
    assert %{"done" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["sequence"]
    assert manifest.chains == ["comment", "continue", "end"]
    assert manifest.then == ["end"]
  end

  test "in a run it comments, continues and ends in one call, before the hooks react" do
    dir = Fixtures.tmp_dir()

    Fixtures.write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["comment", "continue", "done", "end"]
    """)

    test_pid = self()

    Fixtures.use_model(dir, fn _assembled, _tools, call ->
      call.("done", %{"report" => "all counted"})
      send(test_pid, :reached_after_done)
      {:ok, "unused"}
    end)

    project = Fixtures.open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    message_id = Fixtures.insert(project.conn, :prompts)
    opening = Fixtures.opening(message_id, work_id)

    assert {:ok, run} = Run.open(project, opening)
    refute_received :reached_after_done

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})

    assert Enum.map(events, & &1.type) == [
             "start-run",
             "tool",
             "tool",
             "tool",
             "comment",
             "tool",
             "continue",
             "tool",
             "end",
             "tool",
             "end-run"
           ]

    calls = for %{type: "tool", body: body} <- events, do: Jason.decode!(body)

    assert Enum.map(calls, &{&1["name"], &1["via"]}) == [
             {"assemble", nil},
             {"done", nil},
             {"comment", "done"},
             {"continue", "done"},
             {"end", "done"},
             {"on-continue", nil}
           ]

    assert {:ok, [%{body: "all counted"}]} = Store.view(project.conn, "comments.work", work_id)

    assert {:ok, %{state: "done"}} =
             Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])

    Project.close(project)
  end
end
