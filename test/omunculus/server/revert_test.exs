defmodule Omunculus.Server.RevertTest do
  use ExUnit.Case, async: false

  alias Omunculus.{CLI, Config, Fixtures, Operations, Project, Server}
  alias Omunculus.Server.Socket
  alias Omunculus.Store.Access

  @access """

  [access]
  creator_role = "participant"
  bootstrap_role = "admin"

  [access.roles.admin]
  scope = "project"
  capabilities = ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read", "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access", "conversation.manage"]

  [access.roles.participant]
  scope = "conversation"
  capabilities = ["conversation.read", "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access"]

  [access.roles.viewer]
  scope = "project"
  capabilities = ["conversation.read"]
  """

  setup do
    root = Path.expand(".scratch/revert-001", File.cwd!())
    File.mkdir_p!(root)
    Enum.each(File.ls!(root), &File.rm_rf!(Path.join(root, &1)))

    on_exit(fn ->
      File.rm_rf!(root)
      File.rmdir(Path.dirname(root))
    end)

    %{root: root}
  end

  defp toml(root, deny) do
    """
    [workspaces.one]
    root = "#{root}"
    #{deny}

    [policy]
    workspace = "one"

    [agents.concierge]
    depth = 0
    text = "concierge"
    tools = ["end", "write", "sandbox.write"]

    [store]
    path = ".omunculus/store.sqlite3"
    changes = ".omunculus/changes"
    """
  end

  test "reverting a work is for the members holding project.manage_config, under the workspace's write rules",
       %{root: root} do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, toml(root, ""))

    project = Fixtures.open_project(dir)
    work_id = Fixtures.insert(project.conn, :works, %{title: "Note", assignee: "concierge"})
    Project.close(project)

    Fixtures.use_model(dir, fn _assembled, _tools, call ->
      assert {:ok, ""} = call.("write", %{"path" => "note.txt", "content" => "hi\n"})
      {:ok, "done"}
    end)

    assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "hi"], dir)
    note = Path.join(root, "note.txt")
    assert File.read!(note) == "hi\n"

    config_path = Fixtures.config_path(dir)
    File.write!(config_path, File.read!(config_path) <> @access)
    uid = Operations.local_principal().subject
    local = %{issuer: "local", subject: uid}
    viewer = %{issuer: "test", subject: "viewer"}

    assert {:ok, "access bootstrapped"} =
             CLI.run(
               ["--config", config_path, "access", "bootstrap", "--issuer", "local"] ++
                 ["--subject", uid],
               dir
             )

    project = Fixtures.open_project(dir)
    assert :ok = Access.put_member(project, local, viewer, "viewer")
    Project.close(project)

    server_path = Path.join(dir, "server.toml")

    File.write!(server_path, """
    [server]
    max_concurrent = 4
    max_queue = 64
    queue_timeout_ms = 30000
    max_connections = 4

    [projects.solo]
    config = "omunculus.toml"
    """)

    {:ok, config} = Config.load(config_path)
    socket = Socket.path(config.store.path)
    {:ok, _server} = Server.start_link(server_path)

    request = fn method, path, key ->
      Req.request!(
        method: method,
        url: "http://localhost" <> path,
        unix_socket: socket,
        retry: false,
        headers: [{"idempotency-key", key}],
        json: %{}
      )
    end

    path = "/v1/projects/solo/works/#{work_id}/revert"

    assert Req.get!("http://localhost/v1/projects/solo/capabilities", unix_socket: socket).body ==
             %{"items" => String.split(capabilities(), " ")}

    assert {:error, :forbidden} =
             Server.Project.command("solo", "revert", %{"work_id" => work_id}, viewer, nil, "v1")

    assert File.read!(note) == "hi\n"

    Fixtures.write_config(dir, toml(root, ~s(deny = ["sandbox.write"])) <> @access)

    refused = request.(:post, path, "r1")
    assert refused.status == 422
    assert refused.body["error"] == "tool_failed"

    assert refused.body["message"] ==
             "path is not writable: note.txt; writing needs sandbox.write"

    assert File.read!(note) == "hi\n"
    assert request.(:post, path, "r1").body == refused.body

    Fixtures.write_config(dir, toml(root, "") <> @access)

    reverted = request.(:post, path, "r2")
    assert reverted.status == 202
    assert reverted.body["status"] == "accepted"
    refute File.exists?(note)
  end

  defp capabilities do
    "project.manage_access project.manage_config conversation.create conversation.read " <>
      "conversation.send conversation.comment conversation.reply " <>
      "conversation.manage_access conversation.manage"
  end
end
