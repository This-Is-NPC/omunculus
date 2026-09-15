defmodule Omunculus.Config do
  @moduledoc """
  Loads and validates `omunculus.toml`: a project file replaces the
  package default whole, never merges with it (spec §5). Parses the
  policy layer, the per-depth layers under `[policy.depth.N]`, the
  workspace layers, each agent's ceiling layer, and the named
  workflows under `[workflows.<name>]` (spec §3.4), and grants a
  permanent ceiling addition by rewriting the TOML file.
  """

  alias Omunculus.Config.Layer

  @enforce_keys [
    :policy,
    :depths,
    :workspaces,
    :agents,
    :workflows,
    :policy_workflow,
    :depth_workflows
  ]
  defstruct @enforce_keys

  @type agent :: %{depth: non_neg_integer, text: String.t(), ceiling: Layer.t()}
  @type step :: %{name: String.t(), agent: String.t(), ceiling: Layer.t()}
  @type t :: %__MODULE__{
          policy: Layer.t(),
          depths: %{non_neg_integer => Layer.t()},
          workspaces: %{String.t() => Layer.t()},
          agents: %{String.t() => agent},
          workflows: %{String.t() => [step]},
          policy_workflow: String.t() | nil,
          depth_workflows: %{non_neg_integer => String.t()}
        }

  @layer_keys ~w(mode granted tools negotiable human deny)
  @agent_extra_keys ~w(depth text)
  @step_extra_keys ~w(name agent)

  @spec load(String.t()) :: {:ok, t} | {:error, term}
  def load(project_dir) do
    with {:ok, data} <- Toml.decode_file(config_path(project_dir)) do
      parse(data)
    end
  end

  @spec agent_at_depth(t, non_neg_integer) ::
          {:ok, {String.t(), agent}} | {:error, {:no_agent_at_depth, non_neg_integer}}
  def agent_at_depth(%__MODULE__{agents: agents}, depth) do
    agents
    |> Enum.sort_by(fn {name, _agent} -> name end)
    |> Enum.find(fn {_name, agent} -> agent.depth == depth end)
    |> case do
      nil -> {:error, {:no_agent_at_depth, depth}}
      {name, agent} -> {:ok, {name, agent}}
    end
  end

  @spec workflow_for(t, non_neg_integer) :: {:ok, [step]} | :off
  def workflow_for(%__MODULE__{} = config, depth) do
    with name when is_binary(name) <-
           Map.get(config.depth_workflows, depth) || config.policy_workflow,
         {:ok, steps} <- Map.fetch(config.workflows, name) do
      {:ok, steps}
    else
      _ -> :off
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

  @spec grant(String.t(), {:agent, String.t()} | {:depth, non_neg_integer}, String.t()) ::
          :ok | {:error, term}
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

  defp keys(path), do: Enum.map(path, &Access.key(&1, %{}))

  defp add_name(layer, name) do
    if is_list(layer["tools"]) do
      Map.put(layer, "tools", add_unique(layer["tools"], name))
    else
      Map.put(layer, "granted", add_unique(Map.get(layer, "granted", []), name))
    end
  end

  defp add_unique(list, name) do
    if name in list, do: list, else: list ++ [name]
  end

  defp parse(data) do
    case Map.keys(data) -- ["policy", "workspaces", "agents", "workflows"] do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, workspaces} <- parse_workspaces(Map.get(data, "workspaces", %{})),
             {:ok, agents} <- parse_agents(Map.get(data, "agents", %{})),
             {:ok, workflows} <- parse_workflows(Map.get(data, "workflows", %{}), agents),
             {:ok, policy, depths, policy_workflow, depth_workflows} <-
               parse_policy(Map.get(data, "policy", %{}), workflows) do
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
               depth_workflows: depth_workflows
             }}
          end
        end
    end
  end

  defp parse_policy(data, workflows) when is_map(data) do
    depth_data = Map.get(data, "depth", %{})
    workflow_data = Map.get(data, "workflow")
    layer_data = data |> Map.delete("depth") |> Map.delete("workflow")

    case Map.keys(layer_data) -- @layer_keys do
      [key | _] ->
        {:error, {:policy, {:unknown_key, key}}}

      [] ->
        with {:ok, policy} <- tag_error(parse_layer(layer_data, "auto"), :policy),
             {:ok, policy_workflow} <-
               tag_error(fetch_workflow(workflow_data, workflows), :policy),
             {:ok, depths, depth_workflows} <- parse_depths(depth_data, workflows) do
          {:ok, policy, depths, policy_workflow, depth_workflows}
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

  defp parse_workspaces(data) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case parse_layer(value, nil) do
        {:ok, layer} -> {:cont, {:ok, Map.put(acc, name, layer)}}
        {:error, reason} -> {:halt, {:error, {:workspace, name, reason}}}
      end
    end)
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
             {:ok, ceiling} <- parse_layer(Map.drop(data, @agent_extra_keys), nil) do
          {:ok, %{depth: depth, text: text, ceiling: ceiling}}
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
