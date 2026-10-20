defmodule Omunculus.CycleTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Cycle, Fixtures, Operations, Project}
  alias Omunculus.Store.Query

  import Omunculus.Fixtures, only: [last_comment: 1, role: 1]

  @toml """
  [agents.lead]
  depth = 0
  text = "lead"
  tools = ["break", "comment", "continue", "delegate", "done", "end", "work"]

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
  # is done when it runs again, or breaks when the store refuses done
  # because a child broke; each child runs `child`.
  defp model(child) do
    fn assembled, _tools, call ->
      case {role(assembled), last_comment(assembled)} do
        {"lead", nil} ->
          call.("work", %{
            "report" => "planned",
            "works" => [%{"title" => "Root", "goal" => "Ship", "agent" => "lead"}]
          })

        {"lead", "planned"} ->
          call.("work", %{
            "report" => "split",
            "works" => [
              %{"title" => "A", "goal" => "Goal A"},
              %{"title" => "B", "goal" => "Goal B"}
            ]
          })

        {"lead", _children_back} ->
          case call.("done", %{"report" => "shipped"}) do
            {:ok, "refused: " <> _broken} -> call.("break", %{"report" => "A failed"})
            done -> done
          end

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
    assert root.state == "done"

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

  for stopped_state <- ~w(done cancelled) do
    test "pending requests release runs, resume independently, and leave #{stopped_state} work stopped",
         %{dir: dir} do
      write_config(dir, 1)
      path = Fixtures.config_path(dir)

      File.write!(
        path,
        path
        |> File.read!()
        |> String.replace(
          ~s(tools = ["comment", "continue", "done", "end"]),
          ~s(tools = ["ask", "comment", "continue", "done", "end"])
        )
      )

      owner = self()

      Fixtures.use_model(
        dir,
        model(fn assembled, call ->
          goal = if String.contains?(assembled, "Goal A"), do: "Goal A", else: "Goal B"

          if String.contains?(assembled, "## Request") do
            send(owner, {:resumed, goal, assembled})
            call.("done", %{"report" => "answered"})
          else
            send(owner, {:asked, goal, self()})

            call.("ask", %{
              "question" => "May I proceed with #{goal}?",
              "options" => ["yes", "no"],
              "to" => "owner"
            })
          end
        end)
      )

      assert {:ok, ""} = CLI.run(["send", "go"], dir)
      assert_receive {:asked, "Goal A", first_pid}
      assert_receive {:asked, "Goal B", second_pid}
      refute Process.alive?(first_pid)
      refute Process.alive?(second_pid)
      refute_received {:resumed, _, _}

      project = Fixtures.open_project(dir)
      on_exit(fn -> Project.close(project) end)

      [first, second] =
        all(project, "SELECT * FROM works WHERE parent_id IS NOT NULL ORDER BY title")

      [first_request] = all(project, "SELECT * FROM requests WHERE work_id = ?", [first.id])
      [second_request] = all(project, "SELECT * FROM requests WHERE work_id = ?", [second.id])

      for {work, request} <- [{first, first_request}, {second, second_request}] do
        assert work.state == "waiting"
        assert work.waiting == "request"
        assert work.waiting_for == request.id
        assert request.status == "pending"
      end

      assert all(project, "SELECT * FROM runs WHERE status != 'done'") == []
      {:ok, config} = Fixtures.load_config(dir)
      limits = Map.put(config.execution, :scope, {:project, config.store.path})
      assert {:ok, lease} = Omunculus.Execution.Limiter.acquire(limits, self(), :run)
      assert :ok = Omunculus.Execution.Limiter.release(limits, lease, :run)

      assert {:ok, ""} =
               CLI.run(["reply", "--request_id", first_request.id, "Proceed with A."], dir)

      assert_receive {:resumed, "Goal A", prompt}
      assert prompt =~ "Proceed with A."
      refute_received {:resumed, "Goal B", _}

      [_original, resumed] =
        all(project, "SELECT * FROM runs WHERE work_id = ? ORDER BY rowid", [first.id])

      assert resumed.via == "reply"
      assert resumed.request_id == first_request.id

      [reply] =
        all(project, "SELECT * FROM events WHERE type = 'reply' AND request_id = ?", [
          first_request.id
        ])

      assert resumed.cause_id == reply.id
      [still_waiting] = all(project, "SELECT * FROM works WHERE id = ?", [second.id])
      assert still_waiting.state == "waiting"
      assert still_waiting.waiting_for == second_request.id
      assert [_original] = all(project, "SELECT * FROM runs WHERE work_id = ?", [second.id])
      [pending] = all(project, "SELECT * FROM requests WHERE id = ?", [second_request.id])
      assert pending.status == "pending"

      if unquote(stopped_state) == "cancelled" do
        args = %{"request_id" => second_request.id}
        call = %{name: "cancel", args: args, ok: true, output: ""}
        emit = %{"type" => "cancel", "body" => args}

        ctx = %{
          run_id: nil,
          work_id: nil,
          author: "human",
          agent: nil,
          config: config,
          groups: %{}
        }

        assert {:ok, [_tool, %{type: "cancel"}]} =
                 Omunculus.Store.record_tools(project.conn, nil, [{call, [emit]}], ctx)
      else
        assert :ok =
                 Query.exec(project.conn, "UPDATE works SET state = 'done' WHERE id = ?", [
                   second.id
                 ])
      end

      assert {:ok, ""} = CLI.run(["reply", "--request_id", second_request.id, "Too late."], dir)
      refute_received {:resumed, "Goal B", _}
      assert [_original] = all(project, "SELECT * FROM runs WHERE work_id = ?", [second.id])
      [stopped] = all(project, "SELECT * FROM works WHERE id = ?", [second.id])
      assert stopped.state == unquote(stopped_state)
      [closed] = all(project, "SELECT * FROM requests WHERE id = ?", [second_request.id])
      assert closed.status == "closed"
      assert all(project, "SELECT * FROM runs WHERE status != 'done'") == []
    end
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

    # The failed child is broken, which wakes the root once B is done; the
    # root cannot be done while A waits on it, so it breaks too.
    [failed] = all(project, "SELECT * FROM works WHERE goal = 'Goal A'")

    assert [_break] =
             all(project, "SELECT * FROM events WHERE type = 'break' AND work_id = ?", [failed.id])

    {root, runs} = root_runs(project)
    assert root.state == "waiting"

    assert [] =
             all(project, "SELECT * FROM events WHERE type = 'continue' AND work_id = ?", [
               root.id
             ])

    assert [_break] =
             all(project, "SELECT * FROM events WHERE type = 'break' AND work_id = ?", [root.id])

    assert length(runs) == 3
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
                     "works" => [%{"title" => "Root", "goal" => "Ship", "agent" => "lead"}]
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

  test "a command in a shared cycle waits for its own runs and fails with their errors only",
       %{dir: dir} do
    write_config(dir, 4)
    test = self()

    Fixtures.use_model(dir, fn assembled, _tools, _call ->
      if assembled =~ "slow" do
        send(test, {:slow, self()})
        receive do: (:release -> {:ok, "slow"})
      else
        {:error, :fast_failed}
      end
    end)

    project = Fixtures.open_project(dir)
    {:ok, cycle} = Cycle.start_link(project)
    project = %{project | cycle: cycle}

    send_message = fn text ->
      Task.async(fn ->
        Cycle.command(project, nil, &Operations.call(&1, "send", %{"message" => text}, %{}))
      end)
    end

    slow = send_message.("slow")
    assert_receive {:slow, slow_run}, 30_000

    fast = send_message.("fast")
    assert {:error, :fast_failed} = Task.await(fast, 30_000)
    assert Task.yield(slow, 100) == nil

    send(slow_run, :release)
    assert {:ok, _out, _events} = Task.await(slow, 30_000)

    assert :ok = GenServer.call(cycle, :await)
    GenServer.stop(cycle)
    Project.close(project)
  end
end
