defmodule Mix.Tasks.Omunculus.SocketTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Omunculus.Socket
  alias Omunculus.{Fixtures, Server}

  # A registry of the projects `ids`, each with its own config and store;
  # its path and each project's socket by id.
  defp registry(ids) do
    dir = Fixtures.tmp_dir()

    sockets =
      Map.new(ids, fn id ->
        project = Path.join(dir, id)
        File.mkdir_p!(project)
        Fixtures.install_default(project)
        {:ok, config} = Fixtures.load_config(project)
        {id, Server.Socket.path(config.store.path)}
      end)

    projects = Enum.map_join(ids, "\n", &"[projects.#{&1}]\nconfig = \"#{&1}/omunculus.toml\"\n")
    path = Path.join(dir, "server.toml")

    File.write!(path, """
    [server]
    max_concurrent = 4
    max_queue = 64
    queue_timeout_ms = 30000
    max_connections = 8

    #{projects}
    """)

    {path, sockets}
  end

  defp printed(argv), do: capture_io(fn -> Socket.run(argv) end)

  test "a registry of one prints its project, with or without an id or --any" do
    {path, %{"solo" => socket}} = registry(["solo"])

    assert printed([path]) == "solo\t#{socket}\n"
    assert printed([path, "solo"]) == "solo\t#{socket}\n"
    assert printed([path, "--any"]) == "solo\t#{socket}\n"
  end

  test "an id picks its project of several; an unknown one is refused" do
    {path, sockets} = registry(["beta", "alpha"])

    assert printed([path, "beta"]) == "beta\t#{sockets["beta"]}\n"
    assert printed([path, "beta", "--any"]) == "beta\t#{sockets["beta"]}\n"
    assert_raise Mix.Error, ~r/unknown/, fn -> printed([path, "gamma"]) end
  end

  test "several without an id: refused, or with --any the first by id's socket" do
    {path, sockets} = registry(["beta", "alpha"])

    assert_raise Mix.Error, ~r/ambiguous/, fn -> printed([path]) end
    assert printed([path, "--any"]) == "\t#{sockets["alpha"]}\n"
  end
end
