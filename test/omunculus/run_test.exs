defmodule Omunculus.RunTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Fixtures, Id, Project, Run, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.Out

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Fixtures.install_default(dir)
    %{dir: dir}
  end

  defp write_config(dir, contents, opts \\ []), do: Fixtures.write_config(dir, contents, opts)

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
    {:ok, project} = Fixtures.open_project(dir)
    project
  end

  defp message(conn, body \\ "hi"),
    do: Fixtures.insert(conn, :prompts, %{kind: "message", body: body})

  defp open(prompt_id, work_id \\ nil),
    do: %{prompt_id: prompt_id, work_id: work_id, request_id: nil, via: nil, agent: nil}

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
             Run.open(project, open(prompt_id))

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
             Run.open(project, open(prompt_id))

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

    write_tool(dir, "echo", model_tool_toml("echo"), fixed_output_script("echoed"))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _tools, call ->
      assert {:ok, "echoed"} = call.("echo", %{})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, open(message_id))
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
    assert {:error, {:assemble, :missing}} = Run.open(project, open(message(project.conn)))
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

    assert {:error, {:assemble, :empty}} = Run.open(project, open(message(project.conn)))
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

    assert {:ok, _run} = Run.open(project, open(message(project.conn)))
    assert_received {:assembled, "CUSTOM ASSEMBLED"}
    Project.close(project)
  end

  test "a model calling a name outside the effective set is rejected and nothing is recorded",
       %{dir: dir} do
    write_tool(dir, "echo", model_tool_toml("echo"), fixed_output_script("echoed"))
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _tools, call -> call.("nonexistent", %{}) end
    Fixtures.use_model(project, model)

    assert {:error, {:not_allowed, "nonexistent"}} = Run.open(project, open(message_id))

    assert {:ok, events} = Query.all(project.conn, "SELECT * FROM events WHERE type = 'tool'")
    assert Enum.map(events, &Jason.decode!(&1.body)["name"]) == ["assemble"]

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

    assert {:error, {:no_agent_at_depth, 0}} = Run.open(project, open(message_id))
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

    write_tool(dir, "one", model_tool_toml("one"), fixed_output_script("one-out"))
    write_tool(dir, "two", model_tool_toml("two"), fixed_output_script("two-out"))

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

    assert {:ok, _run} = Run.open(project, open(message_id))

    assert_received {:assembled, assembled}
    assert assembled =~ "- one:"
    refute assembled =~ "- two:"

    assert_received {:two, {:error, {:not_allowed, "two"}}}

    Project.close(project)
  end

  test "a message-only run has no ## Work section", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn assembled, _tools, _call -> {:ok, assembled} end
    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, open(message_id))
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

    assert {:ok, run} = Run.open(project, open(message_id, work_id))
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

    assert {:ok, _run} = Run.open(project, open(message_id, work_id))

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
      open(message_id, work_id)
      |> Map.put(:request_id, request_id)
      |> Map.put(:inbox_id, inbox_id)

    assert {:ok, _run} = Run.open(project, opening)

    assert_received {:assembled, assembled}
    assert assembled =~ "## Request"
    assert assembled =~ "## Inbox\n" <> inbox_id
    assert assembled =~ "standalone notice"
    request_at = :binary.match(assembled, "## Request") |> elem(0)
    inbox_at = :binary.match(assembled, "## Inbox") |> elem(0)
    tools_at = :binary.match(assembled, "## Tools") |> elem(0)
    assert request_at < inbox_at
    assert inbox_at < tools_at

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

    assert {:ok, _run} = Run.open(project, open(message_id, work_id))

    assert_received {:assembled, assembled}
    refute assembled =~ "## Inbox"

    Project.close(project)
  end

  test "opening on an unknown work fails and writes nothing", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)

    model = fn _assembled, _tools, _call -> raise "must never be called" end
    Fixtures.use_model(project, model)

    assert {:error, {:no_work, "nope"}} = Run.open(project, open(message_id, "nope"))
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

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, open(message_id))

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
    model = fn _assembled, _tools, _call -> {:ok, "done"} end
    Fixtures.use_model(project, model)

    assert {:ok, run1} = Run.open(project, open(message(project.conn)))
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

    assert {:ok, run2} = Run.open(project, open(message(project.conn)))
    assert Jason.decode!(run2.tools) == ["a", "b"]
    assert {:ok, [start2 | _]} = Store.replay(project.conn, {:run, run2.id})
    policy2 = Jason.decode!(start2.body)["execution"]
    assert policy2["tools"] == ["a", "b"]
    refute policy1["id"] == policy2["id"]

    Project.close(project)
  end

  test "the default concierge ceiling has more than 12 effective tools and lists every card when nothing is pinned",
       %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["break", "catalog", "continue", "delegate", "fs.read", "reply", "store"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, open(message(project.conn)))
    assert length(Jason.decode!(run.tools)) == 13

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
    tools = ["break", "catalog", "continue", "delegate", "fs.read", "reply", "store"]
    pinned = ["store", "sequence", "catalog"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, open(message(project.conn)))
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
    tools = ["break", "catalog", "continue", "delegate", "fs.read", "reply", "store", "counter"]
    """)

    project = open_project(dir)
    test_pid = self()

    model = fn assembled, _tools, _call ->
      send(test_pid, {:assembled, assembled})
      {:ok, "done"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, open(message(project.conn)))
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

    assert {:ok, _run} = Run.open(project, open(message(project.conn), work))
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

    assert {:ok, run} = Run.open(project, open(message(project.conn)))
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

    assert {:ok, _run} = Run.open(project, open(message(project.conn)))

    assert_received {:assembled, assembled}
    assert assembled =~ "- tool_search:"
    refute assembled =~ "Mais "

    Project.close(project)
  end

  test "a child work sees its parent's grants but an unrelated work does not", %{dir: dir} do
    write_tool(dir, "extra", model_tool_toml("extra"), fixed_output_script("ok"))

    project = open_project(dir)
    model = fn _assembled, _tools, _call -> {:ok, "done"} end

    parent_id = Fixtures.insert(project.conn, :works, %{grants: ~s(["extra"])})
    child_id = Fixtures.insert(project.conn, :works, %{parent_id: parent_id})
    unrelated_id = Fixtures.insert(project.conn, :works)
    Fixtures.use_model(project, model)

    assert {:ok, child_run} =
             Run.open(project, open(message(project.conn), child_id))

    assert "extra" in Jason.decode!(child_run.tools)
    Fixtures.use_model(project, model)

    assert {:ok, unrelated_run} =
             Run.open(project, open(message(project.conn), unrelated_id))

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
    model = fn _assembled, _tools, _call -> {:ok, "done"} end

    work_id = Fixtures.insert(project.conn, :works, %{grants: ~s(["write"])})
    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, open(message(project.conn), work_id))

    refute "write" in Jason.decode!(run.tools)

    Project.close(project)
  end

  test "a request_access emit ends the run before any further tool call happens", %{dir: dir} do
    project = open_project(dir)
    message_id = message(project.conn)
    test_pid = self()

    model = fn _assembled, _tools, call ->
      call.("request_access", %{"kind" => "path", "name" => "./secret", "reason" => "need it"})
      send(test_pid, :reached_second_call)
      call.("request_access", %{"kind" => "tool", "name" => "other", "reason" => "x"})
      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, run} = Run.open(project, open(message_id))
    refute_received :reached_second_call

    assert {:ok, events} = Store.replay(project.conn, {:run, run.id})

    assert Enum.map(events, & &1.type) == [
             "start-run",
             "tool",
             "tool",
             "request",
             "end-run",
             "tool"
           ]

    assert {:ok, stored} = Query.one(project.conn, "SELECT * FROM runs WHERE id = ?", [run.id])
    assert stored.status == "done"

    Project.close(project)
  end

  test "request_sandbox with sandbox.write opens a REQUESTS row", %{dir: dir} do
    write_config(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["request_sandbox"]
    """)

    project = open_project(dir)

    model = fn _assembled, _tools, call ->
      call.("request_sandbox", %{"name" => "sandbox.write", "reason" => "need to write"})
      {:ok, "unused"}
    end

    Fixtures.use_model(project, model)

    assert {:ok, _run} = Run.open(project, open(message(project.conn)))
    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
    ask = Jason.decode!(request.ask)
    assert ask["kind"] == "resource"
    assert ask["name"] == "sandbox.write"

    Project.close(project)
  end

  test "the default worker asks for sandbox.write instead of having it", %{dir: dir} do
    project = open_project(dir)

    model = fn _assembled, _tools, call ->
      call.("request_sandbox", %{"name" => "sandbox.write", "reason" => "need to write"})
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
    ask = Jason.decode!(request.ask)
    assert ask["kind"] == "resource"
    assert ask["name"] == "sandbox.write"
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
               %{prompt_id: nil, work_id: nil, request_id: nil, via: nil, agent: "nope"}
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
end
