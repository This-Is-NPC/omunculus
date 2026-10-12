defmodule Omunculus.Server do
  @moduledoc """
  Starts one runtime and one local socket per configured project, and the
  TCP listener when the registry names a `host` and `port`.
  """

  alias Omunculus.Server.{Auth, Config, Endpoint, Project, Socket, StreamLimiter}

  @spec start_link(String.t()) :: Supervisor.on_start()
  def start_link(path) do
    with {:ok, config} <- Config.load(path),
         {:ok, http} <- http_listener(config, Path.expand(path)) do
      limits = Map.put(config.limits, :scope, {:server, Path.expand(path)})
      stream_key = Path.expand(path)

      children =
        [{StreamLimiter, {stream_key, config.max_connections}}] ++
          Enum.flat_map(config.projects, fn {id, project_path} ->
            [
              Supervisor.child_spec({Project, {id, project_path, limits}}, id: {:project, id}),
              Supervisor.child_spec(
                {Socket, {id, project_path, stream_key, Map.keys(config.projects)}},
                id: {:socket, id}
              )
            ]
          end) ++ http

      Supervisor.start_link(children, strategy: :one_for_one)
    end
  end

  defp http_listener(%Config{http: nil}, _stream_key), do: {:ok, []}

  defp http_listener(%Config{http: http} = config, stream_key) do
    with {:ok, auth} <- Auth.load(config.auth) do
      {:ok,
       [
         {Bandit,
          plug:
            {Endpoint, auth: auth, projects: Map.keys(config.projects), stream_key: stream_key},
          ip: http.host,
          port: http.port}
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
