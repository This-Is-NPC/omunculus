defmodule Omunculus.Config do
  @moduledoc """
  Loads and validates a TOML config file. There is no package fallback:
  a missing file is `{:config, :missing, path}`. `load/1` and `grant/3`
  take the file path. The project root is the file's directory, or
  `[project] root` resolved against it. Parses the policy layer, the
  per-depth layers under `[policy.depth.N]`, the workspaces under
  `[workspaces.<name>]` — each a directory `root` (resolved against the
  project root) plus a ceiling layer — and the `[policy] workspace`
  default, each agent's ceiling layer, the named `[models.<name>]`
  adapters, the named workflows under `[workflows.<name>]` (spec §3.4),
  the MCP servers under `[[mcp.servers]]` (spec §8.7), the required
  `[execution]` table, and grants a permanent ceiling addition — to an
  agent, a depth, a workflow step, or a workspace — by rewriting that
  same file.
  """

  alias Omunculus.Config.Layer
  alias Omunculus.Tool.Manifest

  @enforce_keys [
    :root,
    :policy,
    :depths,
    :workspaces,
    :agents,
    :workflows,
    :policy_workflow,
    :policy_workspace,
    :depth_workflows,
    :mcp,
    :execution,
    :tools,
    :models
  ]
  defstruct @enforce_keys

  @type agent :: %{
          depth: non_neg_integer,
          text: String.t(),
          workflow_only: boolean,
          model: String.t(),
          ceiling: Layer.t()
        }
  @type model :: %{api: String.t(), module: module, input: map}
  @type step :: %{name: String.t(), agent: String.t(), ceiling: Layer.t()}
  @type workspace :: %{root: String.t(), ceiling: Layer.t()}
  @type mcp_server :: %{name: String.t(), command: [String.t()]}
  @type execution :: %{
          backend: String.t(),
          runtimes: [String.t()],
          environment: [String.t()],
          timeout_ms: pos_integer,
          max_output_bytes: pos_integer,
          max_concurrent: pos_integer,
          max_queue: pos_integer,
          queue_timeout_ms: pos_integer
        }

  @type t :: %__MODULE__{
          root: String.t(),
          policy: Layer.t(),
          depths: %{non_neg_integer => Layer.t()},
          workspaces: %{String.t() => workspace},
          agents: %{String.t() => agent},
          workflows: %{String.t() => [step]},
          policy_workflow: String.t() | nil,
          policy_workspace: String.t() | nil,
          depth_workflows: %{non_neg_integer => String.t()},
          mcp: [mcp_server],
          execution: execution,
          tools: tools,
          models: %{String.t() => model}
        }

  @type tools :: %{paths: [String.t()], inline: %{String.t() => Manifest.t()}}

  @layer_keys ~w(mode granted tools negotiable human deny)
  @execution_keys ~w(
    backend
    runtimes
    environment
    timeout_ms
    max_output_bytes
    max_concurrent
    max_queue
    queue_timeout_ms
  )
  @agent_extra_keys ~w(depth text workflow_only model)
  @openai_model_keys ~w(api url model timeout_ms temperature key_env headers)
  @module_model_keys ~w(api module params)
  @step_extra_keys ~w(name agent)

  @spec load(String.t()) :: {:ok, t} | {:error, term}
  def load(path) do
    with {:ok, data} <- read(path) do
      parse(data, path)
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

  @spec model_fun(t, String.t()) :: {:ok, fun} | {:error, term}
  def model_fun(%__MODULE__{agents: agents, models: models}, agent_name) do
    case Map.fetch(agents, agent_name) do
      {:ok, %{model: name}} ->
        spec = Map.fetch!(models, name)
        {:ok, spec.module.new(spec.input)}

      :error ->
        {:error, {:no_agent, agent_name}}
    end
  end

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
  def grant(path, layer, name) do
    with {:ok, data} <- read(path),
         {:ok, data} <- add_grant(data, layer, name) do
      File.write(path, Omunculus.Config.Toml.encode(data))
    end
  end

  defp read(path) do
    if File.regular?(path) do
      Toml.decode_file(path)
    else
      {:error, {:config, :missing, path}}
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

  defp parse(data, path) do
    case Map.keys(data) --
           [
             "policy",
             "workspaces",
             "agents",
             "workflows",
             "mcp",
             "execution",
             "project",
             "tools",
             "models"
           ] do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        config_dir = Path.dirname(Path.expand(path))

        with {:ok, root} <- parse_project(Map.get(data, "project"), config_dir),
             {:ok, execution} <- parse_execution(Map.get(data, "execution")),
             {:ok, models} <- parse_models(Map.get(data, "models")),
             {:ok, workspaces} <- parse_workspaces(Map.get(data, "workspaces", %{}), root),
             {:ok, agents} <- parse_agents(Map.get(data, "agents", %{}), models),
             {:ok, workflows} <- parse_workflows(Map.get(data, "workflows", %{}), agents),
             {:ok, policy, depths, policy_workflow, policy_workspace, depth_workflows} <-
               parse_policy(Map.get(data, "policy", %{}), workflows, workspaces),
             {:ok, mcp} <- parse_mcp(Map.get(data, "mcp", %{})),
             {:ok, tools} <- parse_tools(Map.get(data, "tools"), config_dir) do
          if map_size(agents) == 0 do
            {:error, :no_agents}
          else
            {:ok,
             %__MODULE__{
               root: root,
               policy: policy,
               depths: depths,
               workspaces: workspaces,
               agents: agents,
               workflows: workflows,
               policy_workflow: policy_workflow,
               policy_workspace: policy_workspace,
               depth_workflows: depth_workflows,
               mcp: mcp,
               execution: execution,
               tools: tools,
               models: models
             }}
          end
        end
    end
  end

  defp parse_project(nil, config_dir), do: {:ok, config_dir}

  defp parse_project(data, config_dir) when is_map(data) do
    case Map.keys(data) -- ["root"] do
      [key | _] ->
        {:error, {:project, {:unknown_key, key}}}

      [] ->
        case Map.fetch(data, "root") do
          :error ->
            {:ok, config_dir}

          {:ok, root} when is_binary(root) and root != "" ->
            {:ok, Path.expand(root, config_dir)}

          _ ->
            {:error, {:project, {:invalid, :root}}}
        end
    end
  end

  defp parse_project(_data, _config_dir), do: {:error, {:project, {:invalid, :table}}}

  defp parse_tools(nil, _config_dir), do: {:ok, %{paths: [], inline: %{}}}

  defp parse_tools(data, config_dir) when is_map(data) do
    {paths_raw, rest} = Map.pop(data, "paths", [])

    with {:ok, paths} <- parse_tool_paths(paths_raw, config_dir),
         {:ok, inline} <- parse_inline_tools(rest, config_dir) do
      {:ok, %{paths: paths, inline: inline}}
    end
  end

  defp parse_tools(_data, _config_dir), do: {:error, {:tools, {:invalid, :table}}}

  defp parse_tool_paths(paths, config_dir) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case expand_tool_path(path, config_dir) do
        {:ok, expanded} -> {:cont, {:ok, acc ++ [expanded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_tool_paths(_paths, _config_dir), do: {:error, {:tools, {:invalid, :paths}}}

  defp expand_tool_path("~" <> _rest = path, _config_dir) when path != "~" do
    {:ok, Path.expand(path)}
  end

  defp expand_tool_path(path, config_dir) when is_binary(path) and path != "" do
    {:ok, Path.expand(path, config_dir)}
  end

  defp expand_tool_path(_path, _config_dir), do: {:error, {:tools, {:invalid, :paths}}}

  defp parse_inline_tools(data, config_dir) do
    Enum.reduce_while(data, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case parse_inline_tool(name, value, config_dir) do
        {:ok, manifest} -> {:cont, {:ok, Map.put(acc, name, manifest)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_inline_tool("paths", _value, _config_dir),
    do: {:error, {:tools, {:invalid, :paths}}}

  defp parse_inline_tool(name, value, config_dir) when is_map(value) do
    raw =
      case Map.fetch(value, "name") do
        :error -> Map.put(value, "name", name)
        {:ok, ^name} -> value
        {:ok, _other} -> value
      end

    cond do
      Map.get(raw, "name") != name ->
        {:error, {:tools, name, {:invalid, :name}}}

      true ->
        case Manifest.parse(raw, config_dir) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, reason} -> {:error, {:tools, name, reason}}
        end
    end
  end

  defp parse_inline_tool(name, _value, _config_dir),
    do: {:error, {:tools, name, {:invalid, :table}}}

  defp parse_execution(nil), do: {:error, {:execution, :missing, @execution_keys}}

  defp parse_execution(data) when is_map(data) do
    case Map.keys(data) -- @execution_keys do
      [key | _] ->
        {:error, {:execution, {:unknown_key, key}}}

      [] ->
        with {:ok, backend} <- execution_backend(data),
             {:ok, runtimes} <- execution_runtimes(data),
             {:ok, environment} <- execution_environment(data),
             {:ok, timeout_ms} <- execution_positive_integer(data, "timeout_ms"),
             {:ok, max_output_bytes} <- execution_positive_integer(data, "max_output_bytes"),
             {:ok, max_concurrent} <- execution_positive_integer(data, "max_concurrent"),
             {:ok, max_queue} <- execution_positive_integer(data, "max_queue"),
             {:ok, queue_timeout_ms} <- execution_positive_integer(data, "queue_timeout_ms") do
          {:ok,
           %{
             backend: backend,
             runtimes: runtimes,
             environment: environment,
             timeout_ms: timeout_ms,
             max_output_bytes: max_output_bytes,
             max_concurrent: max_concurrent,
             max_queue: max_queue,
             queue_timeout_ms: queue_timeout_ms
           }}
        end
    end
  end

  defp parse_execution(_data), do: {:error, {:execution, {:invalid, :table}}}

  defp execution_backend(%{"backend" => "bubblewrap"}), do: {:ok, "bubblewrap"}
  defp execution_backend(_data), do: {:error, {:execution, {:invalid, :backend}}}

  defp execution_runtimes(%{"runtimes" => [_ | _] = runtimes}) do
    if Enum.all?(runtimes, &runtime_path?/1) and Enum.uniq(runtimes) == runtimes do
      {:ok, runtimes}
    else
      {:error, {:execution, {:invalid, :runtimes}}}
    end
  end

  defp execution_runtimes(_data), do: {:error, {:execution, {:invalid, :runtimes}}}

  defp runtime_path?(path), do: is_binary(path) and path != "" and Path.type(path) == :absolute

  defp execution_environment(%{"environment" => environment}) when is_list(environment) do
    if Enum.all?(environment, &environment_name?/1) and Enum.uniq(environment) == environment do
      {:ok, environment}
    else
      {:error, {:execution, {:invalid, :environment}}}
    end
  end

  defp execution_environment(_data), do: {:error, {:execution, {:invalid, :environment}}}

  defp environment_name?(name) when is_binary(name), do: name =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  defp environment_name?(_name), do: false

  defp execution_positive_integer(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:execution, {:invalid, String.to_existing_atom(key)}}}
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

  defp parse_models(nil), do: {:error, {:models, :missing}}

  defp parse_models(data) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case parse_model(name, spec) do
        {:ok, model} -> {:cont, {:ok, Map.put(acc, name, model)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_models(_data), do: {:error, {:models, :invalid}}

  defp parse_model(name, data) when is_map(data) do
    case Map.get(data, "api") do
      "openai-completions" -> parse_openai_model(name, data)
      "module" -> parse_module_model(name, data)
      nil -> {:error, {:models, name, {:invalid, :api}}}
      api -> {:error, {:models, name, {:unknown_api, api}}}
    end
  end

  defp parse_model(name, _data), do: {:error, {:models, name, {:invalid, :api}}}

  defp parse_openai_model(name, data) do
    case Map.keys(data) -- @openai_model_keys do
      [key | _] ->
        {:error, {:models, name, {:unknown_key, key}}}

      [] ->
        with {:ok, url} <- model_string(data, "url"),
             {:ok, model} <- model_string(data, "model"),
             {:ok, timeout_ms} <- model_timeout(data),
             {:ok, temperature} <- model_temperature(data),
             {:ok, key_env} <- model_optional_string(data, "key_env"),
             {:ok, headers} <- model_headers(data) do
          input =
            %{
              "api" => "openai-completions",
              "url" => url,
              "model" => model,
              "timeout_ms" => timeout_ms
            }
            |> maybe_put_model("temperature", temperature)
            |> maybe_put_model("key_env", key_env)
            |> maybe_put_model("headers", headers)

          {:ok,
           %{
             api: "openai-completions",
             module: Omunculus.Model.OpenAI,
             input: input
           }}
        else
          {:error, reason} -> {:error, {:models, name, reason}}
        end
    end
  end

  defp parse_module_model(name, data) do
    case Map.keys(data) -- @module_model_keys do
      [key | _] ->
        {:error, {:models, name, {:unknown_key, key}}}

      [] ->
        with {:ok, module_name} <- model_string(data, "module"),
             {:ok, params} <- model_params(data),
             {:ok, module} <- resolve_model_module(module_name) do
          {:ok,
           %{
             api: "module",
             module: module,
             input: %{"api" => "module", "module" => module_name, "params" => params}
           }}
        else
          {:error, reason} -> {:error, {:models, name, reason}}
        end
    end
  end

  defp model_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp model_timeout(%{"timeout_ms" => timeout}) when is_integer(timeout) and timeout > 0,
    do: {:ok, timeout}

  defp model_timeout(_data), do: {:error, {:invalid, :timeout_ms}}

  defp model_temperature(data) do
    case Map.fetch(data, "temperature") do
      :error -> {:ok, nil}
      {:ok, value} when is_number(value) -> {:ok, value}
      _ -> {:error, {:invalid, :temperature}}
    end
  end

  defp model_optional_string(data, key) do
    case Map.fetch(data, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp model_headers(data) do
    case Map.fetch(data, "headers") do
      :error ->
        {:ok, nil}

      {:ok, headers} when is_map(headers) ->
        if Enum.all?(headers, fn {key, value} -> is_binary(key) and is_binary(value) end) do
          {:ok, headers}
        else
          {:error, {:invalid, :headers}}
        end

      _ ->
        {:error, {:invalid, :headers}}
    end
  end

  defp model_params(data) do
    case Map.fetch(data, "params") do
      :error -> {:ok, %{}}
      {:ok, params} when is_map(params) -> {:ok, params}
      _ -> {:error, {:invalid, :params}}
    end
  end

  defp resolve_model_module(name) do
    module = Module.concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, :new, 1) do
      {:ok, module}
    else
      {:error, {:unknown_module, name}}
    end
  end

  defp maybe_put_model(map, _key, nil), do: map
  defp maybe_put_model(map, key, value), do: Map.put(map, key, value)

  defp parse_agents(agents, models) when is_map(agents) do
    Enum.reduce_while(agents, {:ok, %{}}, fn {name, data}, {:ok, acc} ->
      case parse_agent(name, data, models) do
        {:ok, agent} -> {:cont, {:ok, Map.put(acc, name, agent)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_agent(name, data, models) when is_map(data) do
    case Map.keys(data) -- (@agent_extra_keys ++ @layer_keys) do
      [key | _] ->
        {:error, {:agent, name, {:unknown_key, key}}}

      [] ->
        with {:ok, depth} <- fetch_depth(data),
             {:ok, text} <- fetch_text(data),
             {:ok, workflow_only} <- fetch_workflow_only(data),
             {:ok, model} <- fetch_model(data, models),
             {:ok, ceiling} <- parse_layer(Map.drop(data, @agent_extra_keys), nil) do
          {:ok,
           %{
             depth: depth,
             text: text,
             workflow_only: workflow_only,
             model: model,
             ceiling: ceiling
           }}
        else
          {:error, reason} -> {:error, {:agent, name, reason}}
        end
    end
  end

  defp parse_agent(name, _data, _models), do: {:error, {:agent, name, {:invalid, :depth}}}

  defp fetch_model(data, models) do
    case Map.fetch(data, "model") do
      {:ok, name} when is_binary(name) and name != "" ->
        if Map.has_key?(models, name), do: {:ok, name}, else: {:error, {:unknown_model, name}}

      _ ->
        {:error, {:invalid, :model}}
    end
  end

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
