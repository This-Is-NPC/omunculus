defmodule Omunculus.Tools.WorkTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Id, Project, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Out, Work}

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
                 %{"type" => "work", "body" => Map.put(@item, "report", "planned")}
               ]
             }
    end

    test "without a work, two items fail" do
      input = without_work(%{"report" => "planned", "works" => [@item, @item]})

      assert Work.run(input) == Out.fail("a run without a work creates one work")
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
      dir = Path.join(System.tmp_dir!(), Id.new())
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    @creator ~w(comment continue delegate done end work)

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

    defp role(assembled), do: assembled |> String.split("\n", parts: 2) |> hd()

    defp last_comment(assembled) do
      case String.split(assembled, "## Last comment\n", parts: 2) do
        [_before, rest] -> rest |> String.split("\n\n", parts: 2) |> hd()
        [_none] -> nil
      end
    end

    defp create(call, report, works), do: call.("work", %{"report" => report, "works" => works})

    defp setup_project(dir, toml, model) do
      Fixtures.write_config(dir, toml)
      Fixtures.use_model(dir, model)
      assert {:ok, ""} = CLI.run(["send", "go"], dir)
      {:ok, project} = Fixtures.open_project(dir)
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

    defp root_model(on_root) do
      fn assembled, _tools, call ->
        case {role(assembled), last_comment(assembled)} do
          {"lead", nil} -> create(call, "planned", [%{"title" => "Root", "goal" => "Ship"}])
          other -> on_root.(other, call)
        end

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

    test "with a workflow at depth 0 the root starts at the first stage and its run opens",
         %{dir: dir} do
      toml =
        agents_toml() <>
          """

          [workflows.flow]
          steps = [{ name = "plan", agent = "lead" }]

          [policy]
          workflow = "flow"

          [policy.overrides.work]
          schema = "staged"
          """

      project = setup_project(dir, toml, root_model(fn _other, _call -> :ok end))

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
              %{"title" => "A", "goal" => "Goal A"},
              %{"title" => "B", "goal" => "Goal B"}
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

      runs = runs_in_order(project)
      [a, b] = Enum.map(children, & &1.id)
      assert Enum.map(runs, & &1.work_id) == [root.id, root.id, a, b, root.id]

      continues =
        for %{type: "continue", work_id: id, body: body} <- all(project, "SELECT * FROM events"),
            into: %{},
            do: {id, Jason.decode!(body)["parent_id"]}

      assert continues == %{a => nil, b => root.id}

      Project.close(project)
    end

    test "a child's break reopens the waiting work at once; a named allowed agent takes the child",
         %{dir: dir} do
      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [
              %{"title" => "A", "goal" => "Goal A", "agent" => "beta"},
              %{"title" => "B", "goal" => "Goal B"}
            ])

          {"beta", _comment}, call ->
            call.("break", %{"body" => "stuck"})

          {"alpha", _comment}, call ->
            call.("done", %{"report" => "finished"})

          _other, _call ->
            :ok
        end)

      project = setup_project(dir, agents_toml(), model)

      assert [root] = all(project, "SELECT * FROM works WHERE parent_id IS NULL")

      assert [%{assignee: "beta", state: "waiting"} = a, %{assignee: "alpha", state: "done"} = b] =
               all(project, "SELECT * FROM works WHERE parent_id = ? ORDER BY title", [root.id])

      runs = runs_in_order(project)
      assert Enum.map(runs, & &1.work_id) == [root.id, root.id, a.id, root.id, b.id]

      Project.close(project)
    end

    test "a child with work creates grandchildren at depth 2 under its own work", %{dir: dir} do
      model =
        root_model(fn
          {"lead", "planned"}, call ->
            create(call, "split", [%{"title" => "A", "goal" => "Goal A"}])

          {"alpha", nil}, call ->
            create(call, "sub", [
              %{"title" => "A1", "goal" => "Goal A1"},
              %{"title" => "A2", "goal" => "Goal A2"}
            ])

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

      assert ["sub"] =
               project
               |> all("SELECT body FROM comments WHERE work_id = ?", [child.id])
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

      assert_received {:work, {:error, {:not_allowed, "work"}}}
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
        assert_received {^agent, {:error, {:delegate, {:agent_not_allowed, ^agent}}}}
      end

      assert [_root] = all(project, "SELECT * FROM works")
      assert [%{body: "planned"}] = all(project, "SELECT * FROM comments")

      Project.close(project)
    end

    test "with a workflow at the child's depth a named agent is refused and the staged schema is served",
         %{dir: dir} do
      test_pid = self()

      model =
        root_model(fn
          {"lead", "planned"}, call ->
            send(
              test_pid,
              {:named,
               create(call, "split", [%{"title" => "A", "goal" => "g", "agent" => "alpha"}])}
            )

          _other, _call ->
            :ok
        end)

      toml =
        agents_toml() <>
          """

          [workflows.flow]
          steps = [{ name = "build", agent = "alpha" }, { name = "check", agent = "checker" }]

          [policy.depth.1]
          workflow = "flow"

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
      {:ok, project} = Fixtures.open_project(dir)

      assert_received {:named, {:error, {:delegate, :agent_with_workflow}}}
      assert_received {:schema, "lead", staged}
      refute Map.has_key?(staged["properties"]["works"]["items"]["properties"], "agent")
      assert [_root] = all(project, "SELECT * FROM works")

      Project.close(project)
    end

    test "without a work, two items or a missing goal fail and write nothing", %{dir: dir} do
      test_pid = self()

      model = fn _assembled, _tools, call ->
        send(test_pid, {:two, create(call, "r", [@item, @item])})
        send(test_pid, {:no_goal, create(call, "r", [%{"title" => "t"}])})
        {:ok, "idle"}
      end

      project = setup_project(dir, agents_toml(), model)

      assert_received {:two, {:ok, "a run without a work creates one work"}}
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
      assert without_work =~ "## Agents\n- lead\n\n## Tools"
      assert_received {:assembled, "lead", with_work}
      assert with_work =~ "## Agents\n- alpha\n- beta\n\n## Tools"
      assert_received {:assembled, "beta", without_card}
      refute without_card =~ "## Agents"
    end

    test "assemble lists no agents when the depth below has a workflow", %{dir: dir} do
      test_pid = self()

      toml =
        agents_toml() <>
          """

          [workflows.flow]
          steps = [{ name = "build", agent = "alpha" }]

          [policy.depth.1]
          workflow = "flow"
          """

      Fixtures.write_config(dir, toml)

      Fixtures.use_model(
        dir,
        root_model(fn {"lead", "planned"}, _call -> send(test_pid, :root_run) end)
        |> then(fn model ->
          fn assembled, tools, call ->
            if last_comment(assembled) == "planned",
              do: send(test_pid, {:assembled, assembled})

            model.(assembled, tools, call)
          end
        end)
      )

      assert {:ok, ""} = CLI.run(["send", "go"], dir)

      assert_received :root_run
      assert_received {:assembled, assembled}
      refute assembled =~ "## Agents"
    end
  end
end
