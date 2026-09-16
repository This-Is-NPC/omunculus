defmodule Omunculus.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Config, Fixtures, Id, Project}
  alias Omunculus.Store.Query

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    [one, two, three] =
      for n <- ["001", "002", "003"] do
        root = Path.expand(".scratch/workspace-#{n}", File.cwd!())
        File.mkdir_p!(root)
        Enum.each(File.ls!(root), &File.rm_rf!(Path.join(root, &1)))
        root
      end

    %{dir: dir, one: one, two: two, three: three}
  end

  defp open(dir) do
    {:ok, project} = Project.open(dir)
    project
  end

  defp write_config(dir, contents), do: Fixtures.write_config(dir, contents)

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
    tools = ["work", "delegate", "directory", "workspaces", "read", "write", "request_access", "reply", "comment", "peek", "sandbox.write"]

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

    assert {:ok, ""} = CLI.run(["send", "oi"], dir, model)
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

    assert {:ok, ""} = CLI.run(["send", "oi"], dir, model)

    assert File.read!(Path.join(one, "note.txt")) == "hi"
    refute File.exists?(Path.join(dir, "note.txt"))
  end

  test "a work created with workspace two has write absent from the run's tools", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    project = open(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    model = fn _assembled, _tools, _call -> {:ok, "done"} end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, model)

    project = open(dir)

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
    File.write!(Path.join(two, "secret.txt"), "segredo")
    File.write!(Path.join(one, "other.txt"), "outro")

    project = open(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    model = fn _assembled, _tools, call ->
      assert {:ok, "segredo"} = call.("read", %{"path" => "secret.txt"})

      assert {:ok, message} = call.("read", %{"path" => Path.join(one, "other.txt")})
      assert message =~ "path outside roots"
      {:ok, "done"}
    end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, model)
  end

  test "a child delegated from a workspace-two work inherits workspace two", %{
    dir: dir,
    one: one,
    two: two,
    three: three
  } do
    write_config(dir, base_toml(one, two, three))
    project = open(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    model = fn _assembled, _tools, call ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 -> call.("delegate", %{"title" => "child", "body" => "faça isso"})
        _already_delegated -> :ok
      end

      {:ok, "done"}
    end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, model)

    project = open(dir)

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
    project = open(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    test_pid = self()

    model = fn _assembled, _tools, call ->
      {:ok, output} = call.("workspaces", %{})
      send(test_pid, {:output, output})
      {:ok, "done"}
    end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, model)

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

    project = open(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "three", title: "In three"})
    Project.close(project)

    test_pid = self()

    model = fn _assembled, _tools, call ->
      {:ok, output} = call.("directory", %{})
      send(test_pid, {:output, output})
      {:ok, "done"}
    end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, model)

    assert_received {:output, output}
    assert output == "#{three}\n  marker.txt"
  end

  test "a permanent grant with scope workspace on a request from two writes workspaces.two.granted",
       %{dir: dir, one: one, two: two, three: three} do
    write_config(dir, base_toml(one, two, three))
    write_check_tool(dir, "delete", "delete")
    project = open(dir)
    work_id = Fixtures.insert(project.conn, :works, %{workspace: "two", title: "In two"})
    Project.close(project)

    request_model = fn _assembled, _tools, call ->
      call.("request_access", %{
        "kind" => "tool",
        "name" => "delete",
        "reason" => "preciso apagar"
      })

      {:ok, "unused"}
    end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, request_model)

    project = open(dir)
    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
    Project.close(project)

    reply_model = fn _assembled, _tools, _call -> {:ok, "obrigado"} end

    assert {:ok, ""} =
             CLI.run(
               [
                 "reply",
                 "--request_id",
                 request.id,
                 "--decision",
                 "grant",
                 "--scope",
                 "workspace",
                 "pode para sempre"
               ],
               dir,
               reply_model
             )

    assert {:ok, %Config{workspaces: workspaces}} = Config.load(dir)
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
    tools = ["work", "delegate", "read", "write", "request_access", "reply", "comment"]

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
    project = open(dir)

    work_id =
      Fixtures.insert(project.conn, :works, %{
        workspace: "two",
        stage: "to_do",
        title: "In two"
      })

    Project.close(project)

    request_model = fn _assembled, _tools, call ->
      call.("request_access", %{
        "kind" => "tool",
        "name" => "delete",
        "reason" => "preciso apagar"
      })

      {:ok, "unused"}
    end

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "oi"], dir, request_model)

    project = open(dir)
    assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
    Project.close(project)

    reply_model = fn _assembled, _tools, _call -> {:ok, "obrigado"} end

    assert {:ok, ""} =
             CLI.run(
               [
                 "reply",
                 "--request_id",
                 request.id,
                 "--decision",
                 "grant",
                 "--scope",
                 "stage",
                 "pode para sempre"
               ],
               dir,
               reply_model
             )

    assert {:ok, %Config{workflows: %{"delivery" => [to_do]}}} = Config.load(dir)
    assert "delete" in to_do.ceiling.granted
  end
end
