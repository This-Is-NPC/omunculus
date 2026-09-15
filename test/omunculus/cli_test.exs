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
end
