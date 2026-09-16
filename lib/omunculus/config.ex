defmodule Omunculus.Config do
  @moduledoc """
  Loads and validates `omunculus.toml`: a project file replaces the
  package default whole, never merges with it (spec §5). Parses the
  policy layer, the per-depth layers under `[policy.depth.N]`, the
  workspaces under `[workspaces.<name>]` — each a directory `root`
  (resolved against the project dir) plus a ceiling layer — and the
  `[policy] workspace` default, each agent's ceiling layer, the named
  workflows under `[workflows.<name>]` (spec §3.4), and the MCP
  servers under `[[mcp.servers]]` (spec §8.7), and grants a permanent
  ceiling addition — to an agent, a depth, a workflow step, or a
  workspace — by rewriting the TOML file.
  """

  alias Omunculus.Config.Layer

  @enforce_keys [
    :policy,
    :depths,
    :workspaces,
    :agents,
    :workflows,
    :policy_workflow,
    :policy_workspace,
    :depth_workflows,
    :mcp
  ]
  defstruct @enforce_keys

  @type agent :: %{
          depth: non_neg_integer,
          text: String.t(),
          workflow_only: boolean,
          ceiling: Layer.t()
        }
  @type step :: %{name: String.t(), agent: String.t(), ceiling: Layer.t()}
  @type workspace :: %{root: String.t(), ceiling: Layer.t()}
  @type mcp_server :: %{name: String.t(), command: [String.t()]}
  @type t :: %__MODULE__{
          policy: Layer.t(),
          depths: %{non_neg_integer => Layer.t()},
          workspaces: %{String.t() => workspace},
          agents: %{String.t() => agent},
          workflows: %{String.t() => [step]},
          policy_workflow: String.t() | nil,
          policy_workspace: String.t() | nil,
          depth_workflows: %{non_neg_integer => String.t()},
          mcp: [mcp_server]
        }

  @layer_keys ~w(mode granted tools negotiable human deny)
  @agent_extra_keys ~w(depth text workflow_only)
  @step_extra_keys ~w(name agent)

  @spec load(String.t()) :: {:ok, t} | {:error, term}
  def load(project_dir) do
    with {:ok, data} <- Toml.decode_file(config_path(project_dir)) do
      parse(data, project_dir)
    end
  end

  @spec effective_workspace(t, map | nil) :: String.t() | nil
  def effective_workspace(%__MODULE__{policy_workspace: policy_workspace}, work),
    do: (work && Map.get(work, :workspace)) || policy_workspace

  @spec workspace_ceiling(t, String.t() | nil) :: Layer.t() | nil
  def workspace_ceiling(_config, nil), do: nil

  def workspace_ceiling(config, name),
    do: config.workspaces |> Map.get(name) |> then(&(&1 && &1.ceiling))

  @spec workspace_root(t, String.t() | nil) :: String.t() | nil
  def workspace_root(_config, nil), do: nil

  def workspace_root(config, name),
    do: config.workspaces |> Map.get(name) |> then(&(&1 && &1.root))

  @spec agent_at_depth(t, non_neg_integer) ::
          {:ok, {String.t(), agent}} | {:error, {:no_agent_at_depth, non_neg_integer}}
  def agent_at_depth(%__MODULE__{agents: agents}, depth) do
    agents
    |> Enum.sort_by(fn {name, _agent} -> name end)
    |> Enum.find(fn {_name, agent} -> agent.depth == depth and not agent.workflow_only end)
    |> case do
      nil -> {:error, {:no_agent_at_depth, depth}}
      {name, agent} -> {:ok, {name, agent}}
    end
  end

  @spec workflow_for(t, non_neg_integer) :: {:ok, [step]} | :off
  def workflow_for(%__MODULE__{} = config, depth) do
    case workflow_name_for(config, depth) do
      nil -> :off
      name -> Map.fetch(config.workflows, name)
    end
  end

  @spec workflow_name_for(t, non_neg_integer) :: String.t() | nil
  def workflow_name_for(%__MODULE__{} = config, depth) do
    case Map.get(config.depth_workflows, depth) || config.policy_workflow do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  @spec step_at([step], String.t()) :: {:ok, step} | {:error, :off_sequence}
  def step_at(steps, stage) do
    case Enum.find(steps, &(&1.name == stage)) do
      nil -> {:error, :off_sequence}
      step -> {:ok, step}
    end
  end

  @spec next_step([step], String.t()) :: {:ok, step | nil} | {:error, :off_sequence}
  def next_step(steps, stage) do
    case Enum.find_index(steps, &(&1.name == stage)) do
      nil -> {:error, :off_sequence}
      index -> {:ok, Enum.at(steps, index + 1)}
    end
  end

  @type grant_layer ::
          {:agent, String.t()}
          | {:depth, non_neg_integer}
          | {:stage, String.t(), String.t()}
          | {:workspace, String.t()}

  @spec grant(String.t(), grant_layer, String.t()) :: :ok | {:error, term}
  def grant(project_dir, layer, name) do
    with {:ok, data} <- Toml.decode_file(config_path(project_dir)),
         {:ok, data} <- add_grant(data, layer, name) do
      File.write(Path.join(project_dir, "omunculus.toml"), Omunculus.Config.Toml.encode(data))
    end
  end

  defp config_path(project_dir) do
    project_file = Path.join(project_dir, "omunculus.toml")

    if File.regular?(project_file) do
      project_file
    else
      Application.app_dir(:omunculus, "priv/omunculus.toml")
    end
  end

  defp add_grant(data, {:agent, agent_name}, name) do
    agents = Map.get(data, "agents", %{})

    case Map.fetch(agents, agent_name) do
      :error -> {:error, {:agent, agent_name, :unknown}}
      {:ok, agent} -> {:ok, put_in(data, keys(["agents", agent_name]), add_name(agent, name))}
    end
  end

  defp add_grant(data, {:depth, n}, name) do
    path = keys(["policy", "depth", Integer.to_string(n)])
    {:ok, put_in(data, path, add_name(get_in(data, path), name))}
  end

  defp add_grant(data, {:workspace, workspace_name}, name) do
    path = keys(["workspaces", workspace_name])
    {:ok, put_in(data, path, add_name(get_in(data, path), name))}
  end

  defp add_grant(data, {:stage, workflow_name, stage}, name) do
    workflows = Map.get(data, "workflows", %{})

    case Map.fetch(workflows, workflow_name) do
      :error ->
        {:error, {:workflow, workflow_name, :unknown}}

      {:ok, workflow} ->
        case update_step(Map.get(workflow, "steps", []), stage, name) do
          {:ok, steps} ->
            {:ok,
             put_in(data, keys(["workflows", workflow_name]), Map.put(workflow, "steps", steps))}

          :error ->
            {:error, {:workflow, workflow_name, {:unknown_step, stage}}}
        end
    end
  end

  defp update_step(steps, stage, name) do
    if Enum.any?(steps, &(&1["name"] == stage)) do
      {:ok,
       Enum.map(steps, fn
         %{"name" => ^stage} = step -> add_name(step, name)
         step -> step
       end)}
    else
      :error
    end
  end

  defp keys(path), do: Enum.map(path, &Access.key(&1, %{}))

  defp add_name(layer, name) do
    layer =
      Enum.reduce(["human", "negotiable"], layer, fn key, acc ->
        if Map.has_key?(acc, key), do: Map.update!(acc, key, &List.delete(&1, name)), else: acc
      end)

    if is_list(layer["tools"]) do
      Map.put(layer, "tools", add_unique(layer["tools"], name))
    else
      Map.put(layer, "granted", add_unique(Map.get(layer, "granted", []), name))
    end
  end

  defp add_unique(list, name) do
    if name in list, do: list, else: list ++ [name]
  end

  defp parse(data, project_dir) do
    case Map.keys(data) -- ["policy", "workspaces", "agents", "workflows", "mcp"] do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, workspaces} <- parse_workspaces(Map.get(data, "workspaces", %{}), project_dir),
             {:ok, agents} <- parse_agents(Map.get(data, "agents", %{})),
             {:ok, workflows} <- parse_workflows(Map.get(data, "workflows", %{}), agents),
             {:ok, policy, depths, policy_workflow, policy_workspace, depth_workflows} <-
               parse_policy(Map.get(data, "policy", %{}), workflows, workspaces),
             {:ok, mcp} <- parse_mcp(Map.get(data, "mcp", %{})) do
          if map_size(agents) == 0 do
            {:error, :no_agents}
          else
            {:ok,
             %__MODULE__{
               policy: policy,
               depths: depths,
               workspaces: workspaces,
               agents: agents,
               workflows: workflows,
               policy_workflow: policy_workflow,
               policy_workspace: policy_workspace,
               depth_workflows: depth_workflows,
               mcp: mcp
             }}
          end
        end
    end
  end

  defp parse_mcp(data) when is_map(data) do
    case Map.keys(data) -- ["servers"] do
      [key | _] -> {:error, {:mcp, {:unknown_key, key}}}
      [] -> parse_mcp_servers(Map.get(data, "servers", []))
    end
  end

  defp parse_mcp(_data), do: {:error, {:mcp, {:invalid, :servers}}}

  defp parse_mcp_servers(servers) when is_list(servers) do
    Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
      case parse_mcp_server(server, acc) do
        {:ok, server} -> {:cont, {:ok, acc ++ [server]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_mcp_servers(_servers), do: {:error, {:mcp, {:invalid, :servers}}}

  defp parse_mcp_server(data, acc) when is_map(data) do
    with {:ok, name} <- mcp_string(data, "name"),
         :ok <- check_unique_mcp_name(acc, name),
         {:ok, command} <- mcp_command(data) do
      {:ok, %{name: name, command: command}}
    end
  end

  defp parse_mcp_server(_data, _acc), do: {:error, {:mcp, {:invalid, :servers}}}

  defp check_unique_mcp_name(acc, name) do
    if Enum.any?(acc, &(&1.name == name)),
      do: {:error, {:mcp, {:duplicate, name}}},
      else: :ok
  end

  defp mcp_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:mcp, {:invalid, String.to_atom(key)}}}
    end
  end

  defp mcp_command(data) do
    case Map.fetch(data, "command") do
      {:ok, [_ | _] = list} ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, {:mcp, {:invalid, :command}}}

      _ ->
        {:error, {:mcp, {:invalid, :command}}}
    end
  end

  defp parse_policy(data, workflows, workspaces) when is_map(data) do
    depth_data = Map.get(data, "depth", %{})
    workflow_data = Map.get(data, "workflow")
    workspace_data = Map.get(data, "workspace")
    layer_data = data |> Map.delete("depth") |> Map.delete("workflow") |> Map.delete("workspace")

    case Map.keys(layer_data) -- @layer_keys do
      [key | _] ->
        {:error, {:policy, {:unknown_key, key}}}

      [] ->
        with {:ok, policy} <- tag_error(parse_layer(layer_data, "auto"), :policy),
             {:ok, policy_workflow} <-
               tag_error(fetch_workflow(workflow_data, workflows), :policy),
             {:ok, policy_workspace} <-
               tag_error(fetch_workspace(workspace_data, workspaces), :policy),
             :ok <- ensure_default_workspace(policy_workspace, workspaces),
             {:ok, depths, depth_workflows} <- parse_depths(depth_data, workflows) do
          {:ok, policy, depths, policy_workflow, policy_workspace, depth_workflows}
        end
    end
  end

  defp tag_error({:ok, _} = ok, _tag), do: ok
  defp tag_error({:error, reason}, tag), do: {:error, {tag, reason}}

  defp fetch_workflow(nil, _workflows), do: {:ok, nil}

  defp fetch_workflow(name, workflows) when is_binary(name) do
    if Map.has_key?(workflows, name) do
      {:ok, name}
    else
      {:error, {:unknown_workflow, name}}
    end
  end

  defp fetch_workflow(_invalid, _workflows), do: {:error, {:invalid, :workflow}}

  defp fetch_workspace(nil, _workspaces), do: {:ok, nil}

  defp fetch_workspace(name, workspaces) when is_binary(name) do
    if Map.has_key?(workspaces, name) do
      {:ok, name}
    else
      {:error, {:unknown_workspace, name}}
    end
  end

  defp fetch_workspace(_invalid, _workspaces), do: {:error, {:invalid, :workspace}}

  defp ensure_default_workspace(nil, workspaces) when map_size(workspaces) > 0,
    do: {:error, {:policy, :no_default_workspace}}

  defp ensure_default_workspace(_policy_workspace, _workspaces), do: :ok

  defp parse_depths(data, workflows) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}, %{}}, fn {key, value}, {:ok, layers, depth_workflows} ->
      case parse_depth_entry(key, value, workflows) do
        {:ok, n, layer, workflow} ->
          depth_workflows =
            if workflow, do: Map.put(depth_workflows, n, workflow), else: depth_workflows

          {:cont, {:ok, Map.put(layers, n, layer), depth_workflows}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp parse_depths(_data, _workflows), do: {:error, {:policy, {:invalid, :depth}}}

  defp parse_depth_entry(key, value, workflows) do
    case Integer.parse(key) do
      {n, ""} when n >= 0 ->
        workflow_data = Map.get(value, "workflow")
        layer_data = Map.delete(value, "workflow")

        with {:ok, layer} <- parse_layer(layer_data, nil),
             {:ok, workflow} <- fetch_workflow(workflow_data, workflows) do
          {:ok, n, layer, workflow}
        else
          {:error, reason} -> {:error, {:policy, {:depth, n, reason}}}
        end

      _ ->
        {:error, {:policy, {:invalid, :depth}}}
    end
  end

  defp parse_workspaces(data, project_dir) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case parse_workspace(value, project_dir) do
        {:ok, workspace} -> {:cont, {:ok, Map.put(acc, name, workspace)}}
        {:error, reason} -> {:halt, {:error, {:workspace, name, reason}}}
      end
    end)
  end

  @workspace_keys ["root" | @layer_keys]

  defp parse_workspace(data, project_dir) when is_map(data) do
    case Map.keys(data) -- @workspace_keys do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, root} <- fetch_root(data, project_dir),
             {:ok, ceiling} <- parse_layer(Map.delete(data, "root"), nil) do
          {:ok, %{root: root, ceiling: ceiling}}
        end
    end
  end

  defp fetch_root(data, project_dir) do
    case Map.fetch(data, "root") do
      {:ok, root} when is_binary(root) and root != "" -> {:ok, Path.expand(root, project_dir)}
      _ -> {:error, {:invalid, :root}}
    end
  end

  defp parse_agents(agents) when is_map(agents) do
    Enum.reduce_while(agents, {:ok, %{}}, fn {name, data}, {:ok, acc} ->
      case parse_agent(name, data) do
        {:ok, agent} -> {:cont, {:ok, Map.put(acc, name, agent)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_agent(name, data) when is_map(data) do
    case Map.keys(data) -- (@agent_extra_keys ++ @layer_keys) do
      [key | _] ->
        {:error, {:agent, name, {:unknown_key, key}}}

      [] ->
        with {:ok, depth} <- fetch_depth(data),
             {:ok, text} <- fetch_text(data),
             {:ok, workflow_only} <- fetch_workflow_only(data),
             {:ok, ceiling} <- parse_layer(Map.drop(data, @agent_extra_keys), nil) do
          {:ok, %{depth: depth, text: text, workflow_only: workflow_only, ceiling: ceiling}}
        else
          {:error, reason} -> {:error, {:agent, name, reason}}
        end
    end
  end

  defp parse_agent(name, _data), do: {:error, {:agent, name, {:invalid, :depth}}}

  defp fetch_depth(data) do
    case Map.fetch(data, "depth") do
      {:ok, depth} when is_integer(depth) and depth >= 0 -> {:ok, depth}
      _ -> {:error, {:invalid, :depth}}
    end
  end

  defp fetch_text(data) do
    case Map.fetch(data, "text") do
      {:ok, text} when is_binary(text) -> {:ok, text}
      _ -> {:error, {:invalid, :text}}
    end
  end

  defp fetch_workflow_only(data) do
    case Map.fetch(data, "workflow_only") do
      :error -> {:ok, false}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid, :workflow_only}}
    end
  end

  defp parse_workflows(data, agents) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case parse_workflow(name, value, agents) do
        {:ok, steps} -> {:cont, {:ok, Map.put(acc, name, steps)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_workflow(name, data, agents) when is_map(data) do
    case Map.keys(data) -- ["steps"] do
      [key | _] ->
        {:error, {:workflow, name, {:unknown_key, key}}}

      [] ->
        case Map.get(data, "steps") do
          [_ | _] = steps -> parse_steps(name, steps, agents)
          _ -> {:error, {:workflow, name, :no_steps}}
        end
    end
  end

  defp parse_steps(workflow, steps, agents) do
    Enum.reduce_while(steps, {:ok, []}, fn step_data, {:ok, acc} ->
      with {:ok, step} <- parse_step(workflow, step_data, agents),
           :ok <- check_unique_step(acc, step.name, workflow) do
        {:cont, {:ok, acc ++ [step]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_unique_step(acc, name, workflow) do
    if Enum.any?(acc, &(&1.name == name)) do
      {:error, {:workflow, workflow, {:duplicate_step, name}}}
    else
      :ok
    end
  end

  defp parse_step(workflow, data, agents) when is_map(data) do
    case Map.keys(data) -- (@step_extra_keys ++ @layer_keys) do
      [key | _] ->
        {:error, {:workflow, workflow, {:unknown_key, key}}}

      [] ->
        with {:ok, name} <- fetch_step_name(data),
             {:ok, agent} <- fetch_step_agent(data, agents),
             {:ok, ceiling} <- parse_layer(Map.drop(data, @step_extra_keys), nil) do
          {:ok, %{name: name, agent: agent, ceiling: ceiling}}
        else
          {:error, reason} -> {:error, {:workflow, workflow, reason}}
        end
    end
  end

  defp fetch_step_name(data) do
    case Map.fetch(data, "name") do
      {:ok, name} when is_binary(name) -> {:ok, name}
      _ -> {:error, {:invalid, :name}}
    end
  end

  defp fetch_step_agent(data, agents) do
    case Map.fetch(data, "agent") do
      {:ok, agent} when is_binary(agent) ->
        if Map.has_key?(agents, agent) do
          {:ok, agent}
        else
          {:error, {:unknown_agent, agent}}
        end

      _ ->
        {:error, {:invalid, :agent}}
    end
  end

  defp parse_layer(data, default_mode) do
    case Map.keys(data) -- @layer_keys do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, mode} <- fetch_mode(data, default_mode),
             {:ok, granted} <- fetch_granted(data),
             {:ok, negotiable} <- fetch_list(data, "negotiable", :negotiable),
             {:ok, human} <- fetch_list(data, "human", :human),
             {:ok, deny} <- fetch_list(data, "deny", :deny) do
          {:ok,
           %Layer{mode: mode, granted: granted, negotiable: negotiable, human: human, deny: deny}}
        end
    end
  end

  defp fetch_mode(data, default) do
    case Map.fetch(data, "mode") do
      :error -> {:ok, default}
      {:ok, "deny"} -> {:ok, "allowlist"}
      {:ok, "allow"} -> {:ok, "blocklist"}
      {:ok, mode} when mode in ["allowlist", "blocklist", "auto"] -> {:ok, mode}
      {:ok, _other} -> {:error, {:invalid, :mode}}
    end
  end

  defp fetch_granted(data) do
    case {Map.fetch(data, "granted"), Map.fetch(data, "tools")} do
      {{:ok, _}, {:ok, _}} -> {:error, {:invalid, :granted}}
      {{:ok, list}, :error} -> validate_list(list, :granted)
      {:error, {:ok, list}} -> validate_list(list, :granted)
      {:error, :error} -> {:ok, []}
    end
  end

  defp fetch_list(data, key, tag) do
    case Map.fetch(data, key) do
      :error -> {:ok, []}
      {:ok, list} -> validate_list(list, tag)
    end
  end

  defp validate_list(list, tag) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, {:invalid, tag}}
  end

  defp validate_list(_list, tag), do: {:error, {:invalid, tag}}
end
