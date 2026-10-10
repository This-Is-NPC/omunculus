defmodule Omunculus.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Config, Fixtures, Project}
  alias Omunculus.Store.Query

  import Omunculus.Fixtures, only: [open_project: 1, write_config: 2]

  setup do
    dir = Fixtures.tmp_dir()

    [one, two, three] =
      for n <- ["001", "002", "003"] do
        root = Path.expand(".scratch/workspace-#{n}", File.cwd!())
        File.mkdir_p!(root)
        Enum.each(File.ls!(root), &File.rm_rf!(Path.join(root, &1)))
        root
      end

    %{dir: dir, one: one, two: two, three: three}
  end

  defp base_toml(one, two, three) do
    """
    [workspaces.one]
    root = "#{one}"

    [workspaces.two]
    root = "#{two}"
    deny = ["write"]

    [workspaces.three]
    root = "#{three}"

    [policy]
    workspace = "one"

    [agents.concierge]
    depth = 0
    text = "concierge"
    tools = ["work", "delegate", "end", "directory", "workspaces", "read", "write", "changes", "revert", "request_access", "reply", "comment", "peek", "sandbox.write", "sandbox.network"]

    [agents.worker]
    depth = 1
    text = "worker"
    tools = ["comment"]
    """
  end

  defp write_check_tool(dir, name, needle) do
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
    data=$(cat)
    case "$data" in
      *'#{needle}'*) echo '{"ok": true, "output": "match", "emit": []}' ;;
      *) echo '{"ok": true, "output": "nomatch", "emit": []}' ;;
    esac
    """)

    File.chmod!(run_path, 0o755)
  end

  test "a send run without work uses the default workspace's root", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    write_check_tool(dir, "peek", ~s("roots":["#{one}"]))

    model = fn _assembled, _tools, call ->
      assert {:ok, "match"} = call.("peek", %{})
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "hi"], dir)
  end

  test "write in the default workspace writes into its root, not the project dir", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))

    model = fn _assembled, _tools, call ->
      assert {:ok, ""} = call.("write", %{"path" => "note.txt", "content" => "hi"})
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "hi"], dir)

    assert File.read!(Path.join(one, "note.txt")) == "hi"
    refute File.exists?(Path.join(dir, "note.txt"))
  end

  test "with [store] changes, a call that wrote records the files it changed", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    File.write!(Path.join(one, "kept.txt"), "kept\n")

    write_config(
      dir,
      base_toml(one, two, three) <>
        """

        [store]
        path = ".omunculus/store.sqlite3"
        changes = ".omunculus/changes"
        """
    )

    model = fn _assembled, _tools, call ->
      assert {:ok, ""} = call.("write", %{"path" => "note.txt", "content" => "hi\n"})
      assert {:ok, _listing} = call.("directory", %{})
      assert {:ok, "- write (this run)\n  A note.txt (+1 -0)"} = call.("changes", %{})
      assert {:ok, patch} = call.("changes", %{"patch" => true})
      assert patch =~ "+hi"
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)
    assert {:ok, ""} = CLI.run(["send", "hi"], dir)

    project = open_project(dir)
    {:ok, events} = Query.all(project.conn, "SELECT body FROM events WHERE type = 'tool'")
    calls = Map.new(events, &{Jason.decode!(&1.body)["name"], Jason.decode!(&1.body)})

    assert %{"files" => [%{"path" => "note.txt", "op" => "A", "added" => 1, "deleted" => 0}]} =
             changes = calls["write"]["changes"]

    refute Map.has_key?(calls["directory"], "changes")

    assert {:ok, patch} =
             Omunculus.Changes.patch(
               Path.join(dir, ".omunculus/changes"),
               changes["before"],
               changes["after"]
             )

    assert patch =~ "+hi"
  end

  test "revert puts back what the run's calls changed, unless a file moved on since", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    kept = Path.join(one, "kept.txt")
    File.write!(kept, "kept\n")

    write_config(
      dir,
      base_toml(one, two, three) <>
        """

        [store]
        path = ".omunculus/store.sqlite3"
        changes = ".omunculus/changes"
        """
    )

    model = fn _assembled, _tools, call ->
      assert {:ok, ""} = call.("write", %{"path" => "note.txt", "content" => "hi\n"})
      assert {:ok, ""} = call.("write", %{"path" => "kept.txt", "content" => "changed\n"})
      File.write!(kept, "moved on\n")

      assert {:ok, "refused: kept.txt changed after the work's last change; nothing was restored"} =
               call.("revert", %{})

      assert File.exists?(Path.join(one, "note.txt"))
      File.write!(kept, "changed\n")
      assert {:ok, "Restored: kept.txt\nRemoved: note.txt"} = call.("revert", %{})
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)
    assert {:ok, ""} = CLI.run(["send", "hi"], dir)

    assert File.read!(kept) == "kept\n"
    refute File.exists?(Path.join(one, "note.txt"))
  end

  test "a work created with workspace two has write absent from the run's tools", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    model = fn _assembled, _tools, _call -> {:ok, "done"} end
    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)

    project = open_project(dir)

    assert {:ok, [run]} =
             Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [work_id])

    tools = Jason.decode!(run.tools)
    refute "write" in tools
    assert "read" in tools
    Project.close(project)
  end

  test "read of a file in two works, and a path into one is refused", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    File.write!(Path.join(two, "secret.txt"), "secret")
    File.write!(Path.join(one, "other.txt"), "other")

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    model = fn _assembled, _tools, call ->
      assert {:ok, "secret"} = call.("read", %{"path" => "secret.txt"})

      assert {:ok, message} = call.("read", %{"path" => Path.join(one, "other.txt")})
      assert message =~ "path outside roots"
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)
  end

  test "a child delegated from a workspace-two work inherits workspace two", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    model = fn _assembled, _tools, call ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 ->
          call.("work", %{
            "report" => "delegated",
            "works" => [%{"title" => "child", "goal" => "do this"}]
          })

        _already_delegated ->
          :ok
      end

      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)

    project = open_project(dir)

    assert {:ok, [child]} =
             Query.all(project.conn, "SELECT * FROM works WHERE parent_id = ?", [work_id])

    assert child.workspace == "two"
    Project.close(project)
  end

  test "the workspaces tool lists every workspace, marking the run's own", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    test_pid = self()

    model = fn _assembled, _tools, call ->
      {:ok, output} = call.("workspaces", %{})
      send(test_pid, {:output, output})
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)

    assert_received {:output, output}
    assert output == "one #{one}\nthree #{three}\ntwo #{two} *"
  end

  test "the directory tool lists workspace three's entries for a work in three", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    File.write!(Path.join(three, "marker.txt"), "m")

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "three", title: "In three"})
    Project.close(project)

    test_pid = self()

    model = fn _assembled, _tools, call ->
      {:ok, output} = call.("directory", %{})
      send(test_pid, {:output, output})
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)

    assert_received {:output, output}
    assert output == "#{three}\n  marker.txt"
  end

  test "a permanent grant with scope workspace on a request from two writes workspaces.two.granted",
       %{dir: dir, one: one, two: two, three: three} do
    write_config(dir, base_toml(one, two, three))
    write_check_tool(dir, "delete", "delete")
    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    request_model = fn _assembled, _tools, call ->
      call.("request_access", %{
        "report" => "blocked on delete",
        "access" => [%{"kind" => "tool", "name" => "delete"}],
        "reason" => "need to delete"
      })

      {:ok, "unused"}
    end

    Fixtures.use_model(dir, request_model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)

    project = open_project(dir)
    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
    Project.close(project)

    reply_model = fn _assembled, _tools, _call -> {:ok, "thanks"} end
    Fixtures.use_model(dir, reply_model)

    assert {:ok, ""} =
             CLI.run(
               [
                 "reply",
                 "--request_id",
                 request.id,
                 "--option",
                 "grant_workspace",
                 "allowed forever"
               ],
               dir
             )

    assert {:ok, %Config{workspaces: workspaces}} = Fixtures.load_config(dir)
    assert "delete" in workspaces["two"].ceiling.granted
  end

  defp stage_scope_toml(one, two, three) do
    """
    [workspaces.one]
    root = "#{one}"

    [workspaces.two]
    root = "#{two}"
    deny = ["write"]

    [workspaces.three]
    root = "#{three}"

    [policy]
    workspace = "one"
    workflow = "delivery"

    [agents.concierge]
    depth = 0
    text = "concierge"
    tools = ["work", "delegate", "end", "read", "write", "request_access", "reply", "comment"]

    [workflows.delivery]
    steps = [
      { name = "to_do", agent = "concierge" },
    ]
    """
  end

  test "a permanent grant with scope stage writes the workflow step's granted", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, stage_scope_toml(one, two, three))

    write_check_tool(dir, "delete", "delete")
    project = open_project(dir)

    work_id =
      Fixtures.insert(project.conn, :works, %{
        workspace: "two",
        stage: "to_do",
        title: "In two"
      })

    Project.close(project)

    request_model = fn _assembled, _tools, call ->
      call.("request_access", %{
        "report" => "blocked on delete",
        "access" => [%{"kind" => "tool", "name" => "delete"}],
        "reason" => "need to delete"
      })

      {:ok, "unused"}
    end

    Fixtures.use_model(dir, request_model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)

    project = open_project(dir)
    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
    Project.close(project)

    reply_model = fn _assembled, _tools, _call -> {:ok, "thanks"} end
    Fixtures.use_model(dir, reply_model)

    assert {:ok, ""} =
             CLI.run(
               [
                 "reply",
                 "--request_id",
                 request.id,
                 "--option",
                 "grant_stage",
                 "allowed forever"
               ],
               dir
             )

    assert {:ok, %Config{workflows: %{"delivery" => [to_do]}}} = Fixtures.load_config(dir)
    assert "delete" in to_do.ceiling.granted
  end

  test "a run in the default workspace uses that workspace's execution timeout", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(
      dir,
      base_toml(one, two, three) <>
        """

        [workspaces.one.execution]
        timeout_ms = 120000
        """
    )

    model = fn _assembled, _tools, _call -> {:ok, "done"} end
    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "hi"], dir)

    project = open_project(dir)
    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")

    assert {:ok, event} =
             Query.one(project.conn, "SELECT * FROM events WHERE id = ?", [run.event_id])

    assert Jason.decode!(event.body)["execution"]["limits"]["timeout_ms"] == 120_000
    Project.close(project)
  end

  test "a run in workspace two uses that workspace's agent text", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(
      dir,
      base_toml(one, two, three) <>
        """

        [workspaces.two.agents.concierge]
        text = "You are the app worker."
        """
    )

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    model = fn assembled, _tools, _call ->
      assert assembled =~ "You are the app worker."
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)
  end

  test "a run in the default workspace uses the workspace file execution timeout", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    File.write!(Path.join(one, "omunculus.toml"), """
    [execution]
    timeout_ms = 120000
    """)

    write_config(
      dir,
      base_toml(one, two, three) <>
        """

        [workspaces.one]
        config = "omunculus.toml"
        """
    )

    model = fn _assembled, _tools, _call -> {:ok, "done"} end
    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "hi"], dir)

    project = open_project(dir)
    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")

    assert {:ok, event} =
             Query.one(project.conn, "SELECT * FROM events WHERE id = ?", [run.event_id])

    assert Jason.decode!(event.body)["execution"]["limits"]["timeout_ms"] == 120_000
    Project.close(project)
  end

  test "a run in workspace two uses agent text from the workspace file", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    File.write!(Path.join(two, "omunculus.toml"), """
    [agents.concierge]
    text = "You are the app worker."
    """)

    write_config(
      dir,
      base_toml(one, two, three) <>
        """

        [workspaces.two]
        config = "omunculus.toml"
        """
    )

    project = open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    model = fn assembled, _tools, _call ->
      assert assembled =~ "You are the app worker."
      {:ok, "done"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)
  end
end
