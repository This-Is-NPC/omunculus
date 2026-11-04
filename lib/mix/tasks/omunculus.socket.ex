defmodule Mix.Tasks.Omunculus.Socket do
  @moduledoc """
  Prints a project of a server registry and its local socket, separated by
  a tab: `mix omunculus.socket <server.toml> [<id>] [--any]`. The id may be
  left out when the registry holds one project. With `--any` and no id, a
  registry of several prints an empty id and the socket of its first
  project by id, which lists the whole registry.
  """

  use Mix.Task

  alias Omunculus.{Config, Server}

  @shortdoc "Prints a registry project's local socket"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    with {:ok, path, id, any} <- args(argv),
         {:ok, registry} <- Server.Config.load(path),
         {:ok, id, config_path} <- project(registry.projects, id, any),
         {:ok, config} <- Config.load(config_path) do
      IO.puts(id <> "\t" <> Server.Socket.path(config.store.path))
    else
      {:error, reason} -> Mix.raise("omunculus.socket: #{inspect(reason)}")
    end
  end

  defp args(argv) do
    case OptionParser.parse(argv, strict: [any: :boolean]) do
      {opts, [path], []} -> {:ok, path, nil, opts[:any] == true}
      {opts, [path, id], []} -> {:ok, path, id, opts[:any] == true}
      _ -> {:error, :usage}
    end
  end

  defp project(projects, nil, any) do
    case Enum.sort(projects) do
      [{id, config_path}] -> {:ok, id, config_path}
      [{_id, config_path} | _] when any -> {:ok, "", config_path}
      _ -> {:error, {:project, :ambiguous, Map.keys(projects)}}
    end
  end

  defp project(projects, id, _any) do
    case Map.fetch(projects, id) do
      {:ok, config_path} -> {:ok, id, config_path}
      :error -> {:error, {:project, :unknown, id}}
    end
  end
end
