defmodule Omunculus.Tools.WorkTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Project, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Out, Work}

  import Omunculus.Fixtures, only: [last_comment: 1, role: 1]

  @input %{
    name: "work",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  @item %{"title" => "Fix the parser", "goal" => "Done when it passes"}

  defp with_work(args), do: %{@input | args: args, work_id: "wrk_1"}
  defp without_work(args), do: %{@input | args: args}

  describe "the module" do
    test "without a work, emits the work action with the report" do
      input = without_work(%{"report" => "planned", "works" => [@item]})

      assert Work.run(input) == %{
               "ok" => true,
               "output" => "",
               "emit" => [
                 %{"type" => "work", "body" => %{"report" => "planned", "works" => [@item]}}
               ]
             }
    end

    test "with a work, chains a comment with the report and one delegate per item" do
      second = %{
        "title" => "Docs",
        "goal" => "Documented",
        "agent" => "writer",
        "workspace" => ""
      }

      input = with_work(%{"report" => "split", "works" => [@item, second]})

      assert Work.run(input) == %{
               "ok" => true,
               "output" => "",
               "emit" => [],
               "chain" => [
                 %{"name" => "comment", "args" => %{"body" => "split"}},
                 %{"name" => "delegate", "args" => @item},
                 %{
                   "name" => "delegate",
                   "args" => %{"title" => "Docs", "goal" => "Documented", "agent" => "writer"}
                 }
               ]
             }
    end

    test "refuses without a report" do
      assert Work.run(with_work(%{"works" => [@item]})) == Out.fail("report required")
    end

    test "refuses without works or with none" do
      assert Work.run(with_work(%{"report" => "r"})) == Out.fail("works required")
      assert Work.run(with_work(%{"report" => "r", "works" => []})) == Out.fail("works required")
    end

    test "refuses an item without a title, a goal, or that is not an object" do
      for {item, message} <- [
            {%{"goal" => "g"}, "works[1]: title required"},
            {%{"title" => "t", "goal" => ""}, "works[1]: goal required"},
            {"t", "works[1]: object required"}
          ] do
        assert Work.run(with_work(%{"report" => "r", "works" => [@item, item]})) ==
                 Out.fail(message)
      end
    end

    test "the builtin manifest is a model tool of the sequence group chaining its steps" do
      assert %{"work" => manifest} = Catalog.unconfigured()
      assert manifest.triggers == ["model"]
      assert manifest.groups == ["sequence"]
      assert manifest.chains == ["comment", "delegate", "end"]
      assert manifest.then == ["end"]

      items = & &1["properties"]["works"]["items"]["properties"]
      assert Map.has_key?(items.(manifest.parameters), "agent")
      refute Map.has_key?(items.(manifest.schemas["staged"]), "agent")
    end

    test "the manifest wiring yields the same emit as calling the module directly" do
      manifest = Map.fetch!(Catalog.unconfigured(), "work")
      input = without_work(%{"report" => "planned", "works" => [@item]})

      assert {:ok, result} = Invoke.call(manifest, input)
      assert result.emit == Work.run(input)["emit"]
    end
  end

  describe "in the run cycle" do
    setup do
      dir = Fixtures.tmp_dir()
      %{dir: dir}
    end

    @creator ~w(comment continue delegate done end reopen work)

    defp agents_toml(lead_tools \\ @creator) do
      """
      [agents.lead]
      depth = 0
      text = "lead"
      tools = #{inspect(lead_tools)}

      [agents.alpha]
      depth = 1
      text = "alpha"
      tools = #{inspect(@creator)}

      [agents.beta]
      depth = 1
      text = "beta"
      tools = ["break", "comment", "continue", "done", "end"]

      [agents.checker]
      depth = 1
      workflow_only = true
      text = "checker"
      tools = ["comment", "done", "end"]

      [agents.gamma]
      depth = 2
      text = "gamma"
      tools = ["comment", "continue", "done", "end"]
      """
    end

    defp create(call, report, works), do: call.("work", %{"report" => report, "works" => works})

    defp setup_project(dir, toml, model) do
      Fixtures.write_config(dir, toml)
      Fixtures.use_model(dir, model)
      assert {:ok, ""} = CLI.run(["send", "go"], dir)
      project = Fixtures.open_project(dir)
      project
    end

    defp all(project, sql, params \\ []) do
      {:ok, rows} = Query.all(project.conn, sql, params)
      rows
    end

    defp runs_in_order(project),
      do:
        all(
          project,
          "SELECT runs.* FROM runs JOIN events ON events.id = runs.event_id ORDER BY events.sequence"
        )

    # The lead opens a root for itself: by naming itself, or, when depth 0
    # has a workflow (`root`), by naming nobody.
    defp root_model(on_root, root \\ %{"agent" => "lead"}) do
      fn assembled, _tools, call ->
        case {role(assembled), last_comment(assembled)} do
          {"lead", nil} ->
            create(call, "planned", [Map.merge(%{"title" => "Root", "goal" => "Ship"}, root)])

          other ->
            on_root.(other, call)
        end

        # A run that did not end above ends here, so no work is retried.
        call.("end", %{})
        {:ok, "idle"}
      end
    end

    test "send opens a run without a work whose work call creates the root, comments the report, ends the run and opens the root's run",
         %{dir: dir} do
      project = setup_project(dir, agents_toml(), root_model(fn _other, _call -> :ok end))

      assert [root] = all(project, "SELECT * FROM works")
      assert %{parent_id: nil, title: "Root", goal: "Ship", assignee: "lead", stage: nil} = root

      assert [%{body: "planned"}] =
               all(project, "SELECT * FROM comments WHERE work_id = ?", [root.id])

      assert [first, second] = runs_in_order(project)
      assert first.work_id == root.id
      assert second.work_id == root.id

      {:ok, events} = Store.replay(project.conn, {:run, first.id})
      assert events |> Enum.map(& &1.type) |> Enum.take(-2) == ["end", "end-run"]

      Project.close(project)
    end

    test "without a work, works naming agents of depth 1 run before the root's first run",
         %{dir: dir} do
      model = fn assembled, _tools, call ->
        case {role(assembled), last_comment(assembled)} do
          {"lead", nil} ->
            create(call, "handed down", [
              %{"title" => "A", "goal" => "Goal A", "agent" => "alpha"},
              %{"title" => "B", "goal" => "Goal B", "agent" => "beta"}
            ])

          {"lead", _comment} ->
            call.("done", %{"report" => "both back"})

          {_child, _comment} ->
            call.("done", %{"report" => "finished"})
        end

        {:ok, "idle"}
      end

      project = setup_project(dir, agents_toml(), model)

      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")
      assert %{title: "A; B", assignee: "lead", state: "done"} = root

      assert [%{assignee: "alpha", state: "done"}, %{assignee: "beta", state: "done"}] =
               all(project, "SELECT * FROM works WHERE parent_id = ? ORDER BY title", [root.id])

      assert [first, child_one, child_two, last] = runs_in_order(project)

      assert {first.agent, first.work_id, last.agent, last.work_id} ==
               {"lead", root.id, "lead", root.id}

      assert Enum.sort([child_one.agent, child_two.agent]) == ["alpha", "beta"]

      Project.close(project)
    end

    test "with a workflow at depth 0 the root starts at the first stage and its run opens",
         %{dir: dir} do
      toml =
        agents_toml() <>
          """

          [workflows.flow]
          steps = [{ name = "plan", agent = "lead" }]

          [policy]
          workflows = ["flow"]

          [policy.overrides.work]
          schema = "staged"
          """

      project = setup_project(dir, toml, root_model(fn _other, _call -> :ok end, %{}))

      assert [%{stage: "plan", assignee: "lead"} = root] = all(project, "SELECT * FROM works")
      assert [_first, second] = runs_in_order(project)
      assert second.work_id == root.id

      Project.close(project)
    end

    test "a run of a work creates two children, both run, and the work reopens only after both are done",
         %{dir: dir} do
      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [
              %{"title" => "A", "goal" => "Goal A", "agent" => "alpha"},
              %{"title" => "B", "goal" => "Goal B", "agent" => "alpha"}
            ])

          {"alpha", _comment}, call ->
            call.("done", %{"report" => "finished"})

          _other, _call ->
            :ok
        end)

      project = setup_project(dir, agents_toml(), model)

      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")
      children = all(project, "SELECT * FROM works WHERE parent_id = ? ORDER BY title", [root.id])

      assert [%{title: "A", goal: "Goal A"}, %{title: "B", goal: "Goal B"}] = children
      assert Enum.all?(children, &(&1.assignee == "alpha" and &1.state == "done"))
      assert root.state == "open"

      assert ["planned", "split"] =
               project
               |> all("SELECT body FROM comments WHERE work_id = ? ORDER BY created_at, id", [
                 root.id
               ])
               |> Enum.map(& &1.body)

      # The children run concurrently: which of them starts or finishes
      # first is not defined, only that the root reopens once, after both.
      [a, b] = Enum.map(children, & &1.id)
      assert [first, second, child_one, child_two, last] = runs_in_order(project)
      assert [first.work_id, second.work_id, last.work_id] == [root.id, root.id, root.id]
      assert Enum.sort([child_one.work_id, child_two.work_id]) == Enum.sort([a, b])

      continues =
        for %{type: "continue", body: body} = event <- all(project, "SELECT * FROM events"),
            do: {event, Jason.decode!(body)["parent_id"]}

      assert [{_event, nil}, {waking, parent_id}] = continues
      assert parent_id == root.id

      [last_start] = all(project, "SELECT * FROM events WHERE id = ?", [last.event_id])
      assert waking.sequence < last_start.sequence

      Project.close(project)
    end

    test "a child's break reopens the waiting work at once; a named allowed agent takes the child",
         %{dir: dir} do
      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [
              %{"title" => "A", "goal" => "Goal A", "agent" => "beta"},
              %{"title" => "B", "goal" => "Goal B", "agent" => "alpha"}
            ])

          {"beta", _comment}, call ->
            call.("break", %{"report" => "stuck"})

          {"alpha", _comment}, call ->
            call.("done", %{"report" => "finished"})

          _other, _call ->
            :ok
        end)

      project = setup_project(dir, agents_toml(), model)

      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")

      assert [%{assignee: "beta", state: "waiting"} = a, %{assignee: "alpha", state: "done"} = b] =
               all(project, "SELECT * FROM works WHERE parent_id = ? ORDER BY title", [root.id])

      # A and B run concurrently; the root's third run opens after A's break,
      # while B may still run.
      assert [first, second | rest] = runs_in_order(project)
      assert [first.work_id, second.work_id] == [root.id, root.id]
      assert Enum.sort(Enum.map(rest, & &1.work_id)) == Enum.sort([a.id, root.id, b.id])

      [break] = all(project, "SELECT * FROM events WHERE type = 'break'")
      [reopened] = Enum.filter(rest, &(&1.work_id == root.id))
      [reopened_start] = all(project, "SELECT * FROM events WHERE id = ?", [reopened.event_id])
      assert break.sequence < reopened_start.sequence

      Project.close(project)
    end

    test "a parent woken by a child's break reopens its work with instructions, and the child goes on",
         %{dir: dir} do
      test_pid = self()

      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [%{"title" => "A", "goal" => "Goal A", "agent" => "beta"}])

          {"lead", "split"}, call ->
            # The parent woken by the break reads which work broke and sends it back.
            case Regex.run(~r/beta broke its work (\w+): stuck/, Process.get(:assembled)) do
              [_, work_id] ->
                send(test_pid, :woken)
                call.("reopen", %{"work_id" => work_id, "instructions" => "use the other file"})

              nil ->
                :ok
            end

          {"beta", "use the other file"}, call ->
            call.("done", %{"report" => "finished"})

          {"beta", _first}, call ->
            call.("break", %{"report" => "stuck"})

          _other, _call ->
            :ok
        end)

      project =
        setup_project(dir, agents_toml(), fn assembled, tools, call ->
          Process.put(:assembled, assembled)
          model.(assembled, tools, call)
        end)

      assert_received :woken
      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")
      assert [child] = all(project, "SELECT * FROM works WHERE parent_id = ?", [root.id])
      assert child.state == "done"

      assert ["stuck", "use the other file", "finished"] =
               project
               |> all("SELECT body FROM comments WHERE work_id = ? ORDER BY created_at, id", [
                 child.id
               ])
               |> Enum.map(& &1.body)

      Project.close(project)
    end

    test "a child with work creates grandchildren at depth 2 under its own work", %{dir: dir} do
      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [%{"title" => "A", "goal" => "Goal A", "agent" => "alpha"}])

          {"alpha", nil}, call ->
            create(call, "sub", [
              %{"title" => "A1", "goal" => "Goal A1"},
              %{"title" => "A2", "goal" => "Goal A2"}
            ])

          {"alpha", "sub"}, call ->
            call.("done", %{"report" => "merged"})

          {"gamma", _comment}, call ->
            call.("done", %{"report" => "leaf"})

          _other, _call ->
            :ok
        end)

      project = setup_project(dir, agents_toml(), model)

      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")
      assert [child] = all(project, "SELECT * FROM works WHERE parent_id = ?", [root.id])
      assert child.state == "done"

      grandchildren =
        all(project, "SELECT * FROM works WHERE parent_id = ? ORDER BY title", [child.id])

      assert [%{title: "A1"}, %{title: "A2"}] = grandchildren
      assert Enum.all?(grandchildren, &(&1.assignee == "gamma" and &1.state == "done"))
      assert Enum.all?(grandchildren, &(Store.work_depth(project.conn, &1) == 2))

      assert ["sub", "merged"] =
               project
               |> all("SELECT body FROM comments WHERE work_id = ? ORDER BY created_at, id", [
                 child.id
               ])
               |> Enum.map(& &1.body)

      Project.close(project)
    end

    test "an agent without delegate as have cannot create works: the chain fails and writes nothing",
         %{dir: dir} do
      test_pid = self()

      model =
        root_model(fn
          {"lead", "planned"}, call ->
            send(test_pid, {:work, create(call, "split", [%{"title" => "A", "goal" => "g"}])})

          _other, _call ->
            :ok
        end)

      project = setup_project(dir, agents_toml(~w(comment end work)), model)

      assert_received {:work, {:ok, output}}
      assert output == Out.chain_failed("delegate", :not_have)
      assert [_root] = all(project, "SELECT * FROM works")
      assert [%{body: "planned"}] = all(project, "SELECT * FROM comments")

      Project.close(project)
    end

    test "an agent without work as have cannot call it", %{dir: dir} do
      test_pid = self()

      model = fn _assembled, _tools, call ->
        send(test_pid, {:work, create(call, "planned", [%{"title" => "A", "goal" => "g"}])})
        {:ok, "idle"}
      end

      project = setup_project(dir, agents_toml(~w(comment end)), model)

      assert_received {:work, {:error, refused}}
      assert refused == Out.not_yours("work")
      assert [] = all(project, "SELECT * FROM works")

      Project.close(project)
    end

    test "a named agent must be allowed at the child's depth", %{dir: dir} do
      test_pid = self()

      model =
        root_model(fn
          {"lead", "planned"}, call ->
            for agent <- ["gamma", "checker", "ghost"] do
              send(
                test_pid,
                {agent,
                 create(call, "split", [%{"title" => "A", "goal" => "g", "agent" => agent}])}
              )
            end

          _other, _call ->
            :ok
        end)

      project = setup_project(dir, agents_toml(), model)

      for agent <- ["gamma", "checker", "ghost"] do
        assert_received {^agent, {:ok, refused}}
        assert refused == Out.refused({:delegate, {:agent_not_allowed, agent}})
      end

      assert [_root] = all(project, "SELECT * FROM works")
      assert [%{body: "planned"}] = all(project, "SELECT * FROM comments")

      Project.close(project)
    end

    test "with a workflow at the child's depth a named agent is refused and the staged schema is served",
         %{dir: dir} do
      test_pid = self()

      model = fn assembled, _tools, call ->
        if role(assembled) == "lead" and last_comment(assembled) == nil do
          send(
            test_pid,
            {:named,
             create(call, "split", [%{"title" => "A", "goal" => "g", "agent" => "alpha"}])}
          )
        end

        call.("end", %{})
        {:ok, "idle"}
      end

      toml =
        agents_toml() <>
          """

          [workflows.flow]
          steps = [{ name = "build", agent = "alpha" }, { name = "check", agent = "checker" }]

          [policy.depth.1]
          workflows = ["flow"]

          [policy.depth.0.overrides.work]
          schema = "staged"
          """

      Fixtures.write_config(dir, toml)

      Fixtures.use_model(dir, fn assembled, tools, call ->
        work = Enum.find(tools, &(&1.name == "work"))
        send(test_pid, {:schema, role(assembled), work && work.parameters})
        model.(assembled, tools, call)
      end)

      assert {:ok, ""} = CLI.run(["send", "go"], dir)
      project = Fixtures.open_project(dir)

      assert_received {:named, {:ok, named}}
      assert named == Out.refused({:delegate, {:workflow_required, ["flow"]}})
      assert_received {:schema, "lead", staged}
      refute Map.has_key?(staged["properties"]["works"]["items"]["properties"], "agent")
      assert [] = all(project, "SELECT * FROM works")

      Project.close(project)
    end

    test "without a work, two items not all for depth 1 or a missing goal fail and write nothing",
         %{dir: dir} do
      test_pid = self()

      model = fn _assembled, _tools, call ->
        send(test_pid, {:two, create(call, "r", [Map.put(@item, "agent", "lead"), @item])})
        send(test_pid, {:no_goal, create(call, "r", [%{"title" => "t"}])})
        {:ok, "idle"}
      end

      project = setup_project(dir, agents_toml(), model)

      assert_received {:two, {:ok, two}}
      assert two == Out.refused({:work, :one_root})
      assert_received {:no_goal, {:ok, "works[0]: goal required"}}
      assert [] = all(project, "SELECT * FROM works")
      assert [_run] = all(project, "SELECT * FROM runs")

      Project.close(project)
    end

    test "assemble lists the agents a new work may name when the run has the work card",
         %{dir: dir} do
      test_pid = self()

      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [%{"title" => "A", "goal" => "g", "agent" => "beta"}])

          _other, _call ->
            :ok
        end)

      Fixtures.write_config(dir, agents_toml())

      Fixtures.use_model(dir, fn assembled, tools, call ->
        send(test_pid, {:assembled, role(assembled), assembled})
        model.(assembled, tools, call)
      end)

      assert {:ok, ""} = CLI.run(["send", "go"], dir)

      assert_received {:assembled, "lead", without_work}
      assert without_work =~ "## Agents\n- alpha\n- beta: also break\n\n## Tools"
      assert_received {:assembled, "lead", with_work}
      assert with_work =~ "## Agents\n- alpha\n- beta: also break\n\n## Tools"
      assert_received {:assembled, "beta", without_card}
      refute without_card =~ "## Agents"
    end

    test "assemble lists the workflow of the depth below, and an unnamed work goes through it",
         %{dir: dir} do
      test_pid = self()

      toml =
        agents_toml() <>
          """

          [workflows.flow]
          steps = [{ name = "build", agent = "alpha" }]

          [policy.depth.1]
          workflows = ["flow"]
          """

      Fixtures.write_config(dir, toml)

      Fixtures.use_model(dir, fn assembled, _tools, call ->
        case {role(assembled), last_comment(assembled)} do
          {"lead", nil} ->
            send(test_pid, {:assembled, assembled})
            create(call, "planned", [%{"title" => "A", "goal" => "g"}])

          {"alpha", _comment} ->
            call.("done", %{"report" => "built"})

          _other ->
            call.("end", %{})
        end

        {:ok, "idle"}
      end)

      assert {:ok, ""} = CLI.run(["send", "go"], dir)

      assert_received {:assembled, assembled}

      assert assembled =~
               "## Agents\n- workflow flow: build (alpha); every work goes through it"

      project = Fixtures.open_project(dir)
      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")

      assert [%{assignee: "alpha", stage: "build", state: "done"}] =
               all(project, "SELECT * FROM works WHERE parent_id = ?", [root.id])

      Project.close(project)
    end
  end
end
