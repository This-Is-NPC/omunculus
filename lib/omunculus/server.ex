defmodule Omunculus.Server do
  @moduledoc """
  Starts one runtime and one local socket per configured project, and the
  TCP listener when the registry names a `host` and `port`. A project that
  cannot be served, such as one with no `[access]` table, is logged and
  left out; the others keep running. `register/3` adds a project to the
  running server and to the registry file.
  """

  require Logger

  alias Omunculus.Server.{Auth, Config, Endpoint, Project, Socket, StreamLimiter}

  @spec start_link(String.t()) :: Supervisor.on_start()
  def start_link(path) do
    with {:ok, config} <- Config.load(path),
         {:ok, http} <- http_listener(config, Path.expand(path)) do
      stream_key = Path.expand(path)

      children =
        [{StreamLimiter, {stream_key, config.max_connections}}] ++
          Enum.flat_map(config.projects, fn {id, project_path} ->
            if servable?(id, project_path),
              do: project_children(id, project_path, config.limits, stream_key),
              else: []
          end) ++ http

      Supervisor.start_link(children, strategy: :one_for_one, name: via(stream_key))
    end
  end

  defp servable?(id, project_path) do
    with {:ok, config} <- Omunculus.Config.load(project_path),
         :ok <- Project.require_access(config) do
      true
    else
      {:error, :access_required} ->
        Logger.error(
          "project #{id} refused: #{project_path} has no [access] table; add one and run " <>
            "`omunculus access bootstrap` (see docs/server.md#project-access)"
        )

        false

      {:error, reason} ->
        Logger.error("project #{id} refused: cannot load #{project_path}: #{inspect(reason)}")
        false
    end
  end

  defp via(stream_key), do: {:via, Registry, {Omunculus.Server.Registry, {:server, stream_key}}}

  defp project_children(id, project_path, limits, stream_key) do
    limits = Map.put(limits, :scope, {:server, stream_key})

    [
      Supervisor.child_spec({Project, {id, project_path, limits}}, id: {:project, id}),
      Supervisor.child_spec({Socket, {id, project_path, stream_key}}, id: {:socket, id})
    ]
  end

  @doc "The ids of the projects the server at `stream_key` serves."
  @spec project_ids(String.t()) :: [String.t()]
  def project_ids(stream_key) do
    for {{:project, id}, _pid, _type, _modules} <- Supervisor.which_children(via(stream_key)),
        do: id
  end

  @doc """
  Starts the project `id` on the running server whose registry file is
  `stream_key`, then writes it into that file. The project must load with
  an `[access]` table; the other projects keep running.
  """
  @spec register(String.t(), term, String.t()) :: :ok | {:error, term}
  def register(stream_key, id, config) do
    :global.trans({{__MODULE__, stream_key}, self()}, fn ->
      with :ok <- unused(stream_key, id),
           {:ok, server} <- Config.load(stream_key),
           config = Path.expand(config, Path.dirname(stream_key)),
           true <- File.regular?(config) || {:error, {:server, :invalid_project, id}},
           :ok <- start(stream_key, id, config, server.limits) do
        with {:error, _reason} = error <- Config.add_project(stream_key, id, config) do
          stop(stream_key, id)
          error
        end
      end
    end)
  end

  defp unused(stream_key, id) do
    if is_binary(id) and id != "" and id not in project_ids(stream_key),
      do: :ok,
      else: {:error, {:server, :invalid_project, id}}
  end

  defp start(stream_key, id, config, limits) do
    Enum.reduce_while(project_children(id, config, limits, stream_key), :ok, fn spec, :ok ->
      case Supervisor.start_child(via(stream_key), spec) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, reason} ->
          stop(stream_key, id)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp stop(stream_key, id) do
    for key <- [{:socket, id}, {:project, id}] do
      Supervisor.terminate_child(via(stream_key), key)
      Supervisor.delete_child(via(stream_key), key)
    end

    :ok
  end

  defp http_listener(%Config{http: nil}, _stream_key), do: {:ok, []}

  defp http_listener(%Config{http: http} = config, stream_key) do
    with {:ok, auth} <- Auth.load(config.auth) do
      {:ok,
       [
         {Bandit,
          plug: {Endpoint, auth: auth, stream_key: stream_key}, ip: http.host, port: http.port}
       ]}
    end
  end

  @spec main([String.t()]) :: no_return()
  def main(["--config", path]) do
    case start_link(Path.expand(path)) do
      {:ok, supervisor} ->
        Process.unlink(supervisor)
        monitor = Process.monitor(supervisor)
        main = self()

        # The VM's own SIGTERM stop skips the supervisor, which is in no application.
        {:ok, _id} =
          System.trap_signal(:sigterm, fn ->
            send(main, :stop)
            :ok
          end)

        receive do
          :stop ->
            Supervisor.stop(supervisor)
            System.halt(0)

          {:DOWN, ^monitor, :process, ^supervisor, reason} ->
            IO.puts(:stderr, "server stopped: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "server failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def main(_argv) do
    IO.puts(:stderr, "usage: omunculus serve --config <server.toml>")
    System.halt(1)
  end
end
