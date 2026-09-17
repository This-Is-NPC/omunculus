defmodule Omunculus.Execution.Policy do
  @moduledoc """
  Builds the immutable filesystem, environment, and network constraints for a
  single run before an external process is started.
  """

  alias Omunculus.{Ceiling, Config}
  alias Omunculus.Path, as: FilesystemPath

  @resources ~w(sandbox.write sandbox.network)

  @enforce_keys [
    :id,
    :workspace,
    :read_only,
    :read_write,
    :hidden,
    :runtimes,
    :backend,
    :environment,
    :network,
    :limits,
    :tools,
    :sandbox
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          workspace: %{name: String.t() | nil, root: String.t()},
          read_only: [String.t()],
          read_write: [String.t()],
          hidden: [String.t()],
          runtimes: [String.t()],
          backend: String.t(),
          environment: %{String.t() => String.t()},
          network: String.t(),
          limits: %{
            timeout_ms: pos_integer,
            max_output_bytes: pos_integer,
            max_concurrent: pos_integer,
            max_queue: pos_integer,
            queue_timeout_ms: pos_integer
          },
          tools: [String.t()],
          sandbox: %{
            script: String.t(),
            command: [String.t()],
            runner: String.t(),
            exec: String.t()
          }
        }

  @spec build(Config.t(), map, map, String.t(), [String.t()], [String.t()]) ::
          {:ok, t} | {:error, term}
  def build(config, snapshot, workspace, project_dir, tools, implementation_roots) do
    with :ok <- validate_resources(config),
         {:ok, project_root} <- canonical_directory(project_dir, :project),
         {:ok, workspace_root} <- canonical_directory(workspace.root || project_root, :workspace),
         :ok <- validate_workspace_boundary(config, workspace.name, workspace_root),
         {:ok, paths} <- resolve_ceiling_paths(snapshot, workspace_root),
         {:ok, runtimes} <- resolve_runtimes(config.execution.runtimes, workspace_root),
         {:ok, implementation_roots} <- resolve_implementation_roots(implementation_roots),
         hidden <- unique(paths.denied ++ paths.restricted ++ protected_paths(config)),
         policy <-
           build_policy(
             config,
             snapshot,
             workspace,
             workspace_root,
             paths.allowed,
             hidden,
             runtimes,
             tools,
             implementation_roots
           ) do
      {:ok, policy}
    end
  end

  @spec restricted(Config.t(), map, String.t(), [String.t()]) :: {:ok, t} | {:error, term}
  def restricted(config, workspace, project_dir, implementation_roots) do
    with :ok <- validate_resources(config),
         {:ok, project_root} <- canonical_directory(project_dir, :project),
         {:ok, workspace_root} <- canonical_directory(workspace.root || project_root, :workspace),
         :ok <- validate_workspace_boundary(config, workspace.name, workspace_root),
         {:ok, runtimes} <- resolve_runtimes(config.execution.runtimes, workspace_root),
         {:ok, implementation_roots} <- resolve_implementation_roots(implementation_roots) do
      policy = %__MODULE__{
        id: "",
        workspace: %{name: workspace.name, root: workspace_root},
        read_only: implementation_roots,
        read_write: [],
        hidden: protected_paths(config),
        runtimes: runtimes,
        backend: config.execution.backend,
        environment: environment(config.execution.environment),
        network: "none",
        limits: limits(config),
        tools: [],
        sandbox: config.execution.sandbox
      }

      {:ok, %{policy | id: policy_id(policy)}}
    end
  end

  @spec discovery(Config.t(), map, map, String.t(), [String.t()]) :: {:ok, t} | {:error, term}
  def discovery(config, snapshot, workspace, project_dir, implementation_roots) do
    with {:ok, policy} <- restricted(config, workspace, project_dir, implementation_roots) do
      network =
        if Ceiling.classify(snapshot, "sandbox.network", "resource") == "have",
          do: "host",
          else: "none"

      policy = %{policy | network: network}
      {:ok, %{policy | id: policy_id(policy)}}
    end
  end

  @spec coordinator(t, String.t()) :: {:ok, t} | {:error, term}
  def coordinator(%__MODULE__{} = policy, implementation_root) do
    with {:ok, implementation_root} <- canonical_directory(implementation_root, :implementation) do
      policy = %{
        policy
        | id: "",
          read_only: [implementation_root],
          read_write: [],
          network: "none"
      }

      {:ok, %{policy | id: policy_id(policy)}}
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
      "backend" => policy.backend,
      "environment" => Map.keys(policy.environment) |> Enum.sort(),
      "network" => policy.network,
      "limits" => stringify_keys(policy.limits),
      "tools" => policy.tools,
      "sandbox" => stringify_keys(policy.sandbox)
    }
  end

  @spec readable?(t, String.t()) :: boolean
  def readable?(%__MODULE__{} = policy, path) when is_binary(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path) do
      not protected?(policy, canonical) and
        Enum.any?(policy.read_only ++ policy.read_write, &FilesystemPath.within?(&1, canonical))
    else
      _ -> false
    end
  end

  @spec writable?(t, String.t()) :: boolean
  def writable?(%__MODULE__{} = policy, path) when is_binary(path) do
    with {:ok, canonical} <- FilesystemPath.canonical(path) do
      not protected?(policy, canonical) and
        Enum.any?(policy.read_write, &FilesystemPath.within?(&1, canonical)) and
        not Enum.any?(policy.read_only, &FilesystemPath.within?(&1, canonical))
    else
      _ -> false
    end
  end

  defp build_policy(
         config,
         snapshot,
         workspace,
         workspace_root,
         allowed,
         hidden,
         runtimes,
         tools,
         implementation_roots
       ) do
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
      |> Kernel.++(implementation_roots)
      |> unique()

    read_write = if write?, do: [workspace_root], else: []

    policy = %__MODULE__{
      id: "",
      workspace: %{name: workspace.name, root: workspace_root},
      read_only: read_only,
      read_write: read_write,
      hidden: hidden,
      runtimes: runtimes,
      backend: config.execution.backend,
      environment: environment(config.execution.environment),
      network: network,
      limits: limits(config),
      tools: Enum.sort(tools),
      sandbox: config.execution.sandbox
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

  defp resolve_implementation_roots(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case canonical_directory(root, :implementation) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, reason} -> {:halt, {:error, {:implementation, root, reason}}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, unique(resolved)}
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

  defp protected_paths(config) do
    store = Path.expand(config.store.path)
    parent = Path.dirname(store)
    root = Path.expand(config.root)

    store_hidden =
      if parent != root and FilesystemPath.within?(root, parent) do
        parent
      else
        store
      end

    [store_hidden, Path.expand(config.path)]
  end

  defp protected?(policy, path),
    do: Enum.any?(policy.hidden, &FilesystemPath.within?(&1, path))

  defp limits(config) do
    %{
      timeout_ms: config.execution.timeout_ms,
      max_output_bytes: config.execution.max_output_bytes,
      max_concurrent: config.execution.max_concurrent,
      max_queue: config.execution.max_queue,
      queue_timeout_ms: config.execution.queue_timeout_ms
    }
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

  defp validate_resources(%{execution: %{resources: resources}}) when is_list(resources) do
    case Enum.find(resources, &(&1 not in @resources)) do
      nil -> :ok
      name -> {:error, {:execution, {:unknown_resource, name}}}
    end
  end

  defp unique(paths), do: paths |> Enum.uniq() |> Enum.sort()
end
