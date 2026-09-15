defmodule Omunculus.HarnessTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Fixtures, Harness, Id, Project, Run}
  alias Omunculus.Store.Query

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_tool(dir, name, toml, script) do
    tool_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(tool_dir)
    File.write!(Path.join(tool_dir, "tool.toml"), toml)
    run_path = Path.join(tool_dir, "run")
    File.write!(run_path, script)
    File.chmod!(run_path, 0o755)
  end

  defp open_project(dir) do
    {:ok, project} = Project.open(dir)
    project
  end

  defp never_call, do: fn _assembled, _call -> raise "model must never be called" end

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
    model = fn _assembled, _call -> {:ok, "done"} end

    ctx = %{trigger: "cli", run_id: nil, work_id: nil, author: "human", model: model}

    assert {:ok, %{ok: true}} = Harness.dispatch(project, "send", %{}, ctx)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.body == "override"

    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"

    Project.close(project)
  end

  test "an emit outside the catalogue fails and leaves the events table empty", %{dir: dir} do
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
    ctx = %{trigger: "model", run_id: nil, work_id: nil, author: "agent", model: never_call()}

    assert {:error, {:unknown_action, "nope"}} = Harness.dispatch(project, "boom", %{}, ctx)
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM events")

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
    ctx = %{trigger: "cli", run_id: nil, work_id: nil, author: "human", model: never_call()}

    assert {:error, {:not_triggered, "modelonly", "cli"}} =
             Harness.dispatch(project, "modelonly", %{}, ctx)

    Project.close(project)
  end

  test "a tool that declares views = [\"events.run\"] receives the run's events so far", %{
    dir: dir
  } do
    write_tool(
      dir,
      "counter",
      """
      name = "counter"
      kind = "tool"
      triggers = ["model"]
      views = ["events.run"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      count=$(cat | grep -o '"type"' | wc -l)
      echo "{\\"ok\\": true, \\"output\\": \\"$count\\", \\"emit\\": []}"
      """
    )

    project = open_project(dir)
    message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})

    model = fn _assembled, call ->
      {:ok, output} = call.("counter", %{})
      {:ok, output}
    end

    assert {:ok, run} = Run.open(project, message_id, model)

    assert {:ok, [event]} =
             Query.all(project.conn, "SELECT * FROM events WHERE type = 'model' AND run_id = ?", [
               run.id
             ])

    assert event.body == "1"

    Project.close(project)
  end
end
