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

  defp open(prompt_id, work_id \\ nil),
    do: %{prompt_id: prompt_id, work_id: work_id, request_id: nil, via: nil}

  test "a model calling a project tool leaves a start-run, tool, model, end-run replay", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["echo"]
    """)

    write_tool(dir, "echo", model_tool_toml("echo"), fixed_output_script("echoed"))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, call ->
      assert {:ok, "echoed"} = call.("echo", %{})
      {:ok, "done"}
    end

    assert {:ok, run} = Run.open(project, open(message_id), model)
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

    assert {:error, {:not_allowed, "nonexistent"}} = Run.open(project, open(message_id), model)

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

    assert {:error, {:no_agent_at_depth, 0}} = Run.open(project, open(message_id), model)
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

    assert {:ok, _run} = Run.open(project, open(message_id), model)

    assert_received {:assembled, assembled}
    assert assembled =~ "- one:"
    refute assembled =~ "- two:"

    assert_received {:two, {:error, {:not_allowed, "two"}}}

    Project.close(project)
  end

  test "a message-only run has no ## Work section", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn assembled, _call -> {:ok, assembled} end

    assert {:ok, run} = Run.open(project, open(message_id), model)
    refute run.work_id
    Project.close(project)
  end

  test "opening on a work_id sets runs.work_id and assembles the title", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    work_id = Fixtures.insert(project.conn, :works, %{title: "Fix the parser"})
    test_pid = self()

    model = fn assembled, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    assert {:ok, run} = Run.open(project, open(message_id, work_id), model)
    assert run.work_id == work_id

    assert_received {:assembled, assembled}
    assert assembled =~ "## Work\nFix the parser"

    Project.close(project)
  end

  test "opening on an unknown work fails and writes nothing", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _call -> raise "must never be called" end

    assert {:error, {:no_work, "nope"}} = Run.open(project, open(message_id, "nope"), model)
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")

    Project.close(project)
  end

  test "cards and runs.tools only carry have tools: negotiable and deny never appear", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["granted_tool"]
    negotiable = ["negotiable_tool"]
    deny = ["deny_tool"]
    """)

    write_tool(dir, "granted_tool", model_tool_toml("granted_tool"), fixed_output_script("ok"))

    write_tool(
      dir,
      "negotiable_tool",
      model_tool_toml("negotiable_tool"),
      fixed_output_script("ok")
    )

    write_tool(dir, "deny_tool", model_tool_toml("deny_tool"), fixed_output_script("ok"))

    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn assembled, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    assert {:ok, run} = Run.open(project, open(message_id), model)

    assert Jason.decode!(run.tools) == ["granted_tool"]

    assert_received {:assembled, assembled}
    assert assembled =~ "- granted_tool:"
    refute assembled =~ "- negotiable_tool:"
    refute assembled =~ "- deny_tool:"

    Project.close(project)
  end

  test "remount: changing omunculus.toml between two runs changes the second run's tools", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["a"]
    """)

    write_tool(dir, "a", model_tool_toml("a"), fixed_output_script("ok"))
    write_tool(dir, "b", model_tool_toml("b"), fixed_output_script("ok"))

    project = open_project(dir)
    model = fn _assembled, _call -> {:ok, "done"} end

    assert {:ok, run1} = Run.open(project, open(message(project.conn)), model)
    assert Jason.decode!(run1.tools) == ["a"]

    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["a", "b"]
    """)

    assert {:ok, run2} = Run.open(project, open(message(project.conn)), model)
    assert Jason.decode!(run2.tools) == ["a", "b"]

    Project.close(project)
  end

  test "a child work sees its parent's grants but an unrelated work does not", %{dir: dir} do
    write_tool(dir, "extra", model_tool_toml("extra"), fixed_output_script("ok"))

    project = open_project(dir)
    model = fn _assembled, _call -> {:ok, "done"} end

    parent_id = Fixtures.insert(project.conn, :works, %{grants: ~s(["extra"])})
    child_id = Fixtures.insert(project.conn, :works, %{parent_id: parent_id})
    unrelated_id = Fixtures.insert(project.conn, :works)

    assert {:ok, child_run} =
             Run.open(project, open(message(project.conn), child_id), model)

    assert "extra" in Jason.decode!(child_run.tools)

    assert {:ok, unrelated_run} =
             Run.open(project, open(message(project.conn), unrelated_id), model)

    refute "extra" in Jason.decode!(unrelated_run.tools)

    Project.close(project)
  end

  test "a work's grant does not pierce a layer deny", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    deny = ["write"]
    """)

    write_tool(dir, "write", model_tool_toml("write"), fixed_output_script("ok"))

    project = open_project(dir)
    model = fn _assembled, _call -> {:ok, "done"} end

    work_id = Fixtures.insert(project.conn, :works, %{grants: ~s(["write"])})

    assert {:ok, run} = Run.open(project, open(message(project.conn), work_id), model)

    refute "write" in Jason.decode!(run.tools)

    Project.close(project)
  end

  test "a request_access emit ends the run before any further tool call happens", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn _assembled, call ->
      call.("request_access", %{"kind" => "tool", "name" => "secret", "reason" => "preciso"})
      send(test_pid, :reached_second_call)
      call.("request_access", %{"kind" => "tool", "name" => "outro", "reason" => "x"})
      {:ok, "unused"}
    end

    assert {:ok, run} = Run.open(project, open(message_id), model)
    refute_received :reached_second_call

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "tool", "request", "end-run"]

    assert {:ok, stored} = Query.one(project.conn, "SELECT * FROM runs WHERE id = ?", [run.id])
    assert stored.status == "done"

    Project.close(project)
  end
end
