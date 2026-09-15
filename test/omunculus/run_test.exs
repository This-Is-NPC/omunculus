defmodule Omunculus.RunTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Fixtures, Id, Project, Run, Store}
  alias Omunculus.Store.Query

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_config(dir, contents), do: File.write!(Path.join(dir, "omunculus.toml"), contents)

  defp write_tool(dir, name, toml, script) do
    tool_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(tool_dir)
    File.write!(Path.join(tool_dir, "tool.toml"), toml)
    run_path = Path.join(tool_dir, "run")
    File.write!(run_path, script)
    File.chmod!(run_path, 0o755)
  end

  defp model_tool_toml(name),
    do: """
    name = "#{name}"
    kind = "tool"
    triggers = ["model"]
    command = ["./run"]
    """

  defp fixed_output_script(output),
    do: """
    #!/bin/sh
    echo '{"ok": true, "output": "#{output}", "emit": []}'
    """

  defp open_project(dir) do
    {:ok, project} = Project.open(dir)
    project
  end

  defp message(conn, body \\ "hi"),
    do: Fixtures.insert(conn, :prompts, %{kind: "message", body: body})

  test "a model calling a project tool leaves a start-run, tool, model, end-run replay", %{
    dir: dir
  } do
    write_tool(dir, "echo", model_tool_toml("echo"), fixed_output_script("echoed"))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, call ->
      assert {:ok, "echoed"} = call.("echo", %{})
      {:ok, "done"}
    end

    assert {:ok, run} = Run.open(project, message_id, model)
    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "tool", "model", "end-run"]

    Project.close(project)
  end

  test "a model calling a name outside the effective set is rejected and nothing is recorded",
       %{dir: dir} do
    write_tool(dir, "echo", model_tool_toml("echo"), fixed_output_script("echoed"))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, call -> call.("nonexistent", %{}) end

    assert {:error, {:not_allowed, "nonexistent"}} = Run.open(project, message_id, model)

    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM events WHERE type = 'tool'")

    Project.close(project)
  end

  test "a config without a depth-0 agent fails and writes nothing", %{dir: dir} do
    write_config(dir, """
    [agents.watcher]
    depth = 1
    text = "watch"
    """)

    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _call -> raise "must never be called" end

    assert {:error, {:no_agent_at_depth, 0}} = Run.open(project, message_id, model)
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")

    Project.close(project)
  end

  test "omunculus.toml's agent tools list restricts both the cards and the call", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["one"]
    """)

    write_tool(dir, "one", model_tool_toml("one"), fixed_output_script("one-out"))
    write_tool(dir, "two", model_tool_toml("two"), fixed_output_script("two-out"))

    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn assembled, call ->
      send(test_pid, {:assembled, assembled})
      send(test_pid, {:two, call.("two", %{})})
      assert {:ok, "one-out"} = call.("one", %{})
      {:ok, "one-out"}
    end

    assert {:ok, _run} = Run.open(project, message_id, model)

    assert_received {:assembled, assembled}
    assert assembled =~ "- one:"
    refute assembled =~ "- two:"

    assert_received {:two, {:error, {:not_allowed, "two"}}}

    Project.close(project)
  end
end
