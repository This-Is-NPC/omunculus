defmodule Omunculus.Config do
  @moduledoc """
  Loads and validates a TOML config file. There is no package fallback:
  a missing file is `{:config, :missing, path}`. `load/1` and `grant/3`
  take the file path. The project root is the file's directory, or
  `[project] root` resolved against it. Parses the policy layer, the
  per-depth layers under `[policy.depth.N]`, the workspaces under
  `[workspaces.<name>]` — each a directory `root` (resolved against the
  project root) plus a ceiling layer — the `[policy] workspace`
  default, the required `[policy] max_retries`, the optional `[policy]
  last_run_output_bytes` and `tool_output_bytes`, the optional `[policy]
  conversation_bytes` (how much of its conversation's works and exchanges
  a run without a work is shown), the optional `[policy]
  send_catalog` (send every run the catalog's model tools, not only its
  own, so all agents share the start of their requests), the optional
  `[policy] session_ttl_ms` and `session_max_bytes` (together, they let a
  run continue its agent's paused session on the work), each agent's ceiling layer, the named `[models.<name>]`
  adapters, the named workflows under `[workflows.<name>]` (spec §3.4),
  the MCP servers under `[[mcp.servers]]` (spec §8.7), the `[auth]`
  providers (spec §11.1), the `[secrets.<tool>]` binding each secret a
  tool's process receives to one of those providers, the required `[execution]` and `[store]`
  tables. Every ceiling layer, and a workflow, may carry per-tool
  `overrides` (`Omunculus.Tool.Overrides`); a workflow's fold into each
  of its steps beneath the step's own. It also grants a permanent ceiling
  addition — to an agent, a depth, a workflow step, or a workspace — by
  rewriting that same file, and `edit/5` writes one item a client edits
  (`document/1`) the same way. A workspace may name a `config` file relative
  to its `root`; that file uses the same schema minus `[workspaces]` and
  `[store]`, and its tables overlay the global config after any inline
  `[workspaces.<name>]` tables.
  """

  alias Omunculus.Auth
  alias Omunculus.Config.{Layer, Packs}
  alias Omunculus.Tool.{Manifest, Overrides}

  @enforce_keys [
    :root,
    :policy,
    :depths,
    :workspaces,
    :agents,
    :workflows,
    :assemble,
    :max_retries,
    :last_run_output_bytes,
    :tool_output_bytes,
    :conversation_bytes,
    :send_catalog,
    :session_ttl_ms,
    :session_max_bytes,
    :policy_workflow,
    :policy_workspace,
    :depth_workflows,
    :mcp,
    :execution,
    :tools,
    :models,
    :path,
    :store,
    :auth,
    :access,
    :secrets,
    :data
  ]
  defstruct @enforce_keys

  @type agent :: %{
          depth: non_neg_integer,
          text: String.t(),
          workflow_only: boolean,
          model: String.t(),
          assemble: String.t() | nil,
          ceiling: Layer.t()
        }
  @type model :: %{api: String.t(), module: module, input: map}
  @type step :: %{name: String.t(), agent: String.t(), ceiling: Layer.t()}
  @type workspace :: %{
          root: String.t(),
          config: String.t() | nil,
          ceiling: Layer.t(),
          overlay: map,
          resolved: t() | nil
        }
  @type mcp_server :: %{
          name: String.t(),
          command: [String.t()],
          protocol_version: String.t(),
          secrets: %{String.t() => String.t()}
        }
  @type sandbox :: %{
          script: String.t(),
          command: [String.t()],
          runner: String.t(),
          exec: String.t()
        }
  @type execution :: %{
          backend: String.t(),
          runtimes: [String.t()],
          environment: [String.t()],
          timeout_ms: pos_integer,
          max_output_bytes: pos_integer,
          max_concurrent: pos_integer,
          max_queue: pos_integer,
          queue_timeout_ms: pos_integer,
          resources: [String.t()],
          host: boolean,
          deny_read: [String.t()],
          write: [String.t()],
          sandbox: sandbox
        }

  @type t :: %__MODULE__{
          root: String.t(),
          policy: Layer.t(),
          depths: %{non_neg_integer => Layer.t()},
          workspaces: %{String.t() => workspace},
          agents: %{String.t() => agent},
          workflows: %{String.t() => [step]},
          assemble: String.t() | nil,
          max_retries: non_neg_integer,
          last_run_output_bytes: pos_integer | nil,
          tool_output_bytes: pos_integer | nil,
          conversation_bytes: pos_integer | nil,
          send_catalog: boolean,
          session_ttl_ms: pos_integer | nil,
          session_max_bytes: pos_integer | nil,
          policy_workflow: String.t() | nil,
          policy_workspace: String.t() | nil,
          depth_workflows: %{non_neg_integer => String.t()},
          mcp: [mcp_server],
          execution: execution,
          tools: tools,
          models: %{String.t() => model},
          path: String.t(),
          store: %{path: String.t(), changes: String.t() | nil},
          auth: %{store: String.t() | nil, providers: %{String.t() => map}},
          access: map | nil,
          secrets: %{String.t() => %{String.t() => String.t()}},
          data: map
        }

  @type tools :: %{
          paths: [String.t()],
          inline: %{String.t() => Manifest.t()},
          skills: [String.t()]
        }

  @layer_keys ~w(mode granted tools negotiable human deny pinned overrides)
  @execution_keys ~w(
    backend
    runtimes
    environment
    timeout_ms
    max_output_bytes
    max_concurrent
    max_queue
    queue_timeout_ms
    resources
  )
  @execution_optional_keys ~w(host deny_read write)
  @known_execution_resources ~w(sandbox.write sandbox.network)
  @sandbox_keys ~w(script command runner exec)
  @mcp_server_keys ~w(name command protocol_version secrets)
  @workspace_overlay_keys ~w(execution models agents workflows tools policy mcp auth)
  @workspace_file_keys ~w(policy agents workflows mcp execution project tools models auth)
  @policy_extra_keys ~w(depth workflow workspace assemble max_retries last_run_output_bytes tool_output_bytes conversation_bytes send_catalog session_ttl_ms session_max_bytes)
  @agent_extra_keys ~w(depth text workflow_only model assemble)
  @http_model_keys ~w(api url model timeout_ms temperature headers body provider stream retries code_mode)
  @openai_model_keys @http_model_keys ++ ~w(prompt_cache_key)
  @module_model_keys ~w(api module params)
  @command_model_keys ~w(api command model provider params)
  @step_extra_keys ~w(name agent)
  # What a client edits, item by item; the process's own tables (project,
  # execution, store, tools, mcp) and `[auth] store` stay in the file alone.
  @named_items ~w(agents models workflows workspaces auth secrets)
  @single_items ~w(policy access)

  @spec load(String.t()) :: {:ok, t} | {:error, term}
  def load(path) do
    with {:ok, data} <- read(path) do
      parse(data, path, true)
    end
  end

  @doc "The sandbox capabilities `[execution] resources` may name."
  @spec known_resources() :: [String.t()]
  def known_resources, do: @known_execution_resources

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

  @spec for_workspace(t, String.t() | nil) :: {:ok, t} | {:error, term}
  def for_workspace(%__MODULE__{} = config, nil), do: {:ok, config}

  def for_workspace(%__MODULE__{} = config, name) when is_binary(name) do
    case Map.fetch(config.workspaces, name) do
      :error ->
        {:error, {:workspace, name, :unknown}}

      {:ok, %{resolved: resolved}} when not is_nil(resolved) ->
        {:ok, resolved}

      {:ok, _} ->
        {:error, {:workspace, name, :unresolved}}
    end
  end

  @spec model_fun(t, String.t()) :: {:ok, fun} | {:error, term}
  def model_fun(%__MODULE__{} = config, agent_name) do
    case Map.fetch(config.agents, agent_name) do
      {:ok, %{model: name}} -> model(config, name)
      :error -> {:error, {:no_agent, agent_name}}
    end
  end

  @doc "The adapter fun of the model `name`, with its provider's credential."
  @spec model(t, String.t()) :: {:ok, fun} | {:error, term}
  def model(%__MODULE__{} = config, name) do
    spec = Map.fetch!(config.models, name)
    input = spec.input

    case Map.get(input, "provider") do
      nil ->
        {:ok, spec.module.new(input)}

      provider_id ->
        case Auth.credential(config, provider_id) do
          {:ok, nil} -> {:ok, spec.module.new(input)}
          {:ok, credential} -> {:ok, spec.module.new(Map.put(input, "credential", credential))}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec agents_at_depth(t, non_neg_integer) :: [{String.t(), agent}]
  def agents_at_depth(%__MODULE__{agents: agents}, depth) do
    agents
    |> Enum.filter(fn {_name, agent} -> agent.depth == depth and not agent.workflow_only end)
    |> Enum.sort_by(fn {name, _agent} -> name end)
  end

  @doc "The agent of `depth` when it is the only one there; with several, one must be named."
  @spec agent_at_depth(t, non_neg_integer) ::
          {:ok, {String.t(), agent}}
          | {:error, {:no_agent_at_depth, non_neg_integer}}
          | {:error, {:agent_required, non_neg_integer, [String.t()]}}
  def agent_at_depth(%__MODULE__{} = config, depth) do
    case agents_at_depth(config, depth) do
      [] -> {:error, {:no_agent_at_depth, depth}}
      [only] -> {:ok, only}
      several -> {:error, {:agent_required, depth, Enum.map(several, &elem(&1, 0))}}
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

  @doc """
  Adds `name` to a layer of the TOML at `path`. Grants to one file apply
  one after another, and the file is replaced whole, so a concurrent
  `load/1` reads it before or after a grant, never halfway.
  """
  @spec grant(String.t(), grant_layer, String.t()) :: :ok | {:error, term}
  def grant(path, layer, name) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, data} <- read(path) do
        case add_grant(data, path, layer, name) do
          {:ok, {:workspace_file, workspace_path, workspace_data}} ->
            replace(workspace_path, workspace_data)

          {:ok, data} ->
            replace(path, data)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  @doc """
  Writes `entry` — a pack's `path`, with its `models` and `auth` maps — to
  the `[[packs]]` of the TOML at `path`, in place of an entry for the same
  folder, when the config then loads.
  """
  @spec import_pack(String.t(), map) :: {:ok, t} | {:error, term}
  def import_pack(path, entry) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, data} <- read(path),
           {:ok, data, config} <- with_pack(data, path, entry),
           :ok <- replace(path, data) do
        {:ok, config}
      end
    end)
  end

  @doc "The config the TOML at `path` loads as once `entry` is imported, as `import_pack/2` would write it; the file stays as it is."
  @spec try_pack(String.t(), map) :: {:ok, t} | {:error, term}
  def try_pack(path, entry) do
    with {:ok, data} <- read(path),
         {:ok, _data, config} <- with_pack(data, path, entry),
         do: {:ok, config}
  end

  defp with_pack(data, path, %{"path" => folder} = entry) do
    dir = Path.dirname(Path.expand(path))
    same = &(Path.expand(&1["path"] || "", dir) == Path.expand(folder, dir))
    data = Map.put(data, "packs", Enum.reject(Map.get(data, "packs", []), same) ++ [entry])

    with {:ok, config} <- parse(data, path, true), do: {:ok, data, config}
  end

  defp replace(path, data) do
    temporary = "#{path}.#{Omunculus.Id.new()}"

    with :ok <- File.write(temporary, Omunculus.Config.Toml.encode(data)) do
      File.rename(temporary, path)
    end
  end

  @doc "The item `<section>.<name>`, or `policy` / `access`, as `edit/5` takes it."
  @spec item(String.t()) :: tuple
  def item(item) do
    case String.split(item, ".", parts: 2) do
      [section, name] -> {section, name}
      [section] -> {section}
    end
  end

  @doc """
  What a client edits of the TOML at `path`: `document`, its `agents`,
  `models`, `workflows`, `workspaces`, `auth` providers and tool
  `secrets` by name and its `policy` and `access` tables, as the file writes them but for the
  key a provider writes literally, which stays in the file and is named in
  `literal_keys`; and `revision`, the SHA-256 of the file's bytes, in hex.
  """
  @spec document(String.t()) ::
          {:ok, %{document: map, literal_keys: [String.t()], revision: String.t()}}
          | {:error, term}
  def document(path) do
    with {:ok, text} <- read_text(path),
         {:ok, data} <- Toml.decode(text) do
      providers = data |> Map.get("auth", %{}) |> Map.drop(["store"])
      literal = for {name, provider} <- providers, literal_key?(provider), do: name

      document =
        data
        |> Map.take(@named_items ++ @single_items)
        |> Map.put(
          "auth",
          Map.new(providers, fn {name, provider} -> {name, unkeyed(provider, name in literal)} end)
        )

      {:ok, %{document: document, literal_keys: Enum.sort(literal), revision: revision(text)}}
    end
  end

  @doc """
  Writes one item of the TOML at `path` — `{section, name}` of the named
  sections `document/1` reads, or `{section}` for `policy` and `access` —
  as `value`, or removes it for nil, while the file is still at `revision`
  and the result loads; the rest of the file keeps what it holds. With
  `from`, the item under that name in the same section is removed in the
  same write: a rename. An `auth` provider written without a key keeps
  the literal key the file holds for it. Edits and grants to one file
  apply one after another.
  """
  @spec edit(String.t(), String.t(), tuple, map | nil, String.t() | nil) :: :ok | {:error, term}
  def edit(path, revision, item, value, from \\ nil) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, text} <- read_text(path),
           :ok <- current(text, revision),
           {:ok, data, _config} <- with_item(text, path, item, value, from) do
        replace(path, data)
      end
    end)
  end

  @doc """
  The config the TOML at `path` loads as once one item is `value`, as
  `edit/5` would write it; the file stays as it is.
  """
  @spec try_item(String.t(), tuple, map | nil) :: {:ok, t} | {:error, term}
  def try_item(path, item, value) do
    with {:ok, text} <- read_text(path),
         {:ok, _data, config} <- with_item(text, path, item, value, nil) do
      {:ok, config}
    end
  end

  defp with_item(text, path, item, value, from) do
    with {:ok, keys} <- item_keys(item, from),
         :ok <- editable(value),
         {:ok, data} <- Toml.decode(text),
         data = put_item(data, keys, value, from),
         {:ok, config} <- parse(data, path, true) do
      {:ok, data, config}
    end
  end

  defp current(text, revision) do
    if revision(text) == revision, do: :ok, else: {:error, {:config, :stale}}
  end

  defp revision(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp item_keys({section, name}, from)
       when section in @named_items and is_binary(name) and name != "" and
              (is_nil(from) or (is_binary(from) and from != "")) do
    if section == "auth" and "store" in [name, from],
      do: {:error, {:config, :invalid_item}},
      else: {:ok, [section, name]}
  end

  defp item_keys({section}, nil) when section in @single_items, do: {:ok, [section]}
  defp item_keys(_item, _from), do: {:error, {:config, :invalid_item}}

  defp editable(nil), do: :ok

  defp editable(value) when is_map(value) do
    if toml?(value), do: :ok, else: {:error, {:config, :invalid_item}}
  end

  defp editable(_value), do: {:error, {:config, :invalid_item}}

  defp put_item(data, [section], nil, nil), do: Map.delete(data, section)
  defp put_item(data, [section], value, nil), do: Map.put(data, section, value)

  defp put_item(data, [section, name], value, from) do
    table = Map.get(data, section, %{})
    held = Map.get(table, from || name)
    table = Map.drop(table, Enum.reject([from], &is_nil/1))

    table =
      cond do
        is_nil(value) -> Map.delete(table, name)
        section == "auth" -> Map.put(table, name, keyed(value, held))
        true -> Map.put(table, name, value)
      end

    Map.put(data, section, table)
  end

  # A literal key is the secret itself; `$VAR` and `!cmd` only say where it is.
  defp literal_key?(%{"key" => key}) when is_binary(key),
    do: key != "" and not String.starts_with?(key, ["$", "!"])

  defp literal_key?(_provider), do: false

  defp unkeyed(provider, true), do: Map.delete(provider, "key")
  defp unkeyed(provider, false), do: provider

  defp keyed(value, held) do
    if not Map.has_key?(value, "key") and is_map(held) and literal_key?(held),
      do: Map.put(value, "key", held["key"]),
      else: value
  end

  # TOML has no null: every value is a string, number, boolean, array or table.
  defp toml?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp toml?(value) when is_list(value), do: Enum.all?(value, &toml?/1)

  defp toml?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and toml?(item) end)

  defp toml?(_value), do: false

  defp read(path) do
    with {:ok, text} <- read_text(path), do: Toml.decode(text)
  end

  defp read_text(path) do
    if File.regular?(path) do
      File.read(path)
    else
      {:error, {:config, :missing, path}}
    end
  end

  defp add_grant(data, _path, {:agent, agent_name}, name) do
    agents = Map.get(data, "agents", %{})

    case Map.fetch(agents, agent_name) do
      :error -> {:error, {:agent, agent_name, :unknown}}
      {:ok, agent} -> {:ok, put_in(data, keys(["agents", agent_name]), add_name(agent, name))}
    end
  end

  defp add_grant(data, _path, {:depth, n}, name) do
    path = keys(["policy", "depth", Integer.to_string(n)])
    {:ok, put_in(data, path, add_name(get_in(data, path), name))}
  end

  defp add_grant(data, config_path, {:workspace, workspace_name}, name) do
    workspaces = Map.get(data, "workspaces", %{})

    case Map.fetch(workspaces, workspace_name) do
      :error ->
        {:error, {:workspace, workspace_name, :unknown}}

      {:ok, workspace} ->
        case Map.get(workspace, "config") do
          config when is_binary(config) and config != "" ->
            grant_workspace_file(data, config_path, workspace_name, workspace, name)

          _ ->
            path = keys(["workspaces", workspace_name])
            {:ok, put_in(data, path, add_name(workspace, name))}
        end
    end
  end

  defp add_grant(data, _path, {:stage, workflow_name, stage}, name) do
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

  defp parse(data, path, validate_overlays?) do
    with {:ok, data} <- Packs.expand(data, Path.dirname(Path.expand(path))),
         do: parse_expanded(data, path, validate_overlays?)
  end

  defp parse_expanded(data, path, validate_overlays?) do
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
             "models",
             "store",
             "auth",
             "access",
             "secrets",
             "skills"
           ] do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        config_path = Path.expand(path)
        config_dir = Path.dirname(config_path)

        with {:ok, root} <- parse_project(Map.get(data, "project"), config_dir),
             {:ok, execution} <- parse_execution(Map.get(data, "execution"), config_dir),
             {:ok, auth} <- parse_auth(Map.get(data, "auth"), config_dir),
             {:ok, access} <- parse_access(Map.get(data, "access")),
             {:ok, models} <- parse_models(Map.get(data, "models"), auth, config_dir),
             {:ok, store} <- parse_store(Map.get(data, "store"), config_dir),
             {:ok, workspaces} <- parse_workspaces(Map.get(data, "workspaces", %{}), root),
             {:ok, agents} <- parse_agents(Map.get(data, "agents", %{}), models),
             {:ok, workflows} <- parse_workflows(Map.get(data, "workflows", %{}), agents),
             {:ok, policy, depths, policy_workflow, policy_workspace, depth_workflows, assemble,
              max_retries, last_run_output_bytes, tool_output_bytes, conversation_bytes,
              send_catalog,
              session} <-
               parse_policy(Map.get(data, "policy", %{}), workflows, workspaces),
             {:ok, mcp} <- parse_mcp(Map.get(data, "mcp", %{}), auth),
             {:ok, secrets} <- parse_secrets(Map.get(data, "secrets", %{}), auth),
             {:ok, tools} <- parse_tools(Map.get(data, "tools"), config_dir),
             {:ok, skills} <- parse_skills(Map.get(data, "skills"), config_dir) do
          tools = Map.put(tools, :skills, skills)

          if map_size(agents) == 0 do
            {:error, :no_agents}
          else
            config = %__MODULE__{
              root: root,
              policy: policy,
              depths: depths,
              workspaces: workspaces,
              agents: agents,
              workflows: workflows,
              assemble: assemble,
              max_retries: max_retries,
              last_run_output_bytes: last_run_output_bytes,
              tool_output_bytes: tool_output_bytes,
              conversation_bytes: conversation_bytes,
              send_catalog: send_catalog,
              session_ttl_ms: session.ttl_ms,
              session_max_bytes: session.max_bytes,
              policy_workflow: policy_workflow,
              policy_workspace: policy_workspace,
              depth_workflows: depth_workflows,
              mcp: mcp,
              execution: execution,
              tools: tools,
              models: models,
              path: config_path,
              store: store,
              auth: auth,
              access: access,
              secrets: secrets,
              data: data
            }

            if validate_overlays?,
              do: resolve_all_workspaces(config),
              else: {:ok, config}
          end
        end
    end
  end

  @capabilities ~w(
    project.manage_access project.manage_config conversation.create
    conversation.read conversation.send conversation.comment
    conversation.reply conversation.manage_access conversation.manage
  )

  defp parse_access(nil), do: {:ok, nil}

  defp parse_access(
         %{"creator_role" => creator, "bootstrap_role" => bootstrap, "roles" => roles} = data
       )
       when is_binary(creator) and is_binary(bootstrap) and is_map(roles) do
    with [] <- Map.keys(data) -- ~w(creator_role bootstrap_role roles),
         true <- map_size(roles) > 0,
         true <- Map.has_key?(roles, creator) and Map.has_key?(roles, bootstrap),
         {:ok, parsed} <- parse_access_roles(roles),
         true <- "conversation.manage_access" in parsed[creator].capabilities,
         true <- "project.manage_access" in parsed[bootstrap].capabilities,
         true <- "project.manage_config" in parsed[bootstrap].capabilities do
      {:ok, %{creator_role: creator, bootstrap_role: bootstrap, roles: parsed}}
    else
      _ -> {:error, {:access, :invalid}}
    end
  end

  defp parse_access(_), do: {:error, {:access, :invalid}}

  defp parse_access_roles(roles) do
    Enum.reduce_while(roles, {:ok, %{}}, fn {name, role}, {:ok, acc} ->
      case role do
        %{"scope" => scope, "capabilities" => caps} = data
        when scope in ~w(project conversation) and is_list(caps) ->
          if Map.keys(data) -- ~w(scope capabilities) == [] and
               Enum.all?(caps, &(&1 in @capabilities)) and
               (scope == "project" or
                  Enum.all?(caps, &String.starts_with?(&1, "conversation."))) do
            {:cont, {:ok, Map.put(acc, name, %{scope: scope, capabilities: caps})}}
          else
            {:halt, {:error, {:access, :invalid_role, name}}}
          end

        _ ->
          {:halt, {:error, {:access, :invalid_role, name}}}
      end
    end)
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

  defp parse_store(nil, _config_dir), do: {:error, {:store, :missing}}

  defp parse_store(data, config_dir) when is_map(data) do
    case Map.keys(data) -- ["path", "changes"] do
      [key | _] ->
        {:error, {:store, {:unknown_key, key}}}

      [] ->
        with {:ok, path} <- store_path(data, "path", config_dir),
             {:ok, changes} <- store_path(data, "changes", config_dir) do
          if is_nil(path),
            do: {:error, {:store, {:invalid, :path}}},
            else: {:ok, %{path: path, changes: changes}}
        end
    end
  end

  defp parse_store(_data, _config_dir), do: {:error, {:store, {:invalid, :table}}}

  # `changes`, optional, is where the files each call changed are kept.
  defp store_path(data, key, config_dir) do
    case Map.fetch(data, key) do
      {:ok, path} when is_binary(path) and path != "" ->
        {:ok, expand_store_path(path, config_dir)}

      :error ->
        {:ok, nil}

      _invalid ->
        {:error, {:store, {:invalid, String.to_atom(key)}}}
    end
  end

  defp expand_store_path("~" <> _rest = path, _config_dir) when path != "~",
    do: Path.expand(path)

  defp expand_store_path(path, config_dir), do: Path.expand(path, config_dir)

  defp parse_tools(nil, _config_dir), do: {:ok, %{paths: [], inline: %{}}}

  defp parse_tools(data, config_dir) when is_map(data) do
    {paths_raw, rest} = Map.pop(data, "paths", [])

    with {:ok, paths} <- parse_tool_paths(paths_raw, config_dir),
         {:ok, inline} <- parse_inline_tools(rest, config_dir) do
      {:ok, %{paths: paths, inline: inline}}
    end
  end

  defp parse_tools(_data, _config_dir), do: {:error, {:tools, {:invalid, :table}}}

  defp parse_tool_paths(paths, config_dir) do
    case expand_paths(paths, config_dir) do
      {:ok, expanded} -> {:ok, expanded}
      :error -> {:error, {:tools, {:invalid, :paths}}}
    end
  end

  # `[skills] paths`: folders of Agent Skills, as `[tools] paths` are of tools.
  defp parse_skills(nil, _config_dir), do: {:ok, []}

  defp parse_skills(data, config_dir) when is_map(data) do
    with [] <- Map.keys(data) -- ["paths"],
         {:ok, paths} <- expand_paths(Map.get(data, "paths", []), config_dir) do
      {:ok, paths}
    else
      [key | _] -> {:error, {:skills, {:unknown_key, key}}}
      :error -> {:error, {:skills, {:invalid, :paths}}}
    end
  end

  defp parse_skills(_data, _config_dir), do: {:error, {:skills, {:invalid, :table}}}

  # Each path relative to the config file's directory, `~` to the home.
  defp expand_paths(paths, config_dir) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case expand_path(path, config_dir) do
        {:ok, expanded} -> {:cont, {:ok, acc ++ [expanded]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp expand_paths(_paths, _config_dir), do: :error

  defp expand_path("~" <> _rest = path, _config_dir) when path != "~",
    do: {:ok, Path.expand(path)}

  defp expand_path(path, config_dir) when is_binary(path) and path != "",
    do: {:ok, Path.expand(path, config_dir)}

  defp expand_path(_path, _config_dir), do: :error

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

  defp parse_execution(nil, _config_dir), do: {:error, {:execution, :missing, @execution_keys}}

  defp parse_execution(data, config_dir) when is_map(data) do
    {sandbox_data, rest} = Map.pop(data, "sandbox")

    case Map.keys(rest) -- (@execution_keys ++ @execution_optional_keys) do
      [key | _] ->
        {:error, {:execution, {:unknown_key, key}}}

      [] ->
        with {:ok, backend} <- execution_backend(rest),
             {:ok, runtimes} <- execution_runtimes(rest),
             {:ok, environment} <- execution_environment(rest),
             {:ok, timeout_ms} <- execution_positive_integer(rest, "timeout_ms"),
             {:ok, max_output_bytes} <- execution_positive_integer(rest, "max_output_bytes"),
             {:ok, max_concurrent} <- execution_positive_integer(rest, "max_concurrent"),
             {:ok, max_queue} <- execution_positive_integer(rest, "max_queue"),
             {:ok, queue_timeout_ms} <- execution_positive_integer(rest, "queue_timeout_ms"),
             {:ok, resources} <- execution_resources(rest),
             {:ok, host} <- execution_host(rest),
             {:ok, deny_read} <- execution_paths(rest, "deny_read"),
             {:ok, write} <- execution_paths(rest, "write"),
             {:ok, sandbox} <- parse_sandbox(sandbox_data, config_dir) do
          {:ok,
           %{
             backend: backend,
             runtimes: runtimes,
             environment: environment,
             timeout_ms: timeout_ms,
             max_output_bytes: max_output_bytes,
             max_concurrent: max_concurrent,
             max_queue: max_queue,
             queue_timeout_ms: queue_timeout_ms,
             resources: resources,
             host: host,
             deny_read: deny_read,
             write: write,
             sandbox: sandbox
           }}
        end
    end
  end

  defp parse_execution(_data, _config_dir), do: {:error, {:execution, {:invalid, :table}}}

  defp parse_sandbox(nil, _config_dir), do: {:error, {:execution, {:sandbox, :missing}}}

  defp parse_sandbox(data, config_dir) when is_map(data) do
    case Map.keys(data) -- @sandbox_keys do
      [key | _] ->
        {:error, {:execution, {:sandbox, {:unknown_key, key}}}}

      [] ->
        with {:ok, script} <- sandbox_script(data, config_dir),
             {:ok, command} <- sandbox_command(data),
             {:ok, runner} <- sandbox_string(data, "runner"),
             {:ok, exec} <- sandbox_string(data, "exec") do
          {:ok, %{script: script, command: command, runner: runner, exec: exec}}
        end
    end
  end

  defp parse_sandbox(_data, _config_dir),
    do: {:error, {:execution, {:sandbox, {:invalid, :table}}}}

  defp sandbox_script(%{"script" => script}, config_dir)
       when is_binary(script) and script != "" do
    {:ok, expand_sandbox_script(script, config_dir)}
  end

  defp sandbox_script(_data, _config_dir),
    do: {:error, {:execution, {:sandbox, {:invalid, :script}}}}

  defp expand_sandbox_script("~" <> _rest = path, _config_dir) when path != "~",
    do: Path.expand(path)

  defp expand_sandbox_script(path, config_dir), do: Path.expand(path, config_dir)

  defp sandbox_command(%{"command" => [_ | _] = command}) do
    if Enum.all?(command, &(is_binary(&1) and &1 != "")) do
      {:ok, command}
    else
      {:error, {:execution, {:sandbox, {:invalid, :command}}}}
    end
  end

  defp sandbox_command(_data), do: {:error, {:execution, {:sandbox, {:invalid, :command}}}}

  defp sandbox_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, {:execution, {:sandbox, {:invalid, String.to_existing_atom(key)}}}}
    end
  end

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

  # `host`, optional, shows the machine to a command, read-only, as the
  # person sees it; without it a command sees only the runtimes.
  defp execution_host(data) do
    case Map.get(data, "host", false) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, {:execution, {:invalid, :host}}}
    end
  end

  # Paths a command may not read (`deny_read`) or may also write (`write`),
  # absolute or under `~`.
  defp execution_paths(data, key) do
    paths = Map.get(data, key, [])

    if is_list(paths) and Enum.all?(paths, &host_path?/1),
      do: {:ok, Enum.map(paths, &Path.expand/1)},
      else: {:error, {:execution, {:invalid, String.to_atom(key)}}}
  end

  defp host_path?("~/" <> rest), do: rest != ""
  defp host_path?(path), do: is_binary(path) and Path.type(path) == :absolute

  defp execution_resources(%{"resources" => resources}) when is_list(resources) do
    cond do
      not Enum.all?(resources, &(is_binary(&1) and &1 != "")) ->
        {:error, {:execution, {:invalid, :resources}}}

      Enum.uniq(resources) != resources ->
        {:error, {:execution, {:invalid, :resources}}}

      true ->
        case Enum.find(resources, &(&1 not in @known_execution_resources)) do
          nil -> {:ok, resources}
          name -> {:error, {:execution, {:unknown_resource, name}}}
        end
    end
  end

  defp execution_resources(_data), do: {:error, {:execution, {:invalid, :resources}}}

  defp environment_name?(name) when is_binary(name), do: name =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  defp environment_name?(_name), do: false

  defp execution_positive_integer(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:execution, {:invalid, String.to_existing_atom(key)}}}
    end
  end

  defp parse_mcp(data, auth) when is_map(data) do
    case Map.keys(data) -- ["servers"] do
      [key | _] -> {:error, {:mcp, {:unknown_key, key}}}
      [] -> parse_mcp_servers(Map.get(data, "servers", []), auth)
    end
  end

  defp parse_mcp(_data, _auth), do: {:error, {:mcp, {:invalid, :servers}}}

  defp parse_mcp_servers(servers, auth) when is_list(servers) do
    Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
      case parse_mcp_server(server, acc, auth) do
        {:ok, server} -> {:cont, {:ok, acc ++ [server]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_mcp_servers(_servers, _auth), do: {:error, {:mcp, {:invalid, :servers}}}

  defp parse_mcp_server(data, acc, auth) when is_map(data) do
    case Map.keys(data) -- @mcp_server_keys do
      [key | _] ->
        {:error, {:mcp, {:unknown_key, key}}}

      [] ->
        with {:ok, name} <- mcp_string(data, "name"),
             :ok <- check_unique_mcp_name(acc, name),
             {:ok, command} <- mcp_command(data),
             {:ok, protocol_version} <- mcp_string(data, "protocol_version"),
             {:ok, secrets} <- secret_binding(Map.get(data, "secrets", %{}), auth) do
          {:ok,
           %{name: name, command: command, protocol_version: protocol_version, secrets: secrets}}
        else
          {:error, {:mcp, _reason}} = error -> error
          {:error, reason} -> {:error, {:mcp, name_of(data), reason}}
        end
    end
  end

  defp parse_mcp_server(_data, _acc, _auth), do: {:error, {:mcp, {:invalid, :servers}}}

  defp name_of(data), do: Map.get(data, "name")

  # `[secrets.<tool>]`: each name a tool's process receives, bound to the
  # `[auth]` provider whose credential it is.
  defp parse_secrets(data, auth) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {tool, binding}, {:ok, acc} ->
      case secret_binding(binding, auth) do
        {:ok, binding} -> {:cont, {:ok, Map.put(acc, tool, binding)}}
        {:error, reason} -> {:halt, {:error, {:secrets, tool, reason}}}
      end
    end)
  end

  defp parse_secrets(_data, _auth), do: {:error, {:secrets, {:invalid, :table}}}

  defp secret_binding(binding, auth) when is_map(binding) do
    Enum.reduce_while(binding, {:ok, %{}}, fn {name, provider}, {:ok, acc} ->
      cond do
        not Omunculus.Execution.Command.secret_name?(name) ->
          {:halt, {:error, {:invalid_secret_name, name}}}

        not is_binary(provider) ->
          {:halt, {:error, {:invalid, :secrets}}}

        true ->
          case validate_model_provider(provider, auth) do
            :ok -> {:cont, {:ok, Map.put(acc, name, provider)}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp secret_binding(_binding, _auth), do: {:error, {:invalid, :secrets}}

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
    assemble_data = Map.get(data, "assemble")
    layer_data = Map.drop(data, @policy_extra_keys)

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
             {:ok, depths, depth_workflows} <- parse_depths(depth_data, workflows),
             {:ok, assemble} <- tag_error(fetch_assemble(assemble_data), :policy),
             {:ok, max_retries} <- fetch_max_retries(data),
             {:ok, last_run_output_bytes} <- fetch_positive(data, :last_run_output_bytes),
             {:ok, tool_output_bytes} <- fetch_positive(data, :tool_output_bytes),
             {:ok, conversation_bytes} <- fetch_positive(data, :conversation_bytes),
             {:ok, send_catalog} <- fetch_send_catalog(data),
             {:ok, session} <- fetch_session(data) do
          {:ok, policy, depths, policy_workflow, policy_workspace, depth_workflows, assemble,
           max_retries, last_run_output_bytes, tool_output_bytes, conversation_bytes,
           send_catalog, session}
        end
    end
  end

  defp tag_error({:ok, _} = ok, _tag), do: ok
  defp tag_error({:error, reason}, tag), do: {:error, {tag, reason}}

  defp fetch_assemble(nil), do: {:ok, nil}

  defp fetch_assemble(name) when is_binary(name) and name != "", do: {:ok, name}

  defp fetch_assemble(_invalid), do: {:error, {:invalid, :assemble}}

  defp fetch_max_retries(%{"max_retries" => n}) when is_integer(n) and n >= 0, do: {:ok, n}
  defp fetch_max_retries(_data), do: {:error, {:policy, {:invalid, :max_retries}}}

  # Absent, a run is sent its own tools only.
  defp fetch_send_catalog(data) do
    case Map.get(data, "send_catalog") do
      nil -> {:ok, false}
      flag when is_boolean(flag) -> {:ok, flag}
      _invalid -> {:error, {:policy, {:invalid, :send_catalog}}}
    end
  end

  # Sessions continue only with both: how long a paused session stays
  # worth continuing, and how large it may grow.
  defp fetch_session(data) do
    with {:ok, ttl_ms} <- fetch_positive(data, :session_ttl_ms),
         {:ok, max_bytes} <- fetch_positive(data, :session_max_bytes) do
      if is_nil(ttl_ms) == is_nil(max_bytes),
        do: {:ok, %{ttl_ms: ttl_ms, max_bytes: max_bytes}},
        else: {:error, {:policy, {:invalid, :session}}}
    end
  end

  defp fetch_positive(data, key) do
    case Map.get(data, Atom.to_string(key)) do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      _invalid -> {:error, {:policy, {:invalid, key}}}
    end
  end

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

  defp parse_workspace(data, project_dir) when is_map(data) do
    {overlays, rest} = Map.split(data, @workspace_overlay_keys)

    case Map.keys(rest) -- ["root", "config" | @layer_keys] do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, root} <- fetch_root(rest, project_dir),
             {:ok, config} <- fetch_workspace_config_path(rest),
             {:ok, ceiling} <- parse_layer(Map.drop(rest, ["root", "config"]), nil),
             {:ok, overlay} <- parse_workspace_overlay(overlays) do
          {:ok,
           %{
             root: root,
             config: config,
             ceiling: ceiling,
             overlay: overlay,
             resolved: nil
           }}
        end
    end
  end

  defp parse_workspace(_data, _project_dir), do: {:error, {:invalid, :table}}

  defp parse_workspace_overlay(overlays) do
    Enum.reduce_while(overlays, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_map(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:halt, {:error, overlay_table_error(key)}}
      end
    end)
  end

  defp overlay_table_error("execution"), do: {:execution, {:invalid, :table}}
  defp overlay_table_error("models"), do: {:models, :invalid}
  defp overlay_table_error("agents"), do: {:invalid, :agents}
  defp overlay_table_error("workflows"), do: {:invalid, :workflows}
  defp overlay_table_error("tools"), do: {:tools, {:invalid, :table}}
  defp overlay_table_error("policy"), do: {:policy, {:invalid, :table}}
  defp overlay_table_error("mcp"), do: {:mcp, {:invalid, :servers}}
  defp overlay_table_error("auth"), do: {:auth, {:invalid, :table}}
  defp overlay_table_error(key), do: {:unknown_key, key}

  defp overlay_config(%__MODULE__{} = config, inline_overlay, file_overlay, _file_dir)
       when inline_overlay == %{} and file_overlay == %{} do
    {:ok, config}
  end

  defp overlay_config(%__MODULE__{} = config, inline_overlay, file_overlay, file_dir) do
    file_dir = file_dir || Path.dirname(config.path)

    config.data
    |> deep_merge(strip_ceiling(inline_overlay))
    |> deep_merge(strip_ceiling(expand_overlay_paths(file_overlay, file_dir)))
    |> parse(config.path, false)
  end

  defp resolve_all_workspaces(config) do
    Enum.reduce_while(config.workspaces, {:ok, config}, fn {name, workspace}, {:ok, acc} ->
      case resolve_workspace(acc, name, workspace) do
        {:ok, updated_workspace} ->
          {:cont, {:ok, %{acc | workspaces: Map.put(acc.workspaces, name, updated_workspace)}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp resolve_workspace(config, name, workspace) do
    with {:ok, file_data} <- read_workspace_config(name, workspace),
         :ok <- validate_workspace_file_keys(file_data, name),
         {:ok, file_policy_layer} <- extract_file_policy_layer(file_data),
         ceiling = intersect_ceiling(workspace.ceiling, file_policy_layer),
         file_dir = workspace_file_dir(workspace),
         {:ok, resolved} <- overlay_config(config, workspace.overlay, file_data, file_dir),
         resolved = patch_workspace_ceiling(resolved, name, ceiling) do
      {:ok, %{workspace | ceiling: ceiling, resolved: resolved}}
    end
  end

  defp read_workspace_config(_name, %{config: nil}), do: {:ok, %{}}

  defp read_workspace_config(name, %{config: config_rel, root: root}) do
    read_workspace_file(name, Path.expand(config_rel, root))
  end

  defp read_workspace_file(name, path) do
    if File.regular?(path) do
      Toml.decode_file(path)
    else
      {:error, {:workspace, name, {:config, :missing, path}}}
    end
  end

  defp validate_workspace_file_keys(data, _name) when data == %{} do
    :ok
  end

  defp validate_workspace_file_keys(data, name) when is_map(data) do
    case Map.keys(data) -- @workspace_file_keys do
      [key | _] -> {:error, {:workspace, name, {:unknown_key, key}}}
      [] -> :ok
    end
  end

  defp validate_workspace_file_keys(_data, name),
    do: {:error, {:workspace, name, {:invalid, :table}}}

  defp workspace_file_dir(%{config: nil, root: root}), do: root

  defp workspace_file_dir(%{config: config_rel, root: root}),
    do: Path.dirname(Path.expand(config_rel, root))

  defp extract_file_policy_layer(file_data) do
    case Map.fetch(file_data, "policy") do
      :error ->
        {:ok, %Layer{}}

      {:ok, policy} when is_map(policy) ->
        policy
        |> Map.drop(@policy_extra_keys)
        |> parse_layer(nil)

      {:ok, _} ->
        {:error, {:policy, {:invalid, :table}}}
    end
  end

  defp intersect_ceiling(%Layer{} = inline, %Layer{} = file) do
    %Layer{
      mode: file.mode || inline.mode,
      deny: Enum.uniq(inline.deny ++ file.deny),
      granted: intersect_ceiling_lists(inline.granted, file.granted),
      negotiable: intersect_ceiling_lists(inline.negotiable, file.negotiable),
      human: intersect_ceiling_lists(inline.human, file.human),
      pinned: intersect_ceiling_lists(inline.pinned, file.pinned),
      overrides: Overrides.merge([inline.overrides, file.overrides])
    }
  end

  defp intersect_ceiling_lists(left, right) do
    cond do
      left == [] -> right
      right == [] -> left
      true -> Enum.filter(left, &(&1 in right))
    end
  end

  defp patch_workspace_ceiling(config, name, ceiling) do
    update_in(config.workspaces[name].ceiling, fn _ -> ceiling end)
  end

  defp fetch_workspace_config_path(data) do
    case Map.fetch(data, "config") do
      :error -> {:ok, nil}
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, {:invalid, :config}}
    end
  end

  defp grant_workspace_file(data, config_path, workspace_name, workspace, tool_name) do
    config_dir = Path.dirname(Path.expand(config_path))
    project_root = project_root_from_data(data, config_dir)
    workspace_root = Path.expand(workspace["root"], project_root)
    workspace_file = Path.expand(workspace["config"], workspace_root)

    with {:ok, workspace_data} <- read_workspace_file(workspace_name, workspace_file) do
      policy = Map.get(workspace_data, "policy", %{})
      updated = Map.put(workspace_data, "policy", add_name(policy, tool_name))
      {:ok, {:workspace_file, workspace_file, updated}}
    end
  end

  defp project_root_from_data(data, config_dir) do
    case get_in(data, ["project", "root"]) do
      root when is_binary(root) and root != "" -> Path.expand(root, config_dir)
      _ -> config_dir
    end
  end

  defp expand_overlay_paths(overlay, _file_dir) when overlay == %{} do
    overlay
  end

  defp expand_overlay_paths(overlay, file_dir) when is_map(overlay) do
    overlay
    |> expand_overlay_tools_paths(file_dir)
    |> expand_overlay_execution_paths(file_dir)
    |> expand_overlay_mcp_paths(file_dir)
    |> expand_overlay_models_paths(file_dir)
  end

  defp expand_overlay_tools_paths(overlay, file_dir) do
    case Map.get(overlay, "tools") do
      tools when is_map(tools) ->
        tools =
          case Map.get(tools, "paths") do
            paths when is_list(paths) ->
              expanded =
                Enum.map(paths, fn path ->
                  {:ok, expanded} = expand_path(path, file_dir)
                  expanded
                end)

              Map.put(tools, "paths", expanded)

            _ ->
              tools
          end

        tools =
          Map.new(tools, fn
            {"paths", value} ->
              {"paths", value}

            {name, %{"command" => command} = tool} when is_list(command) ->
              {name, Map.put(tool, "command", expand_relative_commands(command, file_dir))}

            entry ->
              entry
          end)

        Map.put(overlay, "tools", tools)

      _ ->
        overlay
    end
  end

  defp expand_overlay_execution_paths(overlay, file_dir) do
    case Map.get(overlay, "execution") do
      %{"sandbox" => sandbox} = execution when is_map(sandbox) ->
        sandbox =
          case Map.get(sandbox, "script") do
            script when is_binary(script) and script != "" ->
              Map.put(sandbox, "script", expand_sandbox_script(script, file_dir))

            _ ->
              sandbox
          end

        sandbox =
          case Map.get(sandbox, "command") do
            command when is_list(command) ->
              Map.put(sandbox, "command", expand_relative_commands(command, file_dir))

            _ ->
              sandbox
          end

        Map.put(overlay, "execution", Map.put(execution, "sandbox", sandbox))

      _ ->
        overlay
    end
  end

  defp expand_overlay_mcp_paths(overlay, file_dir) do
    case Map.get(overlay, "mcp") do
      %{"servers" => servers} = mcp when is_list(servers) ->
        servers =
          Enum.map(servers, fn
            %{"command" => command} = server when is_list(command) ->
              Map.put(server, "command", expand_relative_commands(command, file_dir))

            server ->
              server
          end)

        Map.put(overlay, "mcp", Map.put(mcp, "servers", servers))

      _ ->
        overlay
    end
  end

  defp expand_overlay_models_paths(overlay, file_dir) do
    case Map.get(overlay, "models") do
      models when is_map(models) ->
        models =
          Map.new(models, fn
            {name, %{"command" => command} = spec} when is_list(command) ->
              {name, Map.put(spec, "command", expand_relative_commands(command, file_dir))}

            entry ->
              entry
          end)

        Map.put(overlay, "models", models)

      _ ->
        overlay
    end
  end

  defp expand_relative_commands(command, file_dir) when is_list(command) do
    Enum.map(command, fn
      elem ->
        if relative_command_path?(elem) do
          Path.expand(elem, file_dir)
        else
          elem
        end
    end)
  end

  defp relative_command_path?(path) do
    is_binary(path) and path != "" and not String.starts_with?(path, "~") and
      Path.type(path) == :relative
  end

  defp strip_ceiling(overlay) do
    overlay
    |> strip_layer_keys("policy")
    |> strip_agents_ceiling()
    |> strip_workflows_ceiling()
  end

  defp strip_layer_keys(overlay, key) do
    case Map.get(overlay, key) do
      policy when is_map(policy) -> Map.put(overlay, key, Map.drop(policy, @layer_keys))
      _ -> overlay
    end
  end

  defp strip_agents_ceiling(overlay) do
    case Map.get(overlay, "agents") do
      agents when is_map(agents) ->
        Map.put(
          overlay,
          "agents",
          Map.new(agents, fn {name, agent} ->
            {name, if(is_map(agent), do: Map.drop(agent, @layer_keys), else: agent)}
          end)
        )

      _ ->
        overlay
    end
  end

  defp strip_workflows_ceiling(overlay) do
    case Map.get(overlay, "workflows") do
      workflows when is_map(workflows) ->
        Map.put(
          overlay,
          "workflows",
          Map.new(workflows, fn {name, workflow} ->
            {name, strip_workflow_ceiling(workflow)}
          end)
        )

      _ ->
        overlay
    end
  end

  defp strip_workflow_ceiling(%{"steps" => steps} = workflow) when is_list(steps) do
    workflow
    |> Map.delete("overrides")
    |> Map.put(
      "steps",
      Enum.map(steps, fn
        step when is_map(step) -> Map.drop(step, @layer_keys)
        step -> step
      end)
    )
  end

  defp strip_workflow_ceiling(workflow) when is_map(workflow),
    do: Map.delete(workflow, "overrides")

  defp strip_workflow_ceiling(workflow), do: workflow

  defp deep_merge(base, overlay) when is_map(base) and is_map(overlay) do
    Map.merge(base, overlay, fn _key, left, right ->
      if is_map(left) and is_map(right) and not is_struct(left) and not is_struct(right) do
        deep_merge(left, right)
      else
        right
      end
    end)
  end

  defp fetch_root(data, project_dir) do
    case Map.fetch(data, "root") do
      {:ok, root} when is_binary(root) and root != "" -> {:ok, Path.expand(root, project_dir)}
      _ -> {:error, {:invalid, :root}}
    end
  end

  defp parse_auth(nil, _config_dir), do: {:ok, %{store: nil, providers: %{}}}

  defp parse_auth(data, config_dir) when is_map(data) do
    {store_raw, providers} = Map.pop(data, "store")

    cond do
      not is_nil(store_raw) and not is_binary(store_raw) ->
        {:error, {:auth, {:invalid, :store}}}

      map_size(providers) > 0 and store_raw in [nil, ""] ->
        {:error, {:auth, :missing_store}}

      true ->
        with {:ok, store} <- parse_auth_store(store_raw, config_dir),
             {:ok, parsed} <- parse_auth_providers(providers) do
          {:ok, %{store: store, providers: parsed}}
        end
    end
  end

  defp parse_auth(_data, _config_dir), do: {:error, {:auth, {:invalid, :table}}}

  defp parse_auth_store(nil, _config_dir), do: {:ok, nil}

  defp parse_auth_store(path, config_dir) when is_binary(path) and path != "" do
    {:ok, Path.expand(path, config_dir)}
  end

  defp parse_auth_store(_path, _config_dir), do: {:error, {:auth, {:invalid, :store}}}

  defp parse_auth_providers(providers) when is_map(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn {id, data}, {:ok, acc} ->
      case parse_auth_provider(id, data) do
        {:ok, provider} -> {:cont, {:ok, Map.put(acc, id, provider)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_auth_provider(id, data) when is_map(data) do
    case Map.get(data, "kind") do
      "api_key" -> parse_api_key_provider(id, data)
      "oauth-code" -> parse_oauth_provider(id, data)
      "tool" -> parse_tool_provider(id, data)
      kind when is_binary(kind) -> {:error, {:auth, id, {:unknown_kind, kind}}}
      nil -> {:error, {:auth, id, {:invalid, :kind}}}
      _ -> {:error, {:auth, id, {:invalid, :kind}}}
    end
  end

  defp parse_auth_provider(id, _data), do: {:error, {:auth, id, {:invalid, :table}}}

  defp parse_api_key_provider(id, data) do
    case Map.keys(data) -- ~w(kind key) do
      [key | _] ->
        {:error, {:auth, id, {:unknown_key, key}}}

      [] ->
        case Map.get(data, "key") do
          key when is_binary(key) ->
            {:ok, %{kind: "api_key", key: key}}

          _ ->
            {:error, {:auth, id, {:invalid, :key}}}
        end
    end
  end

  defp parse_oauth_provider(id, data) do
    {callback_raw, rest} = Map.pop(data, "callback")
    {credential_raw, rest} = Map.pop(rest, "credential")
    {authorize_params, rest} = Map.pop(rest, "authorize_params", %{})
    {refresh_raw, rest} = Map.pop(rest, "refresh")
    required = ~w(kind authorize_url token_url client_id scopes pkce)

    case Map.keys(rest) -- required do
      [key | _] ->
        {:error, {:auth, id, {:unknown_key, key}}}

      [] ->
        with {:ok, authorize_url} <- auth_string(rest, "authorize_url"),
             {:ok, token_url} <- auth_string(rest, "token_url"),
             {:ok, client_id} <- auth_string(rest, "client_id"),
             {:ok, scopes} <- auth_string_list(rest, "scopes"),
             {:ok, pkce} <- auth_bool(rest, "pkce"),
             {:ok, callback} <- parse_auth_callback(id, callback_raw),
             {:ok, credential} <- parse_auth_credential(id, credential_raw),
             {:ok, authorize_params} <- auth_params_map(authorize_params),
             {:ok, refresh} <- parse_auth_refresh(refresh_raw) do
          {:ok,
           %{
             kind: "oauth-code",
             authorize_url: authorize_url,
             token_url: token_url,
             client_id: client_id,
             scopes: scopes,
             pkce: pkce,
             callback: callback,
             credential: credential,
             authorize_params: authorize_params,
             refresh: refresh
           }}
        else
          {:error, {:auth, ^id, _} = reason} -> {:error, reason}
          {:error, reason} -> {:error, {:auth, id, reason}}
        end
    end
  end

  defp parse_tool_provider(id, data) do
    case Map.keys(data) -- ~w(kind login refresh) do
      [key | _] ->
        {:error, {:auth, id, {:unknown_key, key}}}

      [] ->
        with {:ok, login} <- auth_string(data, "login"),
             {:ok, refresh} <- auth_string(data, "refresh") do
          {:ok, %{kind: "tool", login: login, refresh: refresh}}
        else
          {:error, reason} -> {:error, {:auth, id, reason}}
        end
    end
  end

  defp parse_auth_callback(_id, data) when is_map(data) do
    case Map.keys(data) -- ~w(host port path) do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, host} <- auth_string(data, "host"),
             {:ok, port} <- auth_port(data),
             {:ok, path} <- auth_string(data, "path") do
          {:ok, %{host: host, port: port, path: path}}
        end
    end
  end

  defp parse_auth_callback(_id, _data), do: {:error, {:invalid, :callback}}

  defp parse_auth_credential(_id, data) when is_map(data) do
    {refresh, rest} = Map.pop(data, "refresh")

    case Map.keys(rest) -- ~w(access expires) do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, access} <- auth_string(rest, "access"),
             {:ok, expires} <- auth_string(rest, "expires") do
          credential = %{access: access, expires: expires}

          cond do
            is_nil(refresh) -> {:ok, credential}
            is_binary(refresh) and refresh != "" -> {:ok, Map.put(credential, :refresh, refresh)}
            true -> {:error, {:invalid, :refresh}}
          end
        end
    end
  end

  defp parse_auth_credential(_id, _data), do: {:error, {:invalid, :credential}}

  defp parse_auth_refresh(nil), do: {:ok, nil}

  defp parse_auth_refresh(data) when is_map(data) do
    case Map.keys(data) -- ~w(token_url) do
      [key | _] ->
        {:error, {:unknown_key, key}}

      [] ->
        with {:ok, token_url} <- auth_string(data, "token_url") do
          {:ok, %{token_url: token_url}}
        end
    end
  end

  defp parse_auth_refresh(_data), do: {:error, {:invalid, :refresh}}

  defp auth_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp auth_string_list(data, key) do
    case Map.get(data, key) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: {:ok, list},
          else: {:error, {:invalid, String.to_atom(key)}}

      _ ->
        {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp auth_bool(data, key) do
    case Map.get(data, key) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp auth_port(data) do
    case Map.get(data, "port") do
      port when is_integer(port) and port > 0 and port < 65_536 -> {:ok, port}
      _ -> {:error, {:invalid, :port}}
    end
  end

  defp auth_params_map(params) when is_map(params) do
    if Enum.all?(params, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, params}
    else
      {:error, {:invalid, :authorize_params}}
    end
  end

  defp auth_params_map(_params), do: {:error, {:invalid, :authorize_params}}

  defp validate_model_provider(nil, _auth), do: :ok

  defp validate_model_provider(provider, %{providers: providers}) do
    if Map.has_key?(providers, provider) do
      :ok
    else
      {:error, {:unknown_provider, provider}}
    end
  end

  defp parse_models(nil, _auth, _config_dir), do: {:error, {:models, :missing}}

  defp parse_models(data, auth, config_dir) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case parse_model(name, spec, auth, config_dir) do
        {:ok, model} -> {:cont, {:ok, Map.put(acc, name, model)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_models(_data, _auth, _config_dir), do: {:error, {:models, :invalid}}

  defp parse_model(name, data, auth, config_dir) when is_map(data) do
    case Map.get(data, "api") do
      "openai-completions" ->
        parse_http_model(name, data, auth, @openai_model_keys, Omunculus.Model.OpenAI)

      "openai-responses" ->
        parse_http_model(name, data, auth, @openai_model_keys, Omunculus.Model.OpenAIResponses)

      "anthropic-messages" ->
        parse_http_model(name, data, auth, @http_model_keys, Omunculus.Model.AnthropicMessages)

      "command" ->
        parse_command_model(name, data, auth, config_dir)

      "module" ->
        parse_module_model(name, data)

      nil ->
        {:error, {:models, name, {:invalid, :api}}}

      api ->
        {:error, {:models, name, {:unknown_api, api}}}
    end
  end

  defp parse_model(name, _data, _auth, _config_dir),
    do: {:error, {:models, name, {:invalid, :api}}}

  defp parse_http_model(name, data, auth, keys, module) do
    api = data["api"]

    case Map.keys(data) -- keys do
      [key | _] ->
        {:error, {:models, name, {:unknown_key, key}}}

      [] ->
        with {:ok, url} <- model_string(data, "url"),
             {:ok, model} <- model_string(data, "model"),
             {:ok, timeout_ms} <- model_timeout(data),
             {:ok, temperature} <- model_temperature(data),
             {:ok, headers} <- model_headers(data),
             {:ok, body} <- model_body(data),
             {:ok, stream} <- model_boolean(data, "stream"),
             {:ok, code_mode} <- model_boolean(data, "code_mode"),
             {:ok, retries} <- model_retries(data),
             {:ok, prompt_cache_key} <- model_optional_string(data, "prompt_cache_key"),
             {:ok, provider} <- model_optional_string(data, "provider"),
             :ok <- validate_model_provider(provider, auth) do
          input =
            %{
              "api" => api,
              "url" => url,
              "model" => model,
              "timeout_ms" => timeout_ms
            }
            |> maybe_put_model("temperature", temperature)
            |> maybe_put_model("headers", headers)
            |> maybe_put_model("body", body)
            |> maybe_put_model("stream", stream)
            |> maybe_put_model("retries", retries)
            |> maybe_put_model("code_mode", code_mode)
            |> maybe_put_model("prompt_cache_key", prompt_cache_key)
            |> maybe_put_model("provider", provider)

          {:ok,
           %{
             api: api,
             module: module,
             input: input
           }}
        else
          {:error, reason} -> {:error, {:models, name, reason}}
        end
    end
  end

  defp parse_command_model(name, data, auth, config_dir) do
    case Map.keys(data) -- @command_model_keys do
      [key | _] ->
        {:error, {:models, name, {:unknown_key, key}}}

      [] ->
        with {:ok, command} <- model_command(data, config_dir),
             {:ok, model} <- model_string(data, "model"),
             {:ok, params} <- model_params(data),
             {:ok, provider} <- model_optional_string(data, "provider"),
             :ok <- validate_model_provider(provider, auth) do
          input =
            %{
              "api" => "command",
              "command" => command,
              "model" => model,
              "params" => params
            }
            |> maybe_put_model("provider", provider)

          {:ok, %{api: "command", module: Omunculus.Model.Command, input: input}}
        else
          {:error, reason} -> {:error, {:models, name, reason}}
        end
    end
  end

  defp model_command(%{"command" => [_ | _] = command}, config_dir) do
    if Enum.all?(command, &(is_binary(&1) and &1 != "")) do
      {:ok, expand_relative_commands(command, config_dir)}
    else
      {:error, {:invalid, :command}}
    end
  end

  defp model_command(_data, _config_dir), do: {:error, {:invalid, :command}}

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

  defp model_retries(data) do
    case Map.fetch(data, "retries") do
      :error -> {:ok, nil}
      {:ok, n} when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid, :retries}}
    end
  end

  defp model_boolean(data, key) do
    case Map.fetch(data, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp model_optional_string(data, key) do
    case Map.fetch(data, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp model_body(data) do
    case Map.fetch(data, "body") do
      :error -> {:ok, nil}
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> {:error, {:invalid, :body}}
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
             {:ok, assemble} <- fetch_assemble(data["assemble"]),
             {:ok, ceiling} <- parse_layer(Map.drop(data, @agent_extra_keys), nil) do
          {:ok,
           %{
             depth: depth,
             text: text,
             workflow_only: workflow_only,
             model: model,
             assemble: assemble,
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
    case Map.keys(data) -- ["steps", "overrides"] do
      [key | _] ->
        {:error, {:workflow, name, {:unknown_key, key}}}

      [] ->
        case {Overrides.parse(Map.get(data, "overrides", %{})), Map.get(data, "steps")} do
          {{:error, reason}, _steps} -> {:error, {:workflow, name, reason}}
          {{:ok, overrides}, [_ | _] = steps} -> parse_steps(name, steps, agents, overrides)
          {{:ok, _overrides}, _steps} -> {:error, {:workflow, name, :no_steps}}
        end
    end
  end

  defp parse_steps(workflow, steps, agents, overrides) do
    Enum.reduce_while(steps, {:ok, []}, fn step_data, {:ok, acc} ->
      with {:ok, step} <- parse_step(workflow, step_data, agents, overrides),
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

  # The workflow's overrides apply to the runs in its stages, beneath each
  # stage's own, so they fold into every step's layer.
  defp parse_step(workflow, data, agents, overrides) when is_map(data) do
    case Map.keys(data) -- (@step_extra_keys ++ @layer_keys) do
      [key | _] ->
        {:error, {:workflow, workflow, {:unknown_key, key}}}

      [] ->
        with {:ok, name} <- fetch_step_name(data),
             {:ok, agent} <- fetch_step_agent(data, agents),
             {:ok, ceiling} <- parse_layer(Map.drop(data, @step_extra_keys), nil) do
          overrides = Overrides.merge([overrides, ceiling.overrides])
          {:ok, %{name: name, agent: agent, ceiling: %{ceiling | overrides: overrides}}}
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
             {:ok, deny} <- fetch_list(data, "deny", :deny),
             {:ok, pinned} <- fetch_list(data, "pinned", :pinned),
             {:ok, overrides} <- Overrides.parse(Map.get(data, "overrides", %{})) do
          {:ok,
           %Layer{
             mode: mode,
             granted: granted,
             negotiable: negotiable,
             human: human,
             deny: deny,
             pinned: pinned,
             overrides: overrides
           }}
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
