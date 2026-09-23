defmodule Omunculus.PresetTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Project}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.Out

  import Omunculus.Fixtures, only: [open_project: 1, write_config: 2, write_model_tool: 3]

  setup do
    dir = Fixtures.tmp_dir()
    %{dir: dir}
  end

  describe "codex-like" do
    test "a codex run with network access executes bash through its policy",
         %{dir: dir} do
      assert {:ok, applied} =
               CLI.run(
                 ["preset", "codex-like", "--from", Fixtures.preset_dir("codex-like")],
                 dir
               )

      assert applied == Out.preset_applied("codex-like")

      assert :ok = Fixtures.grant(dir, {:agent, "codex"}, "sandbox.network")

      model = fn assembled, _tools, call ->
        assert assembled =~ "You are a Codex-style coding agent"
        assert {:ok, "hi\n"} = call.("bash", %{"command" => "echo hi"})
        {:ok, "done"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "run a command"], dir)

      project = open_project(dir)
      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.agent == "codex"

      tools = Jason.decode!(run.tools)
      assert "bash" in tools
      assert "read" in tools
      assert "write" in tools

      Project.close(project)
    end
  end

  describe "pi-like" do
    test "applying the preset switches the run to the pi agent, with no bash", %{dir: dir} do
      assert {:ok, applied} =
               CLI.run(
                 ["preset", "pi-like", "--from", Fixtures.preset_dir("pi-like")],
                 dir
               )

      assert applied == Out.preset_applied("pi-like")

      model = fn assembled, _tools, _call ->
        assert assembled =~ "You are a Pi-style agent"
        {:ok, "done"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)
      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.agent == "pi"
      refute "bash" in Jason.decode!(run.tools)

      Project.close(project)
    end
  end

  describe "default package" do
    test "no run ever has bash, and calling it is refused", %{dir: dir} do
      Fixtures.install_default(dir)

      model = fn _assembled, _tools, call ->
        assert {:error, {:not_allowed, "bash"}} = call.("bash", %{"command" => "echo hi"})
        {:ok, "ok"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)
      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      refute "bash" in Jason.decode!(run.tools)

      Project.close(project)
    end
  end

  describe "custom permission kind" do
    setup %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["comment", "reply", "request_secret", "work", "sandbox.network"]
      """)

      write_model_tool(
        dir,
        "request_secret",
        ~s({"ok": true, "output": "", "emit": [{"type": "request", "body": {"reason": "need it", "options": {"grant": [{"name": "grant", "args": {"kind": "secret", "name": "vault"}}], "deny": []}}}]})
      )

      :ok
    end

    test "a custom-kind request opens REQUESTS waiting_human and a grant lands in works.grants",
         %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Keep the secret"})
      Project.close(project)

      model = fn _assembled, _tools, call ->
        assert {:ok, ""} = call.("request_secret", %{})
        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "need the vault"], dir)

      project = open_project(dir)
      assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
      assert request.status == "waiting_human"

      assert %{"grant" => [%{"args" => %{"kind" => "secret", "name" => "vault"}}]} =
               Jason.decode!(request.options)

      Project.close(project)

      reply_model = fn _assembled, _tools, _call -> {:ok, "thanks"} end
      Fixtures.use_model(dir, reply_model)

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request.id, "--option", "grant", "allowed"],
                 dir
               )

      project = open_project(dir)
      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["vault"]
      Project.close(project)
    end
  end
end
