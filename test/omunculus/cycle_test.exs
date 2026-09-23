defmodule Omunculus.CycleTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Project}
  alias Omunculus.Store.Query

  import Omunculus.Fixtures, only: [last_comment: 1, role: 1]

  @toml """
  [agents.lead]
  depth = 0
  text = "lead"
  tools = ["comment", "continue", "delegate", "done", "end", "work"]

  [agents.alpha]
  depth = 1
  text = "alpha"
  tools = ["comment", "continue", "done", "end"]
  """

  setup do
    dir = Fixtures.tmp_dir()
    %{dir: dir}
  end

  # A limiter of its own per test, so runs of other tests take no slot.
  defp write_config(dir, max_concurrent) do
    Fixtures.write_config(dir, @toml)
    path = Fixtures.config_path(dir)

    File.write!(
      path,
      path
      |> File.read!()
      |> String.replace("max_concurrent = 4", "max_concurrent = #{max_concurrent}")
      |> String.replace(
        "max_queue = 64",
        "max_queue = #{1000 + :erlang.unique_integer([:positive])}"
      )
    )
  end

  # The root is created by the run of send, splits into two children and
  # ends when it runs again; each child runs `child`.
  defp model(child) do
    fn assembled, _tools, call ->
      case {role(assembled), last_comment(assembled)} do
        {"lead", nil} ->
          call.("work", %{
            "report" => "planned",
            "works" => [%{"title" => "Root", "goal" => "Ship"}]
          })

        {"lead", "planned"} ->
          call.("work", %{
            "report" => "split",
            "works" => [
              %{"title" => "A", "goal" => "Goal A"},
              %{"title" => "B", "goal" => "Goal B"}
            ]
          })

        {"lead", _children_done} ->
          call.("end", %{})

        {"alpha", _comment} ->
          child.(assembled, call)
      end
    end
  end

  # Returns once `count` callers have arrived, or fails after five seconds.
  defp barrier(agent, count) do
    Agent.update(agent, &(&1 + 1))
    wait_for(agent, count, System.monotonic_time(:millisecond) + 5_000)
  end

  defp wait_for(agent, count, deadline) do
    cond do
      Agent.get(agent, & &1) >= count ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{Agent.get(agent, & &1)} of #{count} runs started")

      true ->
        Process.sleep(5)
        wait_for(agent, count, deadline)
    end
  end

  defp all(project, sql, params \\ []) do
    {:ok, rows} = Query.all(project.conn, sql, params)
    rows
  end

  defp root_runs(project) do
    [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")
    {root, all(project, "SELECT * FROM runs WHERE work_id = ?", [root.id])}
  end

  test "two children delegated in one batch run at once and, finishing together, reopen the parent once",
       %{dir: dir} do
    write_config(dir, 4)
    {:ok, started} = Agent.start_link(fn -> 0 end)
    {:ok, finishing} = Agent.start_link(fn -> 0 end)

    Fixtures.use_model(
      dir,
      model(fn _assembled, call ->
        barrier(started, 2)
        barrier(finishing, 2)
        call.("done", %{"report" => "finished"})
      end)
    )

    assert {:ok, ""} = CLI.run(["send", "go"], dir)
    project = Fixtures.open_project(dir)

    {root, runs} = root_runs(project)
    assert length(runs) == 3
    assert root.state == "open"

    children = all(project, "SELECT * FROM works WHERE parent_id = ?", [root.id])
    assert Enum.map(children, & &1.state) == ["done", "done"]

    wakes =
      for %{type: "continue", body: body} <- all(project, "SELECT * FROM events"),
          Jason.decode!(body)["parent_id"] == root.id,
          do: body

    assert length(wakes) == 1
    assert all(project, "SELECT * FROM runs WHERE status != 'done'") == []

    Project.close(project)
  end

  test "max_concurrent = 1 runs the children one after the other", %{dir: dir} do
    write_config(dir, 1)
    {:ok, active} = Agent.start_link(fn -> %{now: 0, most: 0} end)

    Fixtures.use_model(
      dir,
      model(fn _assembled, call ->
        Agent.update(active, fn %{now: now, most: most} ->
          %{now: now + 1, most: max(most, now + 1)}
        end)

        Process.sleep(50)
        Agent.update(active, &%{&1 | now: &1.now - 1})
        call.("done", %{"report" => "finished"})
      end)
    )

    assert {:ok, ""} = CLI.run(["send", "go"], dir)
    assert Agent.get(active, & &1.most) == 1

    project = Fixtures.open_project(dir)
    {_root, runs} = root_runs(project)
    assert length(runs) == 3
    Project.close(project)
  end

  test "the command returns after every run it opened and fails with a child's error",
       %{dir: dir} do
    write_config(dir, 4)

    Fixtures.use_model(
      dir,
      model(fn assembled, call ->
        if String.contains?(assembled, "Goal A"),
          do: {:error, :child_failed},
          else: call.("done", %{"report" => "finished"})
      end)
    )

    assert {:error, :child_failed} = CLI.run(["send", "go"], dir)

    project = Fixtures.open_project(dir)
    assert all(project, "SELECT * FROM runs WHERE status != 'done'") == []

    {root, runs} = root_runs(project)
    assert root.state == "waiting"
    assert length(runs) == 2
    Project.close(project)
  end

  test "the errors of several runs fail the command together", %{dir: dir} do
    write_config(dir, 4)

    Fixtures.use_model(
      dir,
      model(fn assembled, _call ->
        if String.contains?(assembled, "Goal A"),
          do: {:error, :a_failed},
          else: {:error, :b_failed}
      end)
    )

    assert {:error, {:runs, reasons}} = CLI.run(["send", "go"], dir)
    assert Enum.sort(reasons) == [:a_failed, :b_failed]
    assert CLI.format_error({:runs, [:a_failed, :b_failed]}) == ":a_failed\n:b_failed"
  end

  test "the run of send that creates the root and goes on holds the root's turn until it finishes",
       %{dir: dir} do
    write_config(dir, 4)
    path = Fixtures.config_path(dir)
    File.write!(path, File.read!(path) <> "\n[agents.lead.overrides.work]\nthen = []\n")

    Fixtures.use_model(dir, fn assembled, _tools, call ->
      case last_comment(assembled) do
        nil ->
          assert {:ok, _} =
                   call.("work", %{
                     "report" => "planned",
                     "works" => [%{"title" => "Root", "goal" => "Ship"}]
                   })

          # Without the root's turn, the root's run would open meanwhile.
          Process.sleep(200)
          call.("end", %{})

        "planned" ->
          call.("end", %{})
      end
    end)

    assert {:ok, ""} = CLI.run(["send", "go"], dir)
    project = Fixtures.open_project(dir)

    {_root, runs} = root_runs(project)
    {[send_run], [root_run]} = Enum.split_with(runs, &(&1.via == "send"))

    [send_end] =
      all(project, "SELECT * FROM events WHERE type = 'end-run' AND run_id = ?", [send_run.id])

    [root_start] = all(project, "SELECT * FROM events WHERE id = ?", [root_run.event_id])
    assert send_end.sequence < root_start.sequence

    Project.close(project)
  end
end
