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

  defp write_hook(dir, name, toml, script) do
    hook_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(hook_dir)
    File.write!(Path.join(hook_dir, "hook.toml"), toml)
    run_path = Path.join(hook_dir, "run")
    File.write!(run_path, script)
    File.chmod!(run_path, 0o755)
  end

  defp open_project(dir) do
    {:ok, project} = Project.open(dir)
    project
  end

  defp write_config(dir, contents), do: File.write!(Path.join(dir, "omunculus.toml"), contents)

  defp open(prompt_id, work_id \\ nil),
    do: %{prompt_id: prompt_id, work_id: work_id, request_id: nil, via: nil, agent: nil}

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

    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil}

    assert {:ok, %{ok: true}, events} = Harness.dispatch(project, "send", %{}, ctx)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.body == "override"
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")

    assert :ok = Harness.follow_up(project, events, model)

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
    ctx = %{trigger: "model", run_id: nil, author: "agent", agent: nil}

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
    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil}

    assert {:error, {:not_triggered, "modelonly", "cli"}} =
             Harness.dispatch(project, "modelonly", %{}, ctx)

    Project.close(project)
  end

  test "a tool that declares views = [\"events.run\"] receives the run's events so far", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["counter"]
    """)

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

    model = fn _assembled, _tools, call ->
      {:ok, output} = call.("counter", %{})
      {:ok, output}
    end

    assert {:ok, run} = Run.open(project, open(message_id), model)

    assert {:ok, [event]} =
             Query.all(project.conn, "SELECT * FROM events WHERE type = 'model' AND run_id = ?", [
               run.id
             ])

    assert event.body == "1"

    Project.close(project)
  end

  test "a project tool declaring views = [\"work\", \"comments.work\"] receives both once the run is on a work",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["work", "viewer"]
    """)

    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      views = ["work", "comments.work"]
      command = ["./run"]
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

    model = fn _assembled, _tools, call ->
      assert {:ok, ""} = call.("work", %{"title" => "Fix the parser"})
      call.("viewer", %{})
    end

    assert {:ok, run} = Run.open(project, open(message_id), model)

    assert {:ok, [event]} =
             Query.all(project.conn, "SELECT * FROM events WHERE type = 'model' AND run_id = ?", [
               run.id
             ])

    assert event.body == "yes"

    Project.close(project)
  end

  test "a tool declaring views = [\"comments.request\"] receives the run's request comments", %{
    dir: dir
  } do
    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      views = ["comments.request"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *"preciso disso"*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    request_id = Fixtures.insert(project.conn, :requests)
    Fixtures.insert(project.conn, :comments, %{request_id: request_id, body: "preciso disso"})
    run_id = Fixtures.insert(project.conn, :runs, %{request_id: request_id})
    ctx = %{trigger: "model", run_id: run_id, author: "agent", agent: "concierge"}

    assert {:ok, out, _events} = Harness.dispatch(project, "viewer", %{}, ctx)
    assert out.output == "yes"

    Project.close(project)
  end

  test "a tool declaring views = [\"comments.inbox\", \"inbox.work\"] receives the work's inbox comments and notifications",
       %{dir: dir} do
    write_tool(
      dir,
      "viewer",
      """
      name = "viewer"
      kind = "tool"
      triggers = ["model"]
      views = ["comments.inbox", "inbox.work"]
      command = ["./run"]
      """,
      """
      #!/bin/sh
      data=$(cat)
      case "$data" in
        *"preciso avisar"*) echo '{"ok": true, "output": "yes", "emit": []}' ;;
        *) echo '{"ok": true, "output": "no", "emit": []}' ;;
      esac
      """
    )

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    inbox_id = Fixtures.insert(project.conn, :inbox, %{work_id: work_id})
    Fixtures.insert(project.conn, :comments, %{inbox_id: inbox_id, body: "preciso avisar"})
    run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id})
    ctx = %{trigger: "model", run_id: run_id, author: "agent", agent: "concierge"}

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
    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil}

    assert {:ok, %{ok: true}, events} = Harness.dispatch(project, "send", %{}, ctx)
    assert Enum.any?(events, &(&1.type == "prompt"))
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")

    Project.close(project)
  end

  test "follow_up opens a run for a prompt event and drives the model", %{dir: dir} do
    project = open_project(dir)
    message_id = Fixtures.insert(project.conn, :prompts, %{kind: "message", body: "hi"})
    event = %{type: "prompt", prompt_id: message_id, work_id: nil}

    assert :ok =
             Harness.follow_up(project, [event], fn _assembled, _tools, _call -> {:ok, "done"} end)

    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"

    assert {:ok, message} =
             Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [message_id])

    assert message.run_id == run.id

    Project.close(project)
  end

  test "a tool declaring views = [\"inbox\"] receives the unread list outside any run", %{
    dir: dir
  } do
    write_tool(
      dir,
      "peek",
      """
      name = "peek"
      kind = "tool"
      triggers = ["cli"]
      views = ["inbox"]
      command = ["./run"]
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

    ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil}

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
      description = "Uma tool concedida."
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
      description = "Uma tool bloqueada."
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

    assert {:ok, %{ok: true, output: "nenhuma tool encontrada"}, _events} =
             Harness.dispatch(project, "tool_search", %{}, ctx)

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

    assert {:error, {:exit, 1, _output}} =
             Harness.dispatch(project, "notify", %{"body" => "oi"}, ctx)

    assert {:ok, [_inbox_row]} = Query.all(project.conn, "SELECT * FROM inbox")

    Project.close(project)
  end
end
