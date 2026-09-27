defmodule Omunculus.Server do
  @moduledoc "Starts the optional HTTP listener and one runtime per configured project."

  alias Omunculus.Server.{Auth, Config, Endpoint, Project, StreamLimiter}

  @spec start_link(String.t()) :: Supervisor.on_start()
  def start_link(path) do
    with {:ok, config} <- Config.load(path),
         {:ok, auth} <- Auth.load(config) do
      limits = Map.put(config.limits, :scope, {:server, Path.expand(path)})
      stream_key = Path.expand(path)

      children =
        [{StreamLimiter, {stream_key, config.max_connections}}] ++
          Enum.map(config.projects, fn {id, project_path} ->
            Supervisor.child_spec({Project, {id, project_path, limits}}, id: {:project, id})
          end) ++
          [
            {Bandit,
             plug:
               {Endpoint, auth: auth, projects: Map.keys(config.projects), stream_key: stream_key},
             ip: config.host,
             port: config.port}
          ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end
  end

  @spec main([String.t()]) :: no_return()
  def main(["--config", path]) do
    case start_link(Path.expand(path)) do
      {:ok, supervisor} ->
        Process.unlink(supervisor)
        monitor = Process.monitor(supervisor)

        receive do
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
