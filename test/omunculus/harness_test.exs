defmodule Omunculus.HarnessTest do
  use ExUnit.Case, async: true

  alias Omunculus.{ExecutionPolicyFixtures, Fixtures, Harness, Project, Run, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Test.ChainTool
  alias Omunculus.Tools.Out

  import Omunculus.Fixtures,
    only: [open_project: 1, opening: 1, opening: 2, write_config: 2, write_hook: 4, write_tool: 4]

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    %{dir: dir}
  end

  defp execution(dir), do: ExecutionPolicyFixtures.policy(dir, network: "host")

  test "a project tool named send replaces the builtin without touching the core", %{dir: dir} do
    write_tool(
      dir,
      "send",
      """
      name = "send"
      kind = "tool"
      triggers = ["cli"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": [{"type": "prompt", "body": {"message": "override"}}]}'
      """
    )

    project = open_project(dir)
    model = fn _assembled, _tools, _call -> {:ok, "done"} end

    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil, execution: execution(dir)}

    assert {:ok, %{ok: true}, events} = Harness.dispatch(project, "send", %{}, ctx)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.body == "override"
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")
    Fixtures.use_model(project, model)

    assert :ok = Harness.follow_up(project, events)

    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"

    Project.close(project)
  end

  test "a model's call whose emit is outside the catalogue is recorded as refused, with no emit",
       %{dir: dir} do
    write_tool(
      dir,
      "boom",
      """
      name = "boom"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": [{"type": "nope", "body": {}}]}'
      """
    )

    project = open_project(dir)
    ctx = %{trigger: "model", run_id: nil, author: "agent", agent: nil, execution: execution(dir)}

    assert {:ok, %{ok: false, output: output}, [event]} =
             Harness.dispatch(project, "boom", %{}, ctx)

    assert output == Out.refused({:unknown_action, "nope"})
    assert {:ok, [%{type: "tool"}]} = Query.all(project.conn, "SELECT * FROM events")
    assert %{"ok" => false, "output" => ^output} = Jason.decode!(event.body)

    Project.close(project)
  end

  test "a tool triggered only by model refuses a cli dispatch", %{dir: dir} do
    write_tool(
      dir,
      "modelonly",
      """
      name = "modelonly"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": []}'
      """
    )

    project = open_project(dir)
    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil}

    assert {:error, {:not_triggered, "modelonly", "cli"}} =
             Harness.dispatch(project, "modelonly", %{}, ctx)

    Project.close(project)
  end

  test "the builtin continue and delegate refuse a model dispatch: they are chain steps only",
       %{dir: dir} do
    project = open_project(dir)
    ctx = %{trigger: "model", run_id: nil, author: "agent", agent: nil, execution: execution(dir)}

    for name <- ["continue", "delegate"] do
      assert {:error, {:not_triggered, ^name, "model"}} =
               Harness.dispatch(project, name, %{}, ctx)
    end

    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM events")

    Project.close(project)
  end

  test "a tool with an events view of its run receives the run's events so far", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["counter", "sandbox.network"]
    """)

    write_tool(
      dir,
      "counter",
      """
      name = "counter"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]

      [views.events]
      source = "events"
      relation = "run"
      """,
      """
      #!/bin/sh
      count=$(cat | grep -o '"type"' | wc -l)
      echo "{\\"ok\\": true, \\"output\\": \\"$count\\", \\"emit\\": []}"
      """
    )

    project = open_project(dir)
    message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

    model = fn _assembled, _tools, call ->
      {:ok, output} = call.("counter", %{})
      {:ok, output}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))

    assert {:ok, [event]} =
             Query.all(project.conn, "SELECT * FROM events WHERE type = 'model' AND run_id = ?", [
               run.id
             ])

    assert event.body == "2"

    Project.close(project)
  end

  test "a project tool with work and comments views receives both once the run is on a work",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["work", "end", "viewer", "sandbox.network"]
    """)

    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]

      [views.work]
      source = "works"

      [views.comments]
      source = "comments"
      from = ["work"]
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *title*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

    model = fn assembled, _tools, call ->
      unless assembled =~ "## Work\n",
        do:
          call.("work", %{
            "report" => "opened",
            "works" => [%{"title" => "Fix the parser", "goal" => "Fix the parser"}]
          })

      call.("viewer", %{})
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))

    assert {:ok, [event]} =
             Query.all(
               project.conn,
               "SELECT * FROM events WHERE type = 'model' AND run_id IN (SELECT id FROM runs WHERE work_id IS NOT NULL AND id != ?)",
               [run.id]
             )

    assert event.body == "yes"

    Project.close(project)
  end

  test "a comments view with the default anchors on a work run receives the work's comments", %{
    dir: dir
  } do
    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]

      [views.comments]
      source = "comments"
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *"from the work"*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    Fixtures.insert(project.conn, :comments, %{work_id: work_id, body: "from the work"})
    run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id})

    ctx = %{
      trigger: "model",
      run_id: run_id,
      author: "agent",
      agent: "concierge",
      execution: execution(dir)
    }

    assert {:ok, out, _events} = Harness.dispatch(project, "viewer", %{}, ctx)
    assert out.output == "yes"

    Project.close(project)
  end

  test "an agents view with tools gives each agent a new work may name with its model tools",
       %{dir: dir} do
    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]

      [views.agents]
      source = "agents"
      include = ["tools"]
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *'"name":"worker","tools":['*'"write"'*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id})

    ctx = %{
      trigger: "model",
      run_id: run_id,
      author: "agent",
      agent: "concierge",
      execution: execution(dir)
    }

    assert {:ok, %{output: "yes"}, _events} = Harness.dispatch(project, "viewer", %{}, ctx)

    Project.close(project)
  end

  test "a comments view from the request receives the run's request comments", %{
    dir: dir
  } do
    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]

      [views.comments]
      source = "comments"
      from = ["request"]
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *"need this"*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    request_id = Fixtures.insert(project.conn, :requests)
    Fixtures.insert(project.conn, :comments, %{request_id: request_id, body: "need this"})
    run_id = Fixtures.insert(project.conn, :runs, %{request_id: request_id})

    ctx = %{
      trigger: "model",
      run_id: run_id,
      author: "agent",
      agent: "concierge",
      execution: execution(dir)
    }

    assert {:ok, out, _events} = Harness.dispatch(project, "viewer", %{}, ctx)
    assert out.output == "yes"

    Project.close(project)
  end

  test "an inbox view from the work receives that work's unread notifications",
       %{dir: dir} do
    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]

      [views.inbox]
      source = "inbox"
      from = ["work"]
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *"need to notify"*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    inbox_id = Fixtures.insert(project.conn, :inbox, %{work_id: work_id})
    Fixtures.insert(project.conn, :comments, %{inbox_id: inbox_id, body: "need to notify"})
    run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id})

    ctx = %{
      trigger: "model",
      run_id: run_id,
      author: "agent",
      agent: "concierge",
      execution: execution(dir)
    }

    assert {:ok, out, _events} = Harness.dispatch(project, "viewer", %{}, ctx)
    assert out.output == "yes"

    Project.close(project)
  end

  test "the builtin workspaces tool receives every workspace, marking the run's own", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["workspaces"]

    [workspaces.one]
    root = "one"

    [workspaces.two]
    root = "two"

    [policy]
    workspace = "two"
    """)

    project = open_project(dir)
    ctx = %{trigger: "model", run_id: nil, author: "agent", agent: "concierge"}

    assert {:ok, out, _events} = Harness.dispatch(project, "workspaces", %{}, ctx)

    assert out.output ==
             "one #{Path.join(dir, "one")}\ntwo #{Path.join(dir, "two")} *"

    Project.close(project)
  end

  test "a dispatch with a run_id that does not exist fails", %{dir: dir} do
    write_tool(
      dir,
      "noop",
      """
      name = "noop"
      kind = "tool"
      triggers = ["model"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": []}'
      """
    )

    project = open_project(dir)

    ctx = %{trigger: "model", run_id: "nope", author: "agent", agent: "concierge"}

    assert {:error, {:no_run, "nope"}} = Harness.dispatch(project, "noop", %{}, ctx)

    Project.close(project)
  end

  test "dispatch alone opens no run even when the emit is a prompt", %{dir: dir} do
    write_tool(
      dir,
      "send",
      """
      name = "send"
      kind = "tool"
      triggers = ["cli"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": [{"type": "prompt", "body": {"message": "hi"}}]}'
      """
    )

    project = open_project(dir)
    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil, execution: execution(dir)}

    assert {:ok, %{ok: true}, events} = Harness.dispatch(project, "send", %{}, ctx)
    assert Enum.any?(events, &(&1.type == "prompt"))
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")

    Project.close(project)
  end

  test "follow_up opens a run for a prompt event and drives the model", %{dir: dir} do
    project = open_project(dir)
    message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

    {:ok, event} =
      Omunculus.Store.Events.append(project.conn, %{
        type: "prompt",
        prompt_id: message_id,
        body: "{}"
      })

    Fixtures.use_model(project, fn _assembled, _tools, _call -> {:ok, "done"} end)

    assert :ok =
             Harness.follow_up(project, [event])

    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"
    assert run.cause_id == event.id

    assert {:ok, message} =
             Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [message_id])

    assert message.run_id == run.id

    Project.close(project)
  end

  test "an inbox view receives the unread list outside any run", %{
    dir: dir
  } do
    write_tool(
      dir,
      "peek",
      """
      name = "peek"
      kind = "tool"
      triggers = ["cli"]
      command = ["./run"]

      [views.inbox]
      source = "inbox"
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *concierge*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    Fixtures.insert(project.conn, :inbox, %{agent: "concierge"})

    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil, execution: execution(dir)}

    assert {:ok, %{ok: true, output: "yes"}, _events} =
             Harness.dispatch(project, "peek", %{}, ctx)

    Project.close(project)
  end

  test "tool_search inside a run lists exactly the run's own tools, never a name only on disk",
       %{dir: dir} do
    write_tool(
      dir,
      "granted",
      """
      name = "granted"
      kind = "tool"
      triggers = ["model"]
      description = "A granted tool."
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": []}'
      """
    )

    write_tool(
      dir,
      "blocked",
      """
      name = "blocked"
      kind = "tool"
      triggers = ["model"]
      description = "A blocked tool."
      command = ["./run"]
      """,
      """
      #!/bin/sh
      echo '{"ok": true, "output": "", "emit": []}'
      """
    )

    project = open_project(dir)
    run_id = Fixtures.insert(project.conn, :runs, %{tools: Jason.encode!(["granted"])})
    ctx = %{trigger: "model", run_id: run_id, author: "agent", agent: "concierge"}

    assert {:ok, %{ok: true, output: output}, _events} =
             Harness.dispatch(project, "tool_search", %{}, ctx)

    assert output =~ "- granted:"
    refute output =~ "blocked"

    Project.close(project)
  end

  test "tool_search outside any run sees an empty catalog view", %{dir: dir} do
    project = open_project(dir)
    ctx = %{trigger: "model", run_id: nil, author: "agent", agent: "concierge"}

    assert {:ok, %{ok: true, output: output}, _events} =
             Harness.dispatch(project, "tool_search", %{}, ctx)

    assert output == Out.no_tools_found()

    Project.close(project)
  end

  test "a broken hook fails the dispatch but the triggering call's own store write already committed",
       %{dir: dir} do
    write_hook(
      dir,
      "on-notify",
      """
      name = "on-notify"
      kind = "hook"
      events = ["notify"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      exit 1
      """
    )

    project = open_project(dir)
    run_id = Fixtures.insert(project.conn, :runs, %{})
    ctx = %{trigger: "model", run_id: run_id, author: "agent", agent: "concierge"}

    assert {:error, _reason} = Harness.dispatch(project, "notify", %{"body" => "hi"}, ctx)

    assert {:ok, [_inbox_row]} = Query.all(project.conn, "SELECT * FROM inbox")

    Project.close(project)
  end

  describe "chains" do
    setup %{dir: dir} do
      chain_config(dir)

      ChainTool.write(dir, "alpha", """
      triggers = ["model"]
      chains = ["alpha", "beta", "comment", "delta", "end", "gamma"]
      """)

      ChainTool.write(dir, "beta", """
      triggers = ["chain"]
      chains = ["alpha", "comment"]
      """)

      ChainTool.write(dir, "gamma", ~s(triggers = ["model", "chain"]))
      ChainTool.write(dir, "delta", ~s(triggers = ["model"]))

      ChainTool.write(dir, "omega", """
      triggers = ["model"]
      chains = ["beta", "comment", "end"]
      then = ["beta", "end"]
      """)

      project = open_project(dir)
      on_exit(fn -> Project.close(project) end)
      work_id = Fixtures.insert(project.conn, :works)
      %{project: project, work_id: work_id}
    end

    defp chain_config(dir, overrides \\ "") do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"
      tools = ["alpha", "beta", "comment", "delta", "end", "omega"]

      #{overrides}
      """)
    end

    defp outside_run, do: %{trigger: "model", run_id: nil, author: "agent", agent: "concierge"}

    defp comment_emit(work_id, body),
      do: %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => body}}

    defp step(name, args \\ %{}), do: %{"name" => name, "args" => args}

    defp tool_calls(conn) do
      {:ok, events} =
        Query.all(conn, "SELECT * FROM events WHERE type = 'tool' ORDER BY sequence")

      Enum.map(events, &Jason.decode!(&1.body))
    end

    defp comment_bodies(conn) do
      {:ok, comments} = Query.all(conn, "SELECT body FROM comments ORDER BY created_at")
      Enum.map(comments, & &1.body)
    end

    test "out.chain runs its steps after the tool, each recorded with via", %{
      project: project,
      work_id: work_id
    } do
      args = %{
        "emit" => [comment_emit(work_id, "alpha")],
        "chain" => [
          step("beta", %{
            "chain" => [step("comment", %{"body" => "nested", "work_id" => work_id})]
          })
        ]
      }

      assert {:ok, %{ok: true, output: "alpha"}, events} =
               Harness.dispatch(project, "alpha", args, outside_run())

      assert Enum.map(events, & &1.type) == ["tool", "comment", "tool", "tool", "comment"]

      assert [
               %{"name" => "alpha"} = alpha,
               %{"name" => "beta", "via" => "alpha"},
               %{"name" => "comment", "via" => "beta"}
             ] = tool_calls(project.conn)

      refute Map.has_key?(alpha, "via")
      assert comment_bodies(project.conn) == ["alpha", "nested"]
    end

    test "inside a run then runs after out.chain, in order, and its end ends the run", %{
      dir: dir,
      project: project,
      work_id: work_id
    } do
      test_pid = self()

      model = fn _assembled, _tools, call ->
        call.("omega", %{"chain" => [step("comment", %{"body" => "first"})]})
        send(test_pid, :reached_after_end)
        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)
      message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

      assert {:ok, run} = Run.open(project, opening(message_id, work_id))
      refute_received :reached_after_end

      assert Enum.map(tl(tool_calls(project.conn)), &{&1["name"], &1["via"]}) == [
               {"omega", nil},
               {"comment", "omega"},
               {"beta", "omega"},
               {"end", "omega"}
             ]

      assert comment_bodies(project.conn) == ["first"]
      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      assert Enum.map(events, & &1.type) |> Enum.take(-2) == ["end", "end-run"]
    end

    for {name, chain, failed_at, reason} <- [
          {"a step outside chains", [{"gamma", %{}}, {"omega", %{}}], "omega", :not_chainable},
          {"a step without the chain trigger", [{"delta", %{}}], "delta", :not_triggered},
          {"a loop", [{"beta", %{"chain" => [%{"name" => "alpha"}]}}], "alpha", :loop},
          {"a step after end", [{"end", %{}}, {"beta", %{}}], "beta", :after_end},
          {"a failing middle step", [{"beta", %{}}, {"beta", %{"fail" => true}}, {"end", %{}}],
           "beta", {:failed, "beta"}}
        ] do
      test "#{name} refuses the whole chain and writes none of its emits", %{
        project: project,
        work_id: work_id
      } do
        steps = Enum.map(unquote(Macro.escape(chain)), fn {name, args} -> step(name, args) end)

        args = %{
          "emit" => [comment_emit(work_id, "alpha")],
          "chain" => [step("comment", %{"body" => "stepped", "work_id" => work_id}) | steps]
        }

        assert {:ok, %{ok: false, output: output}, [event]} =
                 Harness.dispatch(project, "alpha", args, outside_run())

        assert output == Out.chain_failed(unquote(failed_at), unquote(Macro.escape(reason)))
        assert event.type == "tool"
        assert [%{"name" => "alpha", "ok" => false}] = tool_calls(project.conn)
        assert comment_bodies(project.conn) == []
      end
    end

    test "a step emit that fails to apply leaves only the refused call recorded", %{
      project: project,
      work_id: work_id
    } do
      args = %{
        "emit" => [comment_emit(work_id, "alpha")],
        "chain" => [
          step("comment", %{"body" => "stepped", "work_id" => work_id}),
          step("beta", %{"emit" => [comment_emit("nope", "broken")]})
        ]
      }

      assert {:ok, %{ok: false, output: output}, _events} =
               Harness.dispatch(project, "alpha", args, outside_run())

      assert output == Out.refused({:comment, {:missing, :works, "nope"}})
      assert {:ok, [%{type: "tool"}]} = Query.all(project.conn, "SELECT * FROM events")
      assert comment_bodies(project.conn) == []
    end

    test "inside a run a step that is not have fails the chain and the run goes on", %{
      dir: dir,
      project: project,
      work_id: work_id
    } do
      test_pid = self()

      model = fn _assembled, tools, call ->
        send(test_pid, {:cards, Enum.map(tools, & &1.name)})
        send(test_pid, {:beta, call.("beta", %{})})

        send(
          test_pid,
          {:gamma,
           call.("alpha", %{
             "chain" => [step("comment", %{"body" => "stepped"}), step("gamma")]
           })}
        )

        send(test_pid, {:chained, call.("alpha", %{"chain" => [step("beta")]})})
        {:ok, "went on"}
      end

      Fixtures.use_model(dir, model)
      message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

      assert {:ok, run} = Run.open(project, opening(message_id, work_id))

      assert_received {:cards, cards}
      assert cards == ["alpha", "comment", "delta", "end", "omega"]
      assert_received {:beta, {:error, refused}}
      assert refused == Out.not_yours("beta")
      assert_received {:gamma, {:ok, gamma_output}}
      assert gamma_output == Out.chain_failed("gamma", :not_have)
      assert_received {:chained, {:ok, "alpha"}}

      assert [reason, _inbox] = comment_bodies(project.conn)
      assert reason =~ ~r/stopped the work ".+" without a report after 1 run\.$/

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})

      # The refused beta is recorded too, failed.
      assert Enum.map(events, & &1.type) == [
               "start-run",
               "tool",
               "tool",
               "tool",
               "tool",
               "tool",
               "model",
               "end-run",
               "request",
               "notify",
               "tool",
               "tool"
             ]
    end

    test "an override then = [] keeps the manifest's end from ending the run", %{
      dir: dir,
      project: project,
      work_id: work_id
    } do
      chain_config(dir, """
      [agents.concierge.overrides.omega]
      then = []
      """)

      test_pid = self()

      model = fn _assembled, _tools, call ->
        send(test_pid, {:omega, call.("omega", %{})})
        {:ok, "went on"}
      end

      Fixtures.use_model(dir, model)
      message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

      assert {:ok, run} = Run.open(project, opening(message_id, work_id))
      assert_received {:omega, {:ok, "omega"}}
      # The model stops without end, so the harness asks the human about the root work.
      assert Enum.map(tl(tool_calls(project.conn)), & &1["name"]) ==
               ["omega", "on-request", "on-notify"]

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})

      assert Enum.map(events, & &1.type) == [
               "start-run",
               "tool",
               "tool",
               "model",
               "end-run",
               "request",
               "notify",
               "tool",
               "tool"
             ]
    end

    test "an override chains restricts what the tool may chain", %{
      dir: dir,
      project: project
    } do
      chain_config(dir, """
      [policy.overrides.alpha]
      chains = ["comment", "end"]
      """)

      assert {:ok, %{ok: false, output: output}, _events} =
               Harness.dispatch(project, "alpha", %{"chain" => [step("beta")]}, outside_run())

      assert output == Out.chain_failed("beta", :not_chainable)
    end

    for {name, overrides, reason} <- [
          {"chains wider than the manifest's",
           ~s([policy.overrides.beta]\nchains = ["alpha", "gamma"]),
           {:overrides, "beta", {:not_chainable, "gamma"}}},
          {"a then with end before the last name",
           ~s([policy.overrides.omega]\nthen = ["end", "beta"]),
           {:overrides, "omega", {:invalid, :then}}},
          {"chains that leave the manifest's then outside",
           ~s([policy.overrides.omega]\nchains = ["comment", "end"]),
           {:overrides, "omega", {:invalid, :then}}},
          {"an unknown schema variant", ~s([policy.overrides.alpha]\nschema = "nope"),
           {:overrides, "alpha", {:unknown_schema, "nope"}}}
        ] do
      test "#{name} fails the call and keeps the run from opening", %{
        dir: dir,
        project: project,
        work_id: work_id
      } do
        chain_config(dir, unquote(overrides))
        test_pid = self()
        Fixtures.use_model(dir, fn _assembled, _tools, _call -> send(test_pid, :model) end)
        message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})
        reason = unquote(Macro.escape(reason))

        assert {:error, ^reason} = Harness.dispatch(project, "delta", %{}, outside_run())
        assert {:error, ^reason} = Run.open(project, opening(message_id, work_id))
        refute_received :model
        assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")
      end
    end

    test "an override schema is the parameters the model and the CLI see", %{
      dir: dir,
      project: project,
      work_id: work_id
    } do
      ChainTool.write(dir, "delta", """
      triggers = ["model"]

      [parameters]
      type = "object"
      required = ["body"]

      [schemas.short]
      type = "object"
      """)

      chain_config(dir, """
      [policy.overrides.delta]
      schema = "short"
      """)

      test_pid = self()

      model = fn _assembled, tools, _call ->
        send(test_pid, {:tools, Map.new(tools, &{&1.name, &1.parameters})})
        {:ok, "done"}
      end

      Fixtures.use_model(dir, model)
      message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

      assert {:ok, _run} = Run.open(project, opening(message_id, work_id))
      assert_received {:tools, %{"alpha" => %{}, "delta" => %{"type" => "object"}}}
      assert {:ok, manifest} = Harness.manifest(project, "delta")
      assert manifest.parameters == %{"type" => "object"}
    end
  end
end
