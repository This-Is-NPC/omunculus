defmodule Omunculus.CLITest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Id, Project, Store}
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
end
