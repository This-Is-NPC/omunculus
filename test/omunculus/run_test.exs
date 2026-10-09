defmodule Omunculus.RunTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Id, Project, Run, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.Out

  import Omunculus.Fixtures,
    only: [
      open_project: 1,
      opening: 1,
      opening: 2,
      opening: 3,
      write_config: 2,
      write_config: 3,
      write_model_tool: 3,
      write_tool: 4
    ]

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    %{dir: dir}
  end

  defp assemble_toml do
    """
    name = "assemble"
    kind = "tool"
    triggers = ["harness"]
    command = ["./run"]
    """
  end

  defp custom_assemble_script(output) do
    """
    #!/bin/sh
    echo '{"ok": true, "output": #{Jason.encode!(output)}, "emit": []}'
    """
  end

  defp empty_assemble_script do
    """
    #!/bin/sh
    echo '{"ok": true, "output": "", "emit": []}'
    """
  end

  defp message(conn, body \\ "hi"),
    do: Fixtures.insert(conn, :prompts, %{kind: "message", body: body})

  test "a model that raises leaves the run done and returns the crash", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    project = open_project(dir)
    prompt_id = message(project.conn)
    Fixtures.use_model(project, fn _assembled, _tools, _call -> raise "boom" end)

    assert {:error, {:model_crashed, %RuntimeError{message: "boom"}}} =
             Run.open(project, opening(prompt_id))

    assert {:ok, [run]} = Store.Query.all(project.conn, "SELECT status FROM runs")
    assert run.status == "done"
  end

  test "a model that fails leaves the run done and returns its error", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    project = open_project(dir)
    prompt_id = message(project.conn)

    Fixtures.use_model(project, fn _assembled, _tools, _call ->
      {:error, {:openai, :down}}
    end)

    assert {:error, {:openai, :down}} =
             Run.open(project, opening(prompt_id))

    assert {:ok, [run]} = Store.Query.all(project.conn, "SELECT status FROM runs")
    assert run.status == "done"
  end

  test "a model calling a project tool leaves a start-run, tool, model, end-run replay", %{
    dir: dir
  } do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["echo", "sandbox.network"]
    """)

    write_model_tool(dir, "echo", ~s({"ok": true, "output": "echoed", "emit": []}))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _tools, call ->
      assert {:ok, "echoed"} = call.("echo", %{})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))
    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "tool", "tool", "model", "end-run"]
    [assemble_event, echo_event] = Enum.filter(events, &(&1.type == "tool"))
    assert Jason.decode!(assemble_event.body)["name"] == "assemble"
    assert Jason.decode!(echo_event.body)["name"] == "echo"

    Project.close(project)
  end

  test "opening a run without assemble in the TOML fails", %{dir: dir} do
    write_config(
      dir,
      """
      [agents.concierge]
      depth = 0
      text = "hi"
      """,
      assemble: false
    )

    project = open_project(dir)
    assert {:error, {:assemble, :missing}} = Run.open(project, opening(message(project.conn)))
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")
    Project.close(project)
  end

  test "an empty assemble output closes the run without an assembled prompt", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    write_tool(dir, "assemble", assemble_toml(), empty_assemble_script())
    project = open_project(dir)
    Fixtures.use_model(project, fn _assembled, _tools, _call -> raise "must never be called" end)

    assert {:error, {:assemble, :empty}} = Run.open(project, opening(message(project.conn)))
    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"
    assert run.prompt_id == nil
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'assembled'")
    Project.close(project)
  end

  test "a project assemble folder replaces the builtin without recompiling", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    write_tool(dir, "assemble", assemble_toml(), custom_assemble_script("CUSTOM ASSEMBLED"))
    project = open_project(dir)
    test_pid = self()

    Fixtures.use_model(project, fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end)

    assert {:ok, _run} = Run.open(project, opening(message(project.conn)))
    assert_received {:assembled, "CUSTOM ASSEMBLED"}
    Project.close(project)
  end

  test "a model calling a name outside the effective set is rejected and recorded as failed",
       %{dir: dir} do
    write_model_tool(dir, "echo", ~s({"ok": true, "output": "echoed", "emit": []}))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _tools, call -> call.("nonexistent", %{}) end
    Fixtures.use_model(project, model)

    assert Run.open(project, opening(message_id)) == {:error, Out.not_yours("nonexistent")}

    assert {:ok, events} = Query.all(project.conn, "SELECT * FROM events WHERE type = 'tool'")
    assert [_assemble, refused] = Enum.map(events, &Jason.decode!(&1.body))

    assert refused == %{
             "name" => "nonexistent",
             "args" => %{},
             "ok" => false,
             "output" => Out.not_yours("nonexistent")
           }

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

    model = fn _assembled, _tools, _call -> raise "must never be called" end
    Fixtures.use_model(project, model)

    assert {:error, {:no_agent_at_depth, 0}} = Run.open(project, opening(message_id))
    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs")

    Project.close(project)
  end

  test "omunculus.toml's agent tools list restricts both the cards and the call", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["one", "sandbox.network"]
    """)

    write_model_tool(dir, "one", ~s({"ok": true, "output": "one-out", "emit": []}))
    write_model_tool(dir, "two", ~s({"ok": true, "output": "two-out", "emit": []}))

    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn assembled, _tools, call ->
      send(test_pid, {:assembled, assembled})
      send(test_pid, {:two, call.("two", %{})})
      assert {:ok, "one-out"} = call.("one", %{})
      {:ok, "one-out"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message_id))

    assert_received {:assembled, assembled}
    assert assembled =~ "- one:"
    refute assembled =~ "- two:"

    assert_received {:two, {:error, refused}}
    assert refused == Out.not_yours("two")

    Project.close(project)
  end

  test "a message-only run has no ## Work section", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn assembled, _tools, _call -> {:ok, assembled} end
    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))
    refute run.work_id
    Project.close(project)
  end

  test "opening on a work_id sets runs.work_id and assembles the title", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    work_id = Fixtures.insert(project.conn, :works, %{title: "Fix the parser"})
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id, work_id))
    assert run.work_id == work_id

    assert_received {:assembled, assembled}
    assert assembled =~ "## Work\nFix the parser"

    Project.close(project)
  end

  test "a work with unread notifications has no ## Inbox without inbox_id", %{
    dir: dir
  } do
    project = open_project(dir)
    message_id = message(project.conn)
    work_id = Fixtures.insert(project.conn, :works, %{title: "Fix the parser"})

    first_id =
      Fixtures.insert(project.conn, :inbox, %{
        work_id: work_id,
        created_at: "2026-01-01T00:00:00Z"
      })

    Fixtures.insert(project.conn, :comments, %{inbox_id: first_id, body: "first"})

    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message_id, work_id))

    assert_received {:assembled, assembled}
    refute assembled =~ "## Inbox"

    Project.close(project)
  end

  test "a run opened with inbox_id assembles that thread after ## Request when both exist", %{
    dir: dir
  } do
    project = open_project(dir)
    message_id = message(project.conn)
    work_id = Fixtures.insert(project.conn, :works, %{title: "Fix the parser"})
    request_id = Fixtures.insert(project.conn, :requests, %{work_id: work_id, agent: "worker"})
    inbox_id = Fixtures.insert(project.conn, :inbox, %{work_id: work_id})
    Fixtures.insert(project.conn, :comments, %{inbox_id: inbox_id, body: "standalone notice"})
    Fixtures.insert(project.conn, :comments, %{request_id: request_id, body: "please look"})

    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    opening =
      opening(message_id, work_id)
      |> Map.put(:request_id, request_id)
      |> Map.put(:inbox_id, inbox_id)

    assert {:ok, _run} = Run.open(project, opening)

    assert_received {:assembled, assembled}
    assert assembled =~ "## Request"
    assert assembled =~ "## Inbox\n" <> inbox_id
    assert assembled =~ "standalone notice"
    request_at = :binary.match(assembled, "## Request") |> elem(0)
    inbox_at = :binary.match(assembled, "## Inbox") |> elem(0)
    assert request_at < inbox_at

    Project.close(project)
  end

  test "a work with no notifications has no ## Inbox section", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    work_id = Fixtures.insert(project.conn, :works, %{title: "Fix the parser"})
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message_id, work_id))

    assert_received {:assembled, assembled}
    refute assembled =~ "## Inbox"

    Project.close(project)
  end

  test "opening on an unknown work fails and writes nothing", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _tools, _call -> raise "must never be called" end
    Fixtures.use_model(project, model)

    assert {:error, {:no_work, "nope"}} = Run.open(project, opening(message_id, "nope"))
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

    write_model_tool(dir, "granted_tool", ~s({"ok": true, "output": "ok", "emit": []}))

    write_model_tool(dir, "negotiable_tool", ~s({"ok": true, "output": "ok", "emit": []}))

    write_model_tool(dir, "deny_tool", ~s({"ok": true, "output": "ok", "emit": []}))

    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))

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

    write_model_tool(dir, "a", ~s({"ok": true, "output": "ok", "emit": []}))
    write_model_tool(dir, "b", ~s({"ok": true, "output": "ok", "emit": []}))

    project = open_project(dir)
    model = fn _assembled, _tools, _call -> {:ok, "done"} end
    Fixtures.use_model(project, model)

    assert {:ok, run1} = Run.open(project, opening(message(project.conn)))
    assert Jason.decode!(run1.tools) == ["a"]
    assert {:ok, [start1 | _]} = Store.replay(project.conn, {:run, run1.id})
    policy1 = Jason.decode!(start1.body)["execution"]
    assert policy1["tools"] == ["a"]

    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["a", "b"]
    """)

    Fixtures.use_model(project, model)

    assert {:ok, run2} = Run.open(project, opening(message(project.conn)))
    assert Jason.decode!(run2.tools) == ["a", "b"]
    assert {:ok, [start2 | _]} = Store.replay(project.conn, {:run, run2.id})
    policy2 = Jason.decode!(start2.body)["execution"]
    assert policy2["tools"] == ["a", "b"]
    refute policy1["id"] == policy2["id"]

    Project.close(project)
  end

  test "the default concierge ceiling has 15 model tools and lists every card when nothing is pinned",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["break", "catalog", "continue", "delegate", "done", "end", "fs.read", "reply", "skills", "store", "work"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message(project.conn)))
    assert length(Jason.decode!(run.tools)) == 15
    assert "read_work" in Jason.decode!(run.tools)
    assert "skill" in Jason.decode!(run.tools)
    refute "continue" in Jason.decode!(run.tools)

    assert_received {:assembled, assembled}
    assert assembled =~ "- tool_search:"
    assert assembled =~ "- break:"
    assert assembled =~ "- comment:"
    assert assembled =~ "- read:"
    assert assembled =~ "- ls:"
    refute assembled =~ Out.more_tools(1)

    Project.close(project)
  end

  test "pinned ∩ effective become cards; the rest hide behind tool_search", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["break", "catalog", "continue", "delegate", "done", "end", "fs.read", "reply", "store", "work"]
    pinned = ["store", "sequence", "catalog"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message(project.conn)))
    assert_received {:assembled, assembled}
    assert assembled =~ "- tool_search:"
    assert assembled =~ "- comment:"
    refute assembled =~ "- read:"
    refute assembled =~ "- ls:"
    assert assembled =~ Out.more_tools(4)

    Project.close(project)
  end

  test "a 13th effective tool does not hide the others unless pinned is set", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["break", "catalog", "continue", "delegate", "end", "fs.read", "reply", "store", "work", "counter"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message(project.conn)))
    assert_received {:assembled, assembled}
    assert assembled =~ "- counter:"
    assert assembled =~ "- read:"
    refute assembled =~ Out.more_tools(1)

    Project.close(project)
  end

  test "stage pinned intersects agent pinned", %{dir: dir} do
    write_config(dir, """
    [policy]
    workflow = "delivery"

    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["store", "fs.read", "catalog"]
    pinned = ["store", "fs.read"]

    [workflows.delivery]
    steps = [{name = "first", agent = "concierge", pinned = ["store"]}]
    """)

    project = open_project(dir)
    work = Fixtures.insert(project.conn, :works, %{stage: "first", assignee: "concierge"})
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message(project.conn), work))
    assert_received {:assembled, assembled}
    assert assembled =~ "- comment:"
    refute assembled =~ "- read:"
    refute assembled =~ "- ls:"

    Project.close(project)
  end

  test "an agent granted only fs.read does not receive directory or workspaces", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["fs.read"]
    """)

    project = open_project(dir)
    Fixtures.use_model(project, fn _assembled, _tools, _call -> {:ok, "done"} end)

    assert {:ok, run} = Run.open(project, opening(message(project.conn)))
    names = Jason.decode!(run.tools)
    assert names == ["find", "grep", "ls", "read"]
    assert {:ok, [start | _]} = Store.replay(project.conn, {:run, run.id})
    assert Jason.decode!(start.body)["execution"]["tools"] == names

    Project.close(project)
  end

  test "a small ceiling with tool_search but 12 or fewer effective tools still lists every card",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["catalog"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message(project.conn)))

    assert_received {:assembled, assembled}
    assert assembled =~ "- tool_search:"
    refute assembled =~ "more tools"

    Project.close(project)
  end

  test "a child work sees its parent's grants but an unrelated work does not", %{dir: dir} do
    write_model_tool(dir, "extra", ~s({"ok": true, "output": "ok", "emit": []}))

    project = open_project(dir)
    model = fn _assembled, _tools, _call -> {:ok, "done"} end

    parent_id = Fixtures.insert(project.conn, :works, %{grants: ~s(["extra"])})
    child_id = Fixtures.insert(project.conn, :works, %{parent_id: parent_id, assignee: "worker"})
    unrelated_id = Fixtures.insert(project.conn, :works)
    Fixtures.use_model(project, model)

    assert {:ok, child_run} =
             Run.open(project, opening(message(project.conn), child_id))

    assert "extra" in Jason.decode!(child_run.tools)
    Fixtures.use_model(project, model)

    assert {:ok, unrelated_run} =
             Run.open(project, opening(message(project.conn), unrelated_id))

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

    write_model_tool(dir, "write", ~s({"ok": true, "output": "ok", "emit": []}))

    project = open_project(dir)
    model = fn _assembled, _tools, _call -> {:ok, "done"} end

    work_id = Fixtures.insert(project.conn, :works, %{grants: ~s(["write"])})
    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message(project.conn), work_id))

    refute "write" in Jason.decode!(run.tools)

    Project.close(project)
  end

  test "end ends the run before any further tool call happens", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn _assembled, _tools, call ->
      call.("end", %{})
      send(test_pid, :reached_second_call)

      call.("request_access", %{
        "report" => "x",
        "kind" => "tool",
        "name" => "other",
        "reason" => "x"
      })

      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))
    refute_received :reached_second_call

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "tool", "tool", "end", "end-run"]

    assert {:ok, stored} = Query.one(project.conn, "SELECT * FROM runs WHERE id = ?", [run.id])
    assert stored.status == "done"

    Project.close(project)
  end

  test "request_access ends the run: nothing the model calls after it runs", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn _assembled, _tools, call ->
      call.("request_access", %{
        "report" => "blocked",
        "kind" => "path",
        "name" => "./secret",
        "reason" => "need it"
      })

      send(test_pid, :reached_after_request)
      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message_id))
    refute_received :reached_after_request
    assert {:ok, [_request]} = Query.all(project.conn, "SELECT * FROM requests")

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    types = Enum.map(events, & &1.type)
    assert ["request", "tool", "end" | _rest] = Enum.drop_while(types, &(&1 != "request"))
    assert List.last(types) == "end-run"

    Project.close(project)
  end

  test "request_sandbox with sandbox.write opens a REQUESTS row", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["end", "request_sandbox"]
    """)

    project = open_project(dir)

    model = fn _assembled, _tools, call ->
      call.("request_sandbox", %{
        "report" => "blocked on write",
        "name" => "sandbox.write",
        "reason" => "need to write"
      })

      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, opening(message(project.conn)))
    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")

    options = Jason.decode!(request.options)

    assert %{"grant_agent" => [%{"args" => %{"kind" => "resource", "name" => "sandbox.write"}}]} =
             options

    refute Map.has_key?(options, "grant")

    Project.close(project)
  end

  test "request_sandbox in a run with a work comments the report on it before the request and ends the run",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["comment", "end", "request_sandbox"]
    """)

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)

    model = fn _assembled, _tools, call ->
      call.("request_sandbox", %{
        "report" => "blocked on write",
        "name" => "sandbox.write",
        "reason" => "need to write"
      })

      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message(project.conn), work_id))
    assert {:ok, [_request]} = Query.all(project.conn, "SELECT * FROM requests")

    assert {:ok, [%{body: "blocked on write"}]} =
             Store.comments(project.conn, :work, work_id)

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})

    assert ["comment", "request", "tool", "end" | _rest] =
             events |> Enum.map(& &1.type) |> Enum.drop_while(&(&1 != "comment"))

    Project.close(project)
  end

  test "continue is not offered to the model and a model call to it is refused", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["comment", "continue", "done", "end"]
    """)

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    test_pid = self()

    model = fn assembled, tools, call ->
      send(test_pid, {:offered, assembled, Enum.map(tools, & &1.name)})
      send(test_pid, {:continue, call.("continue", %{})})
      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message(project.conn), work_id))
    assert_received {:offered, assembled, names}
    refute "continue" in names
    refute assembled =~ "- continue:"
    assert "done" in names
    assert_received {:continue, {:error, refused}}
    assert refused == Out.not_yours("continue")

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    refute "continue" in Enum.map(events, & &1.type)

    Project.close(project)
  end

  test "break without a report fails, writes nothing and leaves the run going", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["break", "comment", "end"]
    """)

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works)
    test_pid = self()

    model = fn _assembled, _tools, call ->
      send(test_pid, {:break, call.("break", %{})})
      call.("end", %{})
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, opening(message(project.conn), work_id))
    assert_received {:break, {:ok, "report required"}}

    assert {:ok, []} = Store.comments(project.conn, :work, work_id)
    assert {:ok, %{state: "open"}} = Store.view(project.conn, "work", work_id)

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "tool", "tool", "tool", "end", "end-run"]

    Project.close(project)
  end

  test "the default worker asks for sandbox.write instead of having it", %{dir: dir} do
    project = open_project(dir)

    model = fn _assembled, _tools, call ->
      call.("request_sandbox", %{
        "report" => "blocked on write",
        "name" => "sandbox.write",
        "reason" => "need to write"
      })

      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} =
             Run.open(project, %{
               prompt_id: message(project.conn),
               work_id: nil,
               request_id: nil,
               via: nil,
               agent: "worker"
             })

    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")

    options = Jason.decode!(request.options)

    assert %{"grant_agent" => [%{"args" => %{"kind" => "resource", "name" => "sandbox.write"}}]} =
             options

    refute Map.has_key?(options, "grant")

    assert request.status == "waiting_human"

    Project.close(project)
  end

  test "opening with an agent runs that named agent regardless of work or stage, and an unknown agent fails",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"

    [agents.reactor]
    depth = 2
    text = "reacting"
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} =
             Run.open(
               project,
               %{
                 prompt_id: nil,
                 work_id: nil,
                 request_id: nil,
                 via: "on-notify",
                 agent: "reactor"
               }
             )

    assert run.agent == "reactor"
    assert run.depth == "2"
    assert run.via == "on-notify"

    assert_received {:assembled, assembled}
    assert assembled =~ "reacting"
    Fixtures.use_model(project, fn _assembled, _tools, _call -> raise "must never be called" end)

    assert {:error, {:no_agent, "nope"}} =
             Run.open(
               project,
               opening(nil, nil, %{agent: "nope"})
             )

    Project.close(project)
  end

  test "two agents in one project use different models", %{dir: dir} do
    concierge_script = Id.new()
    worker_script = Id.new()
    test_pid = self()

    Omunculus.Test.ScriptedModel.put(concierge_script, fn assembled, _tools, _call ->
      send(test_pid, {:concierge, assembled})
      {:ok, "from-concierge"}
    end)

    Omunculus.Test.ScriptedModel.put(worker_script, fn assembled, _tools, _call ->
      send(test_pid, {:worker, assembled})
      {:ok, "from-worker"}
    end)

    write_config(dir, """
    [models.concierge_model]
    api = "module"
    module = "Omunculus.Test.ScriptedModel"

    [models.concierge_model.params]
    script = "#{concierge_script}"

    [models.worker_model]
    api = "module"
    module = "Omunculus.Test.ScriptedModel"

    [models.worker_model.params]
    script = "#{worker_script}"

    [agents.concierge]
    depth = 0
    model = "concierge_model"
    text = "concierge-text"

    [agents.worker]
    depth = 1
    model = "worker_model"
    text = "worker-text"
    """)

    project = open_project(dir)

    assert {:ok, concierge_run} =
             Run.open(project, %{
               prompt_id: nil,
               work_id: nil,
               request_id: nil,
               via: nil,
               agent: "concierge"
             })

    assert concierge_run.agent == "concierge"
    assert_received {:concierge, concierge_assembled}
    assert concierge_assembled =~ "concierge-text"
    refute_received {:worker, _}

    assert {:ok, worker_run} =
             Run.open(project, %{
               prompt_id: nil,
               work_id: nil,
               request_id: nil,
               via: "reaction",
               agent: "worker"
             })

    assert worker_run.agent == "worker"
    assert_received {:worker, worker_assembled}
    assert worker_assembled =~ "worker-text"

    Project.close(project)
  end

  test "the deltas of a model reach the store's subscribers without being recorded", %{
    dir: dir
  } do
    project = open_project(dir)

    Fixtures.use_model(project, fn _assembled, _tools, _call, record, delta, _execution ->
      :ok = delta.("hel")
      :ok = delta.("lo")
      :ok = record.("hello")
      {:ok, "hello"}
    end)

    :ok = Store.subscribe(project.conn)
    assert {:ok, run} = Run.open(project, opening(nil))
    owner = project.conn.owner

    assert_received {:store, ^owner, {:delta, %{run_id: run_id, text: "hel"}}}
    assert_received {:store, ^owner, {:delta, %{run_id: ^run_id, text: "lo"}}}
    assert run_id == run.id

    {:ok, events} = Store.replay(project.conn, {:run, run.id})
    assert [%{body: "hello"}] = Enum.filter(events, &(&1.type == "model"))

    Project.close(project)
  end

  describe "a run that stops without end" do
    defp retry_config(dir, policy, extra \\ "") do
      write_config(
        dir,
        """
        [agents.concierge]
        depth = 0
        text = "concierge"
        tools = ["comment", "end"]

        [agents.worker]
        depth = 1
        text = "worker"
        tools = ["comment", "end"]

        [policy]
        #{policy}
        """ <> extra
      )
    end

    # Replies from `steps` in order, one per run, and sends each assembled
    # prompt to the test; the last step repeats.
    defp scripted(project, steps) do
      test_pid = self()
      {:ok, script} = Agent.start_link(fn -> steps end)

      Fixtures.use_model(project, fn assembled, _tools, call ->
        send(test_pid, {:assembled, assembled})

        step =
          Agent.get_and_update(script, fn
            [only] -> {only, [only]}
            [step | rest] -> {step, rest}
          end)

        step.(call)
      end)
    end

    defp idle(text), do: fn _call -> {:ok, text} end
    defp ending, do: fn call -> call.("end", %{}) end

    defp runs_of(project, work_id) do
      {:ok, runs} =
        Query.all(
          project.conn,
          "SELECT runs.* FROM runs JOIN events ON events.id = runs.event_id WHERE runs.work_id = ? ORDER BY events.sequence",
          [work_id]
        )

      runs
    end

    defp root_request(project, work_id) do
      {:ok, [request]} =
        Query.all(project.conn, "SELECT * FROM requests WHERE work_id = ?", [work_id])

      request
    end

    defp breaks_of(project, work_id) do
      {:ok, events} = Store.replay(project.conn, {:work, work_id})
      for %{type: "break", body: body} <- events, do: Jason.decode!(body)["body"]
    end

    test "opens a retry run on the same work whose prompt has the last run's events", %{
      dir: dir
    } do
      retry_config(dir, "max_retries = 1")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("first try"), ending()])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert [first, retry] = runs_of(project, work_id)
      assert first.via == nil
      assert retry.via == "retry"
      assert_received {:assembled, _first}
      assert_received {:assembled, assembled}
      assert assembled =~ "## Last run\n- model first try"
      refute assembled =~ "## Last comment"
      assert {:ok, %{state: "open"}} = Store.view(project.conn, "work", work_id)
      assert breaks_of(project, work_id) == []

      Project.close(project)
    end

    test "the retry prompt has the last comment and the stopped run's calls", %{dir: dir} do
      retry_config(dir, "max_retries = 1")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)

      commenting = fn call ->
        {:ok, ""} = call.("comment", %{"body" => "halfway"})
        {:ok, "stopped"}
      end

      scripted(project, [commenting, ending()])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert_received {:assembled, _first}
      assert_received {:assembled, assembled}
      assert assembled =~ "## Last comment\nhalfway"
      assert assembled =~ ~s(- tool comment {"body":"halfway"} ok)
      assert assembled =~ "- model stopped"

      Project.close(project)
    end

    test "[policy] last_run_output_bytes cuts the outputs in the retry prompt", %{dir: dir} do
      retry_config(dir, "max_retries = 1\nlast_run_output_bytes = 2")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)

      failing = fn call ->
        {:ok, _output} = call.("comment", %{})
        {:ok, "stopped"}
      end

      scripted(project, [failing, ending()])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert_received {:assembled, _first}
      assert_received {:assembled, assembled}
      assert assembled =~ ~r/- tool comment \{\} failed\n.{2}\n\(\d+ bytes cut\)\n/

      Project.close(project)
    end

    test "[policy] send_catalog sends every agent the same tools and refuses those not its own",
         %{dir: dir} do
      retry_config(dir, "max_retries = 0\nsend_catalog = true")
      project = open_project(dir)
      test_pid = self()

      Fixtures.use_model(project, fn _assembled, tools, call ->
        send(test_pid, {:sent, Enum.map(tools, & &1.name)})
        send(test_pid, {:write, call.("write", %{"path" => "x", "content" => "y"})})
        {:ok, "done"}
      end)

      assert {:ok, run} = Run.open(project, opening(message(project.conn)))

      assert_received {:sent, sent}
      assert "write" in sent and "work" in sent and sent == Enum.sort(sent)
      assert Jason.decode!(run.tools) == ["comment", "end"]
      assert_received {:write, {:error, refused}}
      assert refused == Out.not_yours("write")

      Project.close(project)
    end

    test "[policy] tool_output_bytes cuts what the model gets but not the recorded call", %{
      dir: dir
    } do
      retry_config(dir, "max_retries = 1\ntool_output_bytes = 2")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      test_pid = self()

      failing = fn call ->
        {:ok, output} = call.("comment", %{})
        send(test_pid, {:tool_output, output})
        {:ok, "stopped"}
      end

      scripted(project, [failing, ending()])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert_received {:tool_output, output}
      assert output == "bo\n(11 bytes cut)"
      assert_received {:assembled, _first}
      assert_received {:assembled, assembled}
      assert assembled =~ "- tool comment {} failed\nbody required"

      Project.close(project)
    end

    test "after max_retries retries a child is broken and its waiting parent's run opens", %{
      dir: dir
    } do
      retry_config(dir, "max_retries = 2")
      project = open_project(dir)
      parent_id = Fixtures.insert(project.conn, :works, %{state: "waiting", waiting: "child"})

      child_id =
        Fixtures.insert(project.conn, :works, %{parent_id: parent_id, assignee: "worker"})

      Fixtures.use_model(project, fn assembled, _tools, call ->
        if String.starts_with?(assembled, "worker"), do: {:ok, "idle"}, else: call.("end", %{})
      end)

      assert {:ok, _run} = Run.open(project, opening(nil, child_id))

      assert Enum.map(runs_of(project, child_id), & &1.via) == [nil, "retry", "retry"]

      assert breaks_of(project, child_id) == [
               "The work stopped without a report after 3 runs."
             ]

      assert {:ok, %{state: "waiting"}} = Store.view(project.conn, "work", child_id)
      assert {:ok, %{state: "open"}} = Store.view(project.conn, "work", parent_id)
      assert [_parent_run] = runs_of(project, parent_id)

      Project.close(project)
    end

    test "a root work over the limit asks the human to retry or cancel it", %{dir: dir} do
      retry_config(dir, "max_retries = 1")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("idle")])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert length(runs_of(project, work_id)) == 2
      assert breaks_of(project, work_id) == []

      request = root_request(project, work_id)
      assert request.arbiter == "human"
      assert request.status == "waiting_human"

      assert Jason.decode!(request.options) == %{
               "retry" => [],
               "cancel" => [%{"name" => "cancel", "args" => %{}}]
             }

      assert {:ok, [reason]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE request_id = ?", [
                 request.id
               ])

      assert reason.body == Out.unreported(2)
      assert reason.author == "harness"

      assert {:ok, [inbox]} = Query.all(project.conn, "SELECT * FROM inbox")
      assert inbox.work_id == work_id

      assert {:ok, [%{body: body}]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE inbox_id = ?", [inbox.id])

      assert body == Out.request_inbox(request.id, Out.unreported(2), ["cancel", "retry"])

      assert {:ok, %{state: "waiting", waiting: "request", waiting_for: waiting_for}} =
               Store.view(project.conn, "work", work_id)

      assert waiting_for == request.id

      Project.close(project)
    end

    test "max_retries = 0 asks at once", %{dir: dir} do
      retry_config(dir, "max_retries = 0")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("idle")])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert [_only] = runs_of(project, work_id)
      assert %{id: request_id} = root_request(project, work_id)

      assert {:ok, [%{body: body}]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE request_id = ?", [
                 request_id
               ])

      assert body == Out.unreported(1)

      Project.close(project)
    end

    test "replying retry to the root's request opens another run of it", %{dir: dir} do
      retry_config(dir, "max_retries = 0")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("idle"), ending()])
      assert {:ok, _run} = Run.open(project, opening(nil, work_id))
      request = root_request(project, work_id)

      assert {:ok, ""} =
               CLI.run(["reply", "--request_id", request.id, "--option", "retry", "go on"], dir)

      assert [_first, again] = runs_of(project, work_id)
      assert again.via == "reply"
      assert again.request_id == request.id
      assert {:ok, %{state: "open"}} = Store.view(project.conn, "work", work_id)

      Project.close(project)
    end

    test "replying cancel to the root's request cancels it and opens no run", %{dir: dir} do
      retry_config(dir, "max_retries = 0")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("idle")])
      assert {:ok, _run} = Run.open(project, opening(nil, work_id))
      request = root_request(project, work_id)

      assert {:ok, ""} =
               CLI.run(["reply", "--request_id", request.id, "--option", "cancel", "drop"], dir)

      assert [_only] = runs_of(project, work_id)
      assert {:ok, %{state: "cancelled"}} = Store.view(project.conn, "work", work_id)

      assert {:error, {:cancelled, ^work_id}} = Run.open(project, opening(nil, work_id))
      assert [_only] = runs_of(project, work_id)

      Project.close(project)
    end

    test "a run ending with end starts the count over", %{dir: dir} do
      retry_config(dir, "max_retries = 1")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("one"), ending(), idle("two"), ending()])

      assert {:ok, _run} = Run.open(project, opening(nil, work_id))
      assert {:ok, _run} = Run.open(project, opening(nil, work_id))

      assert Enum.map(runs_of(project, work_id), & &1.via) == [nil, "retry", nil, "retry"]
      assert breaks_of(project, work_id) == []

      Project.close(project)
    end

    test "the work's workspace overrides max_retries", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "main"))
      File.mkdir_p!(Path.join(dir, "other"))

      retry_config(dir, ~s(max_retries = 0\nworkspace = "main"), """

      [workspaces.main]
      root = "main"

      [workspaces.other]
      root = "other"

      [workspaces.other.policy]
      max_retries = 1
      """)

      project = open_project(dir)
      main_id = Fixtures.insert(project.conn, :works, %{workspace: "main"})
      other_id = Fixtures.insert(project.conn, :works, %{workspace: "other"})
      scripted(project, [idle("idle")])

      assert {:ok, _run} = Run.open(project, opening(nil, main_id))
      assert {:ok, _run} = Run.open(project, opening(nil, other_id))

      assert length(runs_of(project, main_id)) == 1
      assert length(runs_of(project, other_id)) == 2

      Project.close(project)
    end

    test "a work left waiting or done by its run is not retried", %{dir: dir} do
      retry_config(dir, "max_retries = 1")
      project = open_project(dir)

      for state <- ["waiting", "done"] do
        work_id = Fixtures.insert(project.conn, :works)

        scripted(project, [
          fn _call ->
            :ok =
              Query.exec(project.conn, "UPDATE works SET state = ? WHERE id = ?", [state, work_id])

            {:ok, "left #{state}"}
          end
        ])

        assert {:ok, _run} = Run.open(project, opening(nil, work_id))

        assert [_only] = runs_of(project, work_id)
        assert breaks_of(project, work_id) == []
      end

      Project.close(project)
    end

    test "the run opened by send and a run for a named agent are not retried", %{dir: dir} do
      retry_config(dir, "max_retries = 1")
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works)
      scripted(project, [idle("idle")])

      assert {:ok, _run} = Run.open(project, opening(message(project.conn)))
      assert {:ok, [_send_run]} = Query.all(project.conn, "SELECT * FROM runs")

      assert {:ok, _run} =
               Run.open(project, %{opening(nil, work_id) | agent: "concierge"})

      assert [_only] = runs_of(project, work_id)

      Project.close(project)
    end
  end
end
