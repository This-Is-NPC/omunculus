defmodule Mix.Tasks.Omunculus.Socket do
  @moduledoc """
  Prints a project of a server registry and its local socket, separated by
  a tab: `mix omunculus.socket <server.toml> [<id>]`. The id may be left
  out when the registry holds one project.
  """

  use Mix.Task

  alias Omunculus.{Config, Server}

  @shortdoc "Prints a registry project's local socket"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    with {:ok, path, id} <- args(argv),
         {:ok, registry} <- Server.Config.load(path),
         {:ok, id, config_path} <- project(registry.projects, id),
         {:ok, config} <- Config.load(config_path) do
      IO.puts(id <> "\t" <> Server.Socket.path(config.store.path))
    else
      {:error, reason} -> Mix.raise("omunculus.socket: #{inspect(reason)}")
    end
  end

  defp args([path]), do: {:ok, path, nil}
  defp args([path, id]), do: {:ok, path, id}
  defp args(_), do: {:error, :usage}

  defp project(projects, nil) do
    case Map.to_list(projects) do
      [{id, config_path}] -> {:ok, id, config_path}
      _ -> {:error, {:project, :ambiguous, Map.keys(projects)}}
    end
  end

  defp project(projects, id) do
    case Map.fetch(projects, id) do
      {:ok, config_path} -> {:ok, id, config_path}
      :error -> {:error, {:project, :unknown, id}}
    end
  end
end
