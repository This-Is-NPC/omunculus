defmodule Omunculus.Execution.Policy do
  @moduledoc """
  Builds the immutable filesystem, environment, and network constraints for a
  single run before an external process is started.
  """

  alias Omunculus.{Ceiling, Config, Project}
  alias Omunculus.Path, as: FilesystemPath

  @enforce_keys [
    :id,
    :workspace,
    :read_only,
    :read_write,
    :hidden,
    :runtimes,
    :environment,
    :network,
    :limits,
    :tools
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          workspace: %{name: String.t() | nil, root: String.t()},
          read_only: [String.t()],
          read_write: [String.t()],
          hidden: [String.t()],
          runtimes: [String.t()],
          environment: %{String.t() => String.t()},
          network: String.t(),
          limits: %{
            timeout_ms: pos_integer,
            max_output_bytes: pos_integer,
            max_concurrent: pos_integer,
            max_queue: pos_integer,
            queue_timeout_ms: pos_integer
          },
          tools: [String.t()]
        }

  @spec build(Config.t(), map, map, String.t(), [String.t()]) :: {:ok, t} | {:error, term}
  def build(config, snapshot, workspace, project_dir, tools) do
    with {:ok, project_root} <- canonical_directory(project_dir, :project),
         {:ok, workspace_root} <- canonical_directory(workspace.root || project_root, :workspace),
         :ok <- validate_workspace_boundary(config, workspace.name, workspace_root),
         {:ok, paths} <- resolve_ceiling_paths(snapshot, workspace_root),
         {:ok, runtimes} <- resolve_runtimes(config.execution.runtimes, workspace_root),
         hidden <- unique(paths.denied ++ paths.restricted ++ protected_paths(project_root)),
         policy <-
           build_policy(
             config,
             snapshot,
             workspace,
             workspace_root,
             paths.allowed,
             hidden,
             runtimes,
             tools
           ) do
      {:ok, policy}
    end
  end

  @spec serializable(t) :: map
  def serializable(%__MODULE__{} = policy) do
    %{
      "id" => policy.id,
      "workspace" => %{"name" => policy.workspace.name, "root" => policy.workspace.root},
      "read_only" => policy.read_only,
      "read_write" => policy.read_write,
      "hidden" => policy.hidden,
      "runtimes" => policy.runtimes,
      "environment" => Map.keys(policy.environment) |> Enum.sort(),
      "network" => policy.network,
      "limits" => stringify_keys(policy.limits),
      "tools" => policy.tools
    }
  end

  defp build_policy(config, snapshot, workspace, workspace_root, allowed, hidden, runtimes, tools) do
    write? = Ceiling.classify(snapshot, "sandbox.write", "resource") == "have"

    network =
      if Ceiling.classify(snapshot, "sandbox.network", "resource") == "have",
        do: "host",
        else: "none"

    external_allowed = Enum.reject(allowed, &FilesystemPath.within?(workspace_root, &1))

    read_only =
      if write? do
        external_allowed
      else
        [workspace_root | external_allowed]
      end
      |> unique()

    read_write = if write?, do: [workspace_root], else: []

    limits = %{
      timeout_ms: config.execution.timeout_ms,
      max_output_bytes: config.execution.max_output_bytes,
      max_concurrent: config.execution.max_concurrent,
      max_queue: config.execution.max_queue,
      queue_timeout_ms: config.execution.queue_timeout_ms
    }

    policy = %__MODULE__{
      id: "",
      workspace: %{name: workspace.name, root: workspace_root},
      read_only: read_only,
      read_write: read_write,
      hidden: hidden,
      runtimes: runtimes,
      environment: environment(config.execution.environment),
      network: network,
      limits: limits,
      tools: Enum.sort(tools)
    }

    %{policy | id: policy_id(policy)}
  end

  defp resolve_ceiling_paths(snapshot, workspace_root) do
    paths = Ceiling.paths(snapshot, workspace_root)

    with {:ok, allowed} <- resolve_paths(paths["allowed"], :allowed, workspace_root),
         {:ok, denied} <- resolve_paths(paths["denied"], :denied, workspace_root),
         {:ok, restricted} <- resolve_paths(paths["restricted"], :restricted, workspace_root) do
      {:ok, %{allowed: allowed, denied: denied, restricted: restricted}}
    end
  end

  defp resolve_paths(paths, kind, workspace_root) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, canonical} <- FilesystemPath.canonical(path),
           :ok <- validate_path(kind, path, canonical, workspace_root) do
        {:cont, {:ok, [canonical | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:path, kind, path, reason}}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, unique(resolved)}
      error -> error
    end
  end

  defp validate_path(:allowed, _path, canonical, workspace_root) do
    if FilesystemPath.within?(workspace_root, canonical) or File.exists?(canonical),
      do: :ok,
      else: {:error, :missing}
  end

  defp validate_path(_kind, _path, _canonical, _workspace_root), do: :ok

  defp resolve_runtimes(paths, workspace_root) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, runtime} <- canonical_directory(path, :runtime),
           false <- FilesystemPath.within?(runtime, System.user_home!()),
           false <- FilesystemPath.within?(runtime, workspace_root) do
        {:cont, {:ok, [runtime | acc]}}
      else
        true -> {:halt, {:error, {:runtime, path, :overlaps_protected_path}}}
        {:error, reason} -> {:halt, {:error, {:runtime, path, reason}}}
      end
    end)
    |> case do
      {:ok, runtimes} -> {:ok, unique(runtimes)}
      error -> error
    end
  end

  defp validate_workspace_boundary(config, current_name, workspace_root) do
    Enum.reduce_while(config.workspaces, :ok, fn {name, %{root: root}}, :ok ->
      if name == current_name do
        {:cont, :ok}
      else
        case canonical_directory(root, :workspace) do
          {:ok, other_root} ->
            if FilesystemPath.within?(workspace_root, other_root) do
              {:halt, {:error, {:workspace, {:contains_workspace, name}}}}
            else
              {:cont, :ok}
            end

          {:error, reason} ->
            {:halt, {:error, {:workspace, name, reason}}}
        end
      end
    end)
  end

  defp canonical_directory(path, label) do
    with {:ok, canonical} <- FilesystemPath.canonical(path),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, {label, :not_a_directory}}
      {:error, reason} -> {:error, {label, reason}}
    end
  end

  defp protected_paths(project_root) do
    [Project.state_dir(project_root), Path.join(project_root, "omunculus.toml")]
    |> Enum.map(&Path.expand/1)
  end

  defp environment(names) do
    Map.new(names, fn name -> {name, System.get_env(name, "")} end)
  end

  defp policy_id(policy) do
    policy
    |> serializable()
    |> Map.put("id", nil)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp unique(paths), do: paths |> Enum.uniq() |> Enum.sort()
end
