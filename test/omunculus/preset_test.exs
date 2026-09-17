defmodule Omunculus.PresetTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Config, Fixtures, Id, Project}
  alias Omunculus.Model.Fake
  alias Omunculus.Store.Query
  alias Omunculus.Tools.Out

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

  defp fake, do: &Fake.complete/3

  defp write_config(dir, contents), do: Fixtures.write_config(dir, contents)

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

  describe "codex-like" do
    test "a codex run with network access executes bash through its policy",
         %{dir: dir} do
      assert {:ok, applied} = CLI.run(["preset", "codex-like"], dir, fake())
      assert applied == Out.preset_applied("codex-like")

      assert :ok = Config.grant(dir, {:agent, "codex"}, "sandbox.network")

      model = fn assembled, _tools, call ->
        assert assembled =~ "You are a Codex-style coding agent"
        assert {:ok, "hi\n"} = call.("bash", %{"command" => "echo hi"})
        {:ok, "done"}
      end

      assert {:ok, ""} = CLI.run(["send", "run a command"], dir, model)

      project = open(dir)
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
      assert {:ok, applied} = CLI.run(["preset", "pi-like"], dir, fake())
      assert applied == Out.preset_applied("pi-like")

      model = fn assembled, _tools, _call ->
        assert assembled =~ "You are a Pi-style agent"
        {:ok, "done"}
      end

      assert {:ok, ""} = CLI.run(["send", "hi"], dir, model)

      project = open(dir)
      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.agent == "pi"
      refute "bash" in Jason.decode!(run.tools)

      Project.close(project)
    end
  end

  describe "default package" do
    test "no run ever has bash, and calling it is refused", %{dir: dir} do
      model = fn _assembled, _tools, call ->
        assert {:error, {:not_allowed, "bash"}} = call.("bash", %{"command" => "echo hi"})
        {:ok, "ok"}
      end

      assert {:ok, ""} = CLI.run(["send", "hi"], dir, model)

      project = open(dir)
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

      write_emit_tool(
        dir,
        "request_secret",
        ~s({"ok": true, "output": "", "emit": [{"type": "request", "body": {"kind": "secret", "name": "vault", "reason": "need it"}}]})
      )

      :ok
    end

    test "a custom-kind request opens REQUESTS waiting_human and a grant lands in works.grants",
         %{dir: dir} do
      project = open(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Keep the secret"})
      Project.close(project)

      model = fn _assembled, _tools, call ->
        assert {:ok, ""} = call.("request_secret", %{})
        {:ok, "unused"}
      end

      assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "need the vault"], dir, model)

      project = open(dir)
      assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
      assert request.status == "waiting_human"
      assert Jason.decode!(request.ask) == %{"kind" => "secret", "name" => "vault"}
      Project.close(project)

      reply_model = fn _assembled, _tools, _call -> {:ok, "thanks"} end

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request.id, "--decision", "grant", "pode"],
                 dir,
                 reply_model
               )

      project = open(dir)
      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["vault"]
      Project.close(project)
    end
  end
end
