defmodule Omunculus.Tools.Project do
  @moduledoc """
  Builtin `project` tool: tells an existing project from a new one. `list`
  prints the workspaces, each with its name, path and the `client` and
  `summary` its table carries. `create` makes the folder `name` under
  `[project] workspaces_dir`, starts a repository there and writes
  `[workspaces.<name>]` through `Omunculus.Config.edit/5`, the write
  `configure` makes; a run reads the config again, so the next one sees
  it. Nothing is created without `workspaces_dir`, an unused `name` or
  a config that still loads with the workspace.
  """

  alias Omunculus.{Config, Errors, Git}
  alias Omunculus.Tools.{Args, Out}

  @name ~r/^[a-z0-9][a-z0-9_-]*$/

  @spec run(map) :: map
  def run(%{config_path: path, args: args}) when is_binary(path) do
    with {:ok, config} <- Config.load(path) do
      case args["action"] do
        "list" -> config |> list() |> Jason.encode!() |> Out.ok()
        "create" -> create(path, config, args)
        _ -> Out.fail("action must be list or create")
      end
    else
      {:error, reason} -> Out.fail(Errors.format(reason))
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp list(config) do
    for {name, workspace} <- Enum.sort(config.workspaces) do
      %{name: name, path: workspace.root, client: workspace.client, summary: workspace.summary}
    end
  end

  defp create(path, config, args) do
    with {:ok, name} <- Args.fetch(args, "name"),
         {:ok, parent} <- parent(config),
         :ok <- fresh(config, name, parent),
         dir = Path.join(parent, name),
         :ok <- make(dir),
         :ok <- register(path, name, dir, args) do
      Out.ok(Jason.encode!(%{name: name, path: dir}))
    else
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(Errors.format(reason))
    end
  end

  defp parent(%{workspaces_dir: dir}) when is_binary(dir), do: {:ok, dir}

  defp parent(_config),
    do: {:error, "omunculus.toml needs [project] workspaces_dir to create one"}

  defp fresh(config, name, parent) do
    cond do
      not Regex.match?(@name, name) ->
        {:error, "name must be lowercase letters, digits, - and _"}

      Map.has_key?(config.workspaces, name) ->
        {:error, "workspace #{name} exists; use it"}

      File.exists?(Path.join(parent, name)) ->
        {:error, "#{Path.join(parent, name)} exists; pick another name"}

      true ->
        :ok
    end
  end

  defp make(dir) do
    with :ok <- File.mkdir_p(dir),
         {:ok, _said} <- Git.run(["init"], dir) do
      :ok
    else
      error ->
        File.rm_rf(dir)
        {:error, "could not create #{dir}: #{inspect(error)}"}
    end
  end

  defp register(path, name, dir, args) do
    value = Enum.reduce(~w(client summary), %{"root" => dir}, &Args.put_present(&2, &1, args))

    with {:ok, %{revision: revision}} <- Config.document(path),
         :ok <- Config.edit(path, revision, {"workspaces", name}, value) do
      :ok
    else
      error ->
        File.rm_rf(dir)
        error
    end
  end
end
