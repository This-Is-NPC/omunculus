defmodule Omunculus.CLITest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Config, Fixtures, Id, Project, Store}
  alias Omunculus.Store.Query

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp open(dir) do
    {:ok, project} = Project.open(dir)
    project
  end

  defp write_config(dir, contents), do: File.write!(Path.join(dir, "omunculus.toml"), contents)

  defp write_tool(dir, name) do
    tool_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(tool_dir)

    File.write!(Path.join(tool_dir, "tool.toml"), """
    name = "#{name}"
    kind = "tool"
    triggers = ["model"]
    command = ["./run"]
    """)

    run_path = Path.join(tool_dir, "run")

    File.write!(run_path, """
    #!/bin/sh
    echo '{"ok": true, "output": "", "emit": []}'
    """)

    File.chmod!(run_path, 0o755)
  end

  defp write_emit_tool(dir, name, emit_json) do
    tool_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(tool_dir)

    File.write!(Path.join(tool_dir, "tool.toml"), """
    name = "#{name}"
    kind = "tool"
    triggers = ["model"]
    command = ["./run"]
    """)

    run_path = Path.join(tool_dir, "run")
    File.write!(run_path, "#!/bin/sh\necho '#{emit_json}'\n")
    File.chmod!(run_path, 0o755)
  end

  test "send delivers a message, opens a run and the run reaches done", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "conte até 5"], dir)

    project = open(dir)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.run_id != nil

    assert {:ok, [assembled]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'assembled'")

    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"
    assert run.agent == "concierge"
    assert run.depth == "0"
    assert run.prompt_id == assembled.id

    assert {:ok, events} = Store.replay(project.conn, :project)
    assert Enum.map(events, & &1.type) == ["tool", "prompt", "start-run", "model", "end-run"]

    assert assembled.body =~ "conte até 5"
    assert assembled.body =~ "tools.*"
    refute assembled.body =~ "send"

    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM works")

    Project.close(project)
  end

  test "the --message form works", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "--message", "hello"], dir)

    project = open(dir)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.body == "hello"

    Project.close(project)
  end

  test "an unknown tool errors", %{dir: dir} do
    assert {:error, {:unknown_tool, "nope"}} = CLI.run(["nope"], dir)
  end

  test "send with no args fails and reports the tool's own output", %{dir: dir} do
    assert {:error, {:tool_failed, "message required"}} = CLI.run(["send"], dir)
  end

  test "a second send never reuses the old assembled prompt", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "first"], dir)
    assert {:ok, ""} = CLI.run(["send", "second"], dir)

    project = open(dir)

    assert {:ok, assembleds} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'assembled'")

    assert length(assembleds) == 2
    assert assembleds |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2

    Project.close(project)
  end

  describe "work + comment" do
    setup do
      on_exit(fn -> Application.delete_env(:omunculus, :model) end)
      :ok
    end

    test "the concierge creates the work, a follow-up comments on it, and a third opening sees the last comment",
         %{dir: dir} do
      Application.put_env(:omunculus, :model, fn _assembled, call ->
        assert {:ok, ""} = call.("work", %{"title" => "Contar até cinco"})
        {:ok, "ok"}
      end)

      assert {:ok, ""} = CLI.run(["send", "Contar até 5"], dir)

      project = open(dir)

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.title == "Contar até cinco"
      assert work.title != "Contar até 5"
      assert work.assignee == "concierge"

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.work_id == work.id

      assert {:ok, events} = Store.replay(project.conn, :project)

      assert Enum.map(events, & &1.type) ==
               ["tool", "prompt", "start-run", "tool", "work", "model", "end-run"]

      assert {:ok, [first_assembled]} =
               Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'assembled'")

      Project.close(project)

      test_pid = self()

      Application.put_env(:omunculus, :model, fn assembled, call ->
        send(test_pid, {:second_assembled, assembled})
        assert {:ok, ""} = call.("comment", %{"body" => "primeiro comment"})
        {:ok, "done"}
      end)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "continua"], dir)

      assert_received {:second_assembled, second_assembled}
      assert second_assembled =~ "## Work"
      assert second_assembled =~ work.title
      assert second_assembled =~ "## Message\ncontinua"
      refute second_assembled =~ "Contar até 5"
      refute second_assembled =~ first_assembled.body

      project = open(dir)

      assert {:ok, [comment]} = Query.all(project.conn, "SELECT * FROM comments")
      assert comment.work_id == work.id
      assert comment.body == "primeiro comment"

      Project.close(project)

      Application.put_env(:omunculus, :model, fn assembled, _call ->
        send(test_pid, {:third_assembled, assembled})
        {:ok, "seen"}
      end)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "mais"], dir)

      assert_received {:third_assembled, third_assembled}
      assert third_assembled =~ "## Last comment"
      assert third_assembled =~ "primeiro comment"
    end

    test "send --work_id pointing at a work that does not exist refuses and leaves events untouched",
         %{dir: dir} do
      assert {:error, {:prompt, {:missing, :works, "nope"}}} =
               CLI.run(["send", "--work_id", "nope", "x"], dir)

      project = open(dir)
      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM events")
      Project.close(project)
    end
  end

  describe "request and reply" do
    setup %{dir: dir} do
      write_tool(dir, "write")
      on_exit(fn -> Application.delete_env(:omunculus, :model) end)
      :ok
    end

    defp open_write_request(dir, work_id \\ nil) do
      Application.put_env(:omunculus, :model, fn _assembled, call ->
        call.("request_access", %{
          "kind" => "tool",
          "name" => "write",
          "reason" => "preciso gravar"
        })

        {:ok, "unused"}
      end)

      args =
        if work_id,
          do: ["send", "--work_id", work_id, "grava isso"],
          else: ["send", "grava isso"]

      assert {:ok, ""} = CLI.run(args, dir)

      project = open(dir)
      assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
      Project.close(project)

      request.id
    end

    test "an askable request opens REQUESTS waiting_human, comments the reason, and marks a linked work waiting for access",
         %{dir: dir} do
      project = open(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "waiting_human"
      assert request.arbiter == "human"
      assert Jason.decode!(request.ask) == %{"kind" => "tool", "name" => "write"}

      assert {:ok, [comment]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE request_id = ?", [
                 request_id
               ])

      assert comment.body == "preciso gravar"

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.waiting == "access"
      assert work.waiting_for == "write"

      Project.close(project)
    end

    test "reply grant adds the name to works.grants, reopens the work, and opens a new run on the same stage with the granted tool",
         %{dir: dir} do
      project = open(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open(dir)
      assert {:ok, [old_run]} = Query.all(project.conn, "SELECT * FROM runs")
      Project.close(project)

      Application.put_env(:omunculus, :model, fn _assembled, _call -> {:ok, "obrigado"} end)

      assert {:ok, ""} =
               CLI.run(["reply", "--request_id", request_id, "--decision", "grant", "pode"], dir)

      project = open(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "closed"

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["write"]
      assert work.state == "open"

      assert {:ok, runs} =
               Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [work_id])

      assert length(runs) == 2
      new_run = Enum.find(runs, &(&1.id != old_run.id))
      assert "write" in Jason.decode!(new_run.tools)
      refute "write" in Jason.decode!(old_run.tools)

      assert {:ok, new_assembled} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [new_run.prompt_id])

      assert new_assembled.body =~ "## Work"
      refute new_assembled.body =~ "## Message"

      Project.close(project)
    end

    test "reply grant with scope agent writes the permanent grant to the project's omunculus.toml, leaves works.grants untouched, and a fresh work also gets the tool",
         %{dir: dir} do
      project = open(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      Application.put_env(:omunculus, :model, fn _assembled, _call -> {:ok, "obrigado"} end)

      assert {:ok, ""} =
               CLI.run(
                 [
                   "reply",
                   "--request_id",
                   request_id,
                   "--decision",
                   "grant",
                   "--scope",
                   "agent",
                   "pode para sempre"
                 ],
                 dir
               )

      project = open(dir)
      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.grants == nil
      Project.close(project)

      assert {:ok, config} = Config.load(dir)
      assert "write" in config.agents["concierge"].ceiling.granted

      project = open(dir)
      other_work_id = Fixtures.insert(project.conn, :works, %{title: "Another one"})
      Project.close(project)

      Application.put_env(:omunculus, :model, fn _assembled, _call -> {:ok, "ok"} end)
      assert {:ok, ""} = CLI.run(["send", "--work_id", other_work_id, "novo pedido"], dir)

      project = open(dir)

      assert {:ok, [run]} =
               Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [other_work_id])

      assert "write" in Jason.decode!(run.tools)
      Project.close(project)
    end

    test "a blocked request denies immediately, opens no REQUESTS row, and the run reaches done",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"
      tools = ["comment", "request_access", "work"]
      deny = ["write"]
      """)

      Application.put_env(:omunculus, :model, fn _assembled, call ->
        call.("request_access", %{"kind" => "tool", "name" => "write", "reason" => "preciso"})
        {:ok, "unused"}
      end)

      assert {:ok, ""} = CLI.run(["send", "grava"], dir)

      project = open(dir)

      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM requests")

      assert {:ok, events} = Store.replay(project.conn, :project)
      assert "deny" in Enum.map(events, & &1.type)

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.status == "done"

      Project.close(project)
    end

    test "requesting a name the run already has does not open REQUESTS and lets the model keep calling tools",
         %{dir: dir} do
      test_pid = self()

      Application.put_env(:omunculus, :model, fn _assembled, call ->
        assert {:ok, output} =
                 call.("request_access", %{
                   "kind" => "tool",
                   "name" => "comment",
                   "reason" => "só confirmando"
                 })

        send(test_pid, {:output, output})
        {:ok, "seguindo"}
      end)

      assert {:ok, ""} = CLI.run(["send", "oi"], dir)

      assert_received {:output, output}
      assert output =~ "already granted: comment"

      project = open(dir)
      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM requests")

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.status == "done"

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      assert "model" in Enum.map(events, & &1.type)

      Project.close(project)
    end

    test "reply deny closes the request, reopens the work, and opens no new run", %{dir: dir} do
      project = open(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open(dir)
      assert {:ok, [old_run]} = Query.all(project.conn, "SELECT * FROM runs")
      Project.close(project)

      Application.put_env(:omunculus, :model, fn _assembled, _call -> {:ok, "obrigado"} end)

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--decision", "deny", "não pode"],
                 dir
               )

      project = open(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "closed"

      assert {:ok, events} = Store.replay(project.conn, :project)
      deny_event = Enum.find(events, &(&1.type == "deny"))
      assert deny_event.request_id == request_id

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "open"

      assert {:ok, runs} =
               Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [work_id])

      assert length(runs) == 1
      assert hd(runs).id == old_run.id

      Project.close(project)
    end

    test "a request without a linked work has no work_id, and granting it opens no run and touches no work",
         %{dir: dir} do
      request_id = open_write_request(dir)

      project = open(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.work_id == nil
      Project.close(project)

      Application.put_env(:omunculus, :model, fn _assembled, _call ->
        raise "must never be called"
      end)

      assert {:ok, ""} =
               CLI.run(["reply", "--request_id", request_id, "--decision", "grant", "pode"], dir)

      project = open(dir)
      assert {:ok, events} = Store.replay(project.conn, :project)
      assert "grant" in Enum.map(events, & &1.type)

      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM works")

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs")
      assert length(runs) == 1

      Project.close(project)
    end

    test "replying twice to the same request fails the second time", %{dir: dir} do
      request_id = open_write_request(dir)

      Application.put_env(:omunculus, :model, fn _assembled, _call -> {:ok, "obrigado"} end)

      assert {:ok, ""} =
               CLI.run(["reply", "--request_id", request_id, "--decision", "grant", "pode"], dir)

      assert {:error, {:reply, :closed}} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--decision", "grant", "de novo"],
                 dir
               )
    end
  end

  describe "sequence and child" do
    setup do
      on_exit(fn -> Application.delete_env(:omunculus, :model) end)
      :ok
    end

    test "D0-H0-W1: continue moves a work through the workflow's steps and the last stage closes it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "Sou o concierge."
      tools = ["work", "continue", "comment"]

      [agents.reviewer]
      depth = 0
      text = "Sou o reviewer."
      tools = ["work", "continue", "comment"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "reviewer", deny = ["work"] },
      ]

      [policy]
      workflow = "delivery"
      """)

      Application.put_env(:omunculus, :model, fn assembled, call ->
        cond do
          assembled =~ "Sou o concierge." ->
            assert {:ok, ""} = call.("work", %{"title" => "Ship it"})
            call.("continue", %{})
            {:ok, "unused"}

          assembled =~ "Sou o reviewer." ->
            call.("continue", %{})
            {:ok, "unused"}
        end
      end)

      assert {:ok, ""} = CLI.run(["send", "Ship it please"], dir)

      project = open(dir)

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "done"
      assert work.stage == "review"

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 2
      [run1, run2] = runs

      assert run1.agent == "concierge"
      assert run2.agent == "reviewer"
      assert run2.depth == "0"
      assert run2.via == "continue"

      assert {:ok, events1} = Store.replay(project.conn, {:run, run1.id})
      refute "model" in Enum.map(events1, & &1.type)
      assert List.last(events1).type == "end-run"
      assert Enum.at(events1, -2).type == "continue"

      assert {:ok, assembled2} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [run2.prompt_id])

      assert assembled2.body =~ "## Work"
      refute assembled2.body =~ "- work:"

      Project.close(project)
    end

    test "continue is refused while the workflow is off and the run keeps going", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "continue"]
      """)

      Application.put_env(:omunculus, :model, fn _assembled, call ->
        assert {:ok, ""} = call.("work", %{"title" => "No sequence"})
        assert {:error, {:continue, :workflow_off}} = call.("continue", %{})
        {:ok, "seguindo mesmo assim"}
      end)

      assert {:ok, ""} = CLI.run(["send", "oi"], dir)

      project = open(dir)

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.status == "done"

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      assert "model" in Enum.map(events, & &1.type)

      Project.close(project)
    end

    test "a continue emit naming a stage is refused by the store", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "bad_continue"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "concierge" },
      ]

      [policy]
      workflow = "delivery"
      """)

      write_emit_tool(
        dir,
        "bad_continue",
        ~s({"ok": true, "output": "", "emit": [{"type": "continue", "body": {"stage": "review"}}]})
      )

      Application.put_env(:omunculus, :model, fn _assembled, call ->
        assert {:ok, ""} = call.("work", %{"title" => "Ship it"})

        assert {:error, {:continue, {:forbidden, "stage"}}} = call.("bad_continue", %{})

        {:ok, "seguindo"}
      end)

      assert {:ok, ""} = CLI.run(["send", "oi"], dir)

      project = open(dir)
      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.stage == "to_do"
      Project.close(project)
    end

    test "a grant on the work survives a stage deny: the effective set loses it but works.grants keeps it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["counter", "continue"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "concierge", deny = ["counter"] },
      ]

      [policy]
      workflow = "delivery"
      """)

      write_tool(dir, "counter")

      project = open(dir)

      work_id =
        Fixtures.insert(project.conn, :works, %{
          stage: "to_do",
          assignee: "concierge",
          grants: ~s(["counter"])
        })

      Project.close(project)

      Application.put_env(:omunculus, :model, fn assembled, call ->
        if assembled =~ "- counter:" do
          call.("continue", %{})
          {:ok, "unused"}
        else
          {:ok, "done"}
        end
      end)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "segue"], dir)

      project = open(dir)

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 2
      review_run = List.last(runs)
      refute "counter" in Jason.decode!(review_run.tools)

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["counter"]

      Project.close(project)
    end

    test "break parks the work with a comment without moving the stage, and a later send reopens a run on it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "break", "comment"]

      [workflows.solo]
      steps = [{ name = "to_do", agent = "concierge" }]

      [policy]
      workflow = "solo"
      """)

      Application.put_env(:omunculus, :model, fn _assembled, call ->
        assert {:ok, ""} = call.("work", %{"title" => "Precisa de ajuda"})
        call.("break", %{"body" => "preciso pausar"})
        {:ok, "unused"}
      end)

      assert {:ok, ""} = CLI.run(["send", "cuide disso"], dir)

      project = open(dir)
      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "waiting"
      assert work.stage == "to_do"
      assert work.waiting_from == "concierge"

      assert {:ok, [comment]} = Query.all(project.conn, "SELECT * FROM comments")
      assert comment.body == "preciso pausar"

      assert {:ok, [run1]} = Query.all(project.conn, "SELECT * FROM runs")
      Project.close(project)

      Application.put_env(:omunculus, :model, fn _assembled, _call -> {:ok, "voltei"} end)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "volta"], dir)

      project = open(dir)

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs")
      assert length(runs) == 2
      run2 = Enum.find(runs, &(&1.id != run1.id))
      assert run2.agent == "concierge"

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work.id])
      assert work.stage == "to_do"

      Project.close(project)
    end

    test "D1-H0-W0: delegate opens a child run, the child finishing wakes the parent, and the parent's end-run precedes the child's start-run",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "Sou o concierge."
      tools = ["work", "delegate", "comment"]

      [agents.worker]
      depth = 1
      text = "Sou o worker."
      tools = ["comment"]
      """)

      Application.put_env(:omunculus, :model, fn assembled, call ->
        cond do
          assembled =~ "Sou o worker." ->
            {:ok, "feito"}

          assembled =~ "## Work" ->
            {:ok, "acompanhando"}

          true ->
            assert {:ok, ""} = call.("work", %{"title" => "Big task"})

            assert {:ok, ""} =
                     call.("delegate", %{"title" => "Sub task", "body" => "faça isso"})

            {:ok, "unused"}
        end
      end)

      assert {:ok, ""} = CLI.run(["send", "Big task please"], dir)

      project = open(dir)

      assert {:ok, works} = Query.all(project.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert parent.state == "open"
      assert child.state == "done"
      assert child.assignee == "worker"
      assert child.parent_id == parent.id

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 3
      [run1, run2, run3] = runs

      assert run1.agent == "concierge"
      assert run2.agent == "worker"
      assert run2.depth == "1"
      assert run2.via == "delegate"
      assert run3.agent == "concierge"
      assert run3.depth == "0"

      assert {:ok, assembled2} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [run2.prompt_id])

      assert assembled2.body =~ "Sub task"
      assert assembled2.body =~ "## Last comment\nfaça isso"

      assert {:ok, project_events} = Store.replay(project.conn, :project)

      end_run1 = Enum.find(project_events, &(&1.type == "end-run" and &1.run_id == run1.id))
      start_run2 = Enum.find(project_events, &(&1.type == "start-run" and &1.run_id == run2.id))
      assert end_run1.sequence < start_run2.sequence

      Project.close(project)
    end

    test "D1-H0-W1: the child follows its own depth-scoped workflow through the parent's agents",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "Sou o concierge."
      tools = ["work", "delegate", "comment", "continue"]

      [agents.worker]
      depth = 1
      text = "Sou o worker."
      tools = ["comment", "continue"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "worker" },
        { name = "review", agent = "concierge" },
      ]

      [policy.depth.1]
      workflow = "delivery"
      """)

      Application.put_env(:omunculus, :model, fn assembled, call ->
        cond do
          assembled =~ "Sou o worker." ->
            call.("continue", %{})
            {:ok, "unused"}

          assembled =~ "Sub task2" ->
            call.("continue", %{})
            {:ok, "unused"}

          assembled =~ "## Work" ->
            {:ok, "acompanhando"}

          true ->
            assert {:ok, ""} = call.("work", %{"title" => "Big task2"})

            assert {:ok, ""} =
                     call.("delegate", %{"title" => "Sub task2", "body" => "faça isso2"})

            {:ok, "unused"}
        end
      end)

      assert {:ok, ""} = CLI.run(["send", "Big task2 please"], dir)

      project = open(dir)

      assert {:ok, works} = Query.all(project.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert parent.state == "open"
      assert child.state == "done"
      assert child.stage == "review"

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 4
      [run1, run2, run3, run4] = runs

      assert run1.agent == "concierge" and run1.depth == "0"
      assert run2.agent == "worker" and run2.depth == "1"
      assert run3.agent == "concierge" and run3.depth == "1"
      assert run4.agent == "concierge" and run4.depth == "0"

      Project.close(project)
    end

    test "an askable request with an agent arbiter opens a run on the parent, and granting it wakes the child with the new tool",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "Sou o concierge."
      tools = ["work", "delegate", "comment", "reply", "write"]

      [agents.worker]
      depth = 1
      text = "Sou o worker."
      tools = ["comment", "request_access"]
      """)

      reader = open(dir)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> Project.close(reader) end)

      Application.put_env(:omunculus, :model, fn assembled, call ->
        cond do
          assembled =~ "Sou o worker." ->
            case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
              0 ->
                call.("request_access", %{
                  "kind" => "tool",
                  "name" => "write",
                  "reason" => "preciso escrever"
                })

                {:ok, "unused"}

              _already_granted ->
                {:ok, "concluido"}
            end

          assembled =~ "## Request" ->
            assert {:ok, [request]} =
                     Query.all(
                       reader.conn,
                       "SELECT * FROM requests WHERE status = 'waiting_agent'"
                     )

            assert {:ok, ""} =
                     call.("reply", %{
                       "request_id" => request.id,
                       "decision" => "grant",
                       "body" => "pode escrever"
                     })

            {:ok, "concedido"}

          assembled =~ "## Work" ->
            {:ok, "acompanhando"}

          true ->
            assert {:ok, ""} = call.("work", %{"title" => "Big task3"})

            assert {:ok, ""} =
                     call.("delegate", %{"title" => "Sub task3", "body" => "escreva isso"})

            {:ok, "unused"}
        end
      end)

      assert {:ok, ""} = CLI.run(["send", "Big task3 please"], dir)

      assert {:ok, [request]} = Query.all(reader.conn, "SELECT * FROM requests")
      assert request.status == "closed"
      assert request.arbiter == "concierge"

      assert {:ok, request_run} =
               Query.one(reader.conn, "SELECT * FROM runs WHERE request_id IS NOT NULL")

      assert request_run.agent == "concierge"

      assert {:ok, request_assembled} =
               Query.one(reader.conn, "SELECT * FROM prompts WHERE id = ?", [
                 request_run.prompt_id
               ])

      assert request_assembled.body =~ "## Request"
      assert request_assembled.body =~ "preciso escrever"

      assert {:ok, works} = Query.all(reader.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert Jason.decode!(child.grants) == ["write"]
      assert child.state == "done"
      assert parent.state == "open"

      assert {:ok, runs} = Query.all(reader.conn, "SELECT * FROM runs ORDER BY started_at")

      granted_worker_run =
        Enum.find(runs, fn run ->
          run.work_id == child.id and run.agent == "worker" and
            "write" in Jason.decode!(run.tools)
        end)

      assert granted_worker_run

      assert List.last(runs).agent == "concierge"
    end
  end
end
