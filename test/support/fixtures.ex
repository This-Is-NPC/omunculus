defmodule Omunculus.Fixtures do
  @moduledoc """
  Inserts rows behind the store's back so tests can set up state the
  actions of the current stage cannot create yet.
  """

  alias Omunculus.Config
  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Id
  alias Omunculus.Project
  alias Omunculus.Store.{Query, Runs}
  alias Omunculus.Test.ScriptedModel
  alias Omunculus.Tools.Preset

  @now "2026-01-01T00:00:00Z"
  @execution """
  [execution]
  backend = "bubblewrap"
  runtimes = ["/usr"]
  environment = ["LANG", "LC_ALL", "TERM"]
  timeout_ms = 30000
  max_output_bytes = 1048576
  max_concurrent = 4
  max_queue = 64
  queue_timeout_ms = 30000
  resources = ["sandbox.write", "sandbox.network"]
  """

  @defaults %{
    prompts: %{kind: "message", body: "hi", created_at: @now},
    events: %{type: "comment", body: "{}", at: @now},
    runs: %{agent: "concierge", depth: "0", status: "open"},
    comments: %{author: "agent", kind: "note", body: "note", created_at: @now},
    works: %{
      title: "a work",
      goal: "a goal",
      assignee: "concierge",
      state: "open",
      created_at: @now
    },
    requests: %{
      agent: "concierge",
      options: ~s({"grant":[{"name":"grant","args":{"kind":"tool","name":"write"}}],"deny":[]}),
      arbiter: "human",
      status: "waiting_human",
      created_at: @now
    },
    inbox: %{agent: "concierge", created_at: @now}
  }

  @spec defaults(atom) :: map
  def defaults(table), do: Map.fetch!(@defaults, table)

  @spec insert(Omunculus.Store.Connection.t(), atom, map) :: String.t()
  def insert(conn, table, attrs \\ %{}) do
    row =
      table
      |> defaults()
      |> Map.put(:id, Id.new())
      |> Map.merge(attrs)

    :ok = Query.insert(conn, table, row)
    row.id
  end

  @spec config(String.t() | nil, keyword) :: Config.t()
  def config(toml \\ nil, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)

    case toml do
      nil ->
        install_default(dir)

        case Keyword.get(opts, :model) do
          fun when is_function(fun) -> use_model(dir, fun)
          _ -> :ok
        end

      contents ->
        write_config(dir, contents, opts)
    end

    {:ok, config} = load_config(dir)
    config
  end

  @spec write_config(String.t(), String.t(), keyword) :: :ok
  def write_config(dir, toml, opts \\ []) when is_list(opts) do
    body = toml <> "\n" <> @execution
    body = if String.contains?(toml, "[tools]"), do: body, else: body <> "\n" <> tools_table(dir)
    File.write!(config_path(dir), body)
    apply_defaults(dir, opts)
  end

  @doc """
  A pack named `team` in `dir/team`: two agents on its role `lead`, a
  workflow, a tool secret on its provider `vault`, a depth layer, an empty
  `tools/`, an `AGENTS.md` for the workspace and an environment script.
  """
  @spec pack(String.t()) :: String.t()
  def pack(dir) do
    pack = Path.join(dir, "team")
    File.mkdir_p!(Path.join(pack, "tools"))
    File.mkdir_p!(Path.join(pack, "workspace"))
    File.mkdir_p!(Path.join(pack, "environment"))
    File.write!(Path.join([pack, "workspace", "AGENTS.md"]), "# Team rules\n")
    File.write!(Path.join([pack, "environment", "up"]), "#!/bin/sh\n")

    File.write!(Path.join(pack, "pack.toml"), """
    [pack]
    name = "team"
    roles = ["lead"]
    auth = ["vault"]

    [agents.chief]
    depth = 0
    model = "lead"
    text = "chief"
    tools = ["end"]

    [agents.hand]
    depth = 1
    model = "lead"
    text = "hand"
    tools = ["end"]

    [workflows.line]
    steps = [{ name = "make", agent = "hand" }]

    [secrets.deploy]
    KEY = "vault"

    [policy.depth.1]
    workflows = ["line"]
    """)

    pack
  end

  @doc """
  Writes, in `dir`, a config with what a pack's roles and providers map to —
  the model `fast` and the login `mine` — then `toml`; returns its path.
  """
  @spec write_pack_config(String.t(), String.t()) :: String.t()
  def write_pack_config(dir, toml \\ "") do
    write_config(dir, """
    [models.fast]
    api = "module"
    module = "Omunculus.Model.Fake"

    [auth]
    store = "auth.json"

    [auth.mine]
    kind = "api_key"
    key = "secret"

    #{toml}
    """)

    config_path(dir)
  end

  @doc "A fresh directory under the system temp dir, removed when the test exits."
  @spec tmp_dir() :: String.t()
  def tmp_dir do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "The params `Runs.begin/2` takes for a concierge run at depth 0, merged with `fields`."
  @spec run_params(map) :: map
  def run_params(fields \\ %{}) do
    params =
      Map.merge(
        %{
          prompt_id: nil,
          agent: "concierge",
          depth: 0,
          ceiling: %{have: ["send"], askable: [], sealed: [], blocked: [], uncited: "askable"},
          execution: %{"id" => "execution-policy"},
          work_id: nil,
          via: nil,
          request_id: nil
        },
        fields
      )

    Map.put_new(params, :tools, params.ceiling.have)
  end

  @doc "Begins a run with `run_params(fields)` and attaches an assembled prompt to it."
  @spec open_run(Omunculus.Store.Connection.t(), map) :: map
  def open_run(conn, fields \\ %{}) do
    {:ok, run} = Runs.begin(conn, run_params(fields))
    {:ok, run} = Runs.attach_assembled(conn, run.id, "assembled")
    run
  end

  @spec open_project(String.t()) :: Project.t()
  def open_project(dir) do
    {:ok, config} = load_config(dir)
    {:ok, project} = Project.open(config)
    project
  end

  @doc "The opening `Run.open/2` takes, every field not given `nil`."
  @spec opening(String.t() | nil, String.t() | nil, map) :: map
  def opening(prompt_id, work_id \\ nil, fields \\ %{}),
    do:
      Map.merge(
        %{prompt_id: prompt_id, work_id: work_id, request_id: nil, via: nil, agent: nil},
        fields
      )

  @spec write_tool(String.t(), String.t(), String.t(), String.t()) :: :ok
  def write_tool(dir, name, toml, script), do: write_command(dir, name, "tool.toml", toml, script)

  @spec write_hook(String.t(), String.t(), String.t(), String.t()) :: :ok
  def write_hook(dir, name, toml, script), do: write_command(dir, name, "hook.toml", toml, script)

  @doc "Installs a model-triggered command tool that prints `out_json` as its `out`."
  @spec write_model_tool(String.t(), String.t(), String.t()) :: :ok
  def write_model_tool(dir, name, out_json \\ ~s({"ok": true, "output": "", "emit": []})) do
    toml = """
    name = "#{name}"
    kind = "tool"
    triggers = ["model"]
    command = ["./run"]
    """

    write_tool(dir, name, toml, "#!/bin/sh\necho '#{out_json}'\n")
  end

  defp write_command(dir, name, file, toml, script) do
    tool_dir = Path.join([dir, "tools", name])
    File.mkdir_p!(tool_dir)
    File.write!(Path.join(tool_dir, file), toml)
    run_path = Path.join(tool_dir, "run")
    File.write!(run_path, script)
    File.chmod!(run_path, 0o755)
  end

  @doc "The first line of an assembled prompt, the agent's own text."
  @spec role(String.t()) :: String.t()
  def role(assembled), do: assembled |> String.split("\n", parts: 2) |> hd()

  @doc "The text under `## Last comment` of an assembled prompt, or nil."
  @spec last_comment(String.t()) :: String.t() | nil
  def last_comment(assembled) do
    case String.split(assembled, "## Last comment\n", parts: 2) do
      [_before, rest] -> rest |> String.split("\n\n", parts: 2) |> hd()
      [_none] -> nil
    end
  end

  @spec use_model(String.t() | Project.t(), fun) :: :ok
  def use_model(%Project{dir: dir}, fun), do: use_model(dir, fun)

  def use_model(dir, fun) when is_binary(dir) and is_function(fun),
    do: apply_defaults(dir, model: fun)

  defp apply_defaults(dir, opts) do
    path = config_path(dir)

    case Toml.decode_file(path) do
      {:ok, data} -> File.write!(path, Config.Toml.encode(inject_defaults(data, opts)))
      _invalid -> :ok
    end
  end

  defp inject_defaults(data, opts) do
    data = data |> maybe_put_store() |> maybe_put_sandbox() |> maybe_put_policy(opts)

    case Keyword.get(opts, :model) do
      fun when is_function(fun) ->
        id = Id.new()
        ScriptedModel.put(id, fun)

        data
        |> put_model("scripted", scripted_spec(id))
        |> put_agent_models("scripted")

      _absent ->
        case Map.get(data, "models") do
          models when is_map(models) and map_size(models) > 0 ->
            data

          _ ->
            data
            |> put_model("fake", %{
              "api" => "module",
              "module" => "Omunculus.Model.Fake"
            })
            |> put_missing_agent_models("fake")
        end
    end
  end

  defp put_model(data, name, spec) do
    models = data |> Map.get("models") |> then(&if(is_map(&1), do: &1, else: %{}))
    Map.put(data, "models", Map.put(models, name, spec))
  end

  defp scripted_spec(id) do
    %{
      "api" => "module",
      "module" => "Omunculus.Test.ScriptedModel",
      "params" => %{"script" => id}
    }
  end

  defp put_agent_models(data, name) do
    update_agents(data, fn agent -> put_agent_model(agent, name, true) end)
  end

  defp put_missing_agent_models(data, name) do
    update_agents(data, fn agent -> put_agent_model(agent, name, false) end)
  end

  defp update_agents(data, fun) do
    case Map.get(data, "agents") do
      agents when is_map(agents) ->
        Map.put(data, "agents", Map.new(agents, fn {name, agent} -> {name, fun.(agent)} end))

      _ ->
        data
    end
  end

  defp put_agent_model(agent, name, true) when is_map(agent), do: Map.put(agent, "model", name)

  defp put_agent_model(agent, name, false) when is_map(agent) do
    if Map.has_key?(agent, "model"), do: agent, else: Map.put(agent, "model", name)
  end

  defp put_agent_model(agent, _name, _force), do: agent

  defp maybe_put_policy(data, opts) do
    policy = Map.get(data, "policy")
    policy = if is_map(policy), do: policy, else: %{}

    policy =
      [assemble: "assemble", max_retries: 0]
      |> Enum.reject(fn {key, _value} -> Keyword.get(opts, key, true) == false end)
      |> Enum.reduce(policy, fn {key, value}, policy ->
        Map.put_new(policy, Atom.to_string(key), value)
      end)

    Map.put(data, "policy", policy)
  end

  defp maybe_put_store(data) do
    case Map.get(data, "store") do
      store when is_map(store) ->
        data

      _ ->
        Map.put(data, "store", %{"path" => ".omunculus/store.sqlite3"})
    end
  end

  defp maybe_put_sandbox(data) do
    case get_in(data, ["execution", "sandbox"]) do
      sandbox when is_map(sandbox) ->
        data

      _ ->
        if is_map(Map.get(data, "execution")) do
          put_in(data, ["execution", "sandbox"], sandbox_table_data())
        else
          data
        end
    end
  end

  defp sandbox_table_data do
    sandbox = ExecutionPolicyFixtures.sandbox()

    %{
      "script" => sandbox.script,
      "command" => sandbox.command,
      "runner" => sandbox.runner,
      "exec" => sandbox.exec
    }
  end

  @spec sandbox_table() :: String.t()
  def sandbox_table do
    sandbox = ExecutionPolicyFixtures.sandbox()

    """
    [execution.sandbox]
    script = #{Jason.encode!(sandbox.script)}
    command = #{Jason.encode!(sandbox.command)}
    runner = #{Jason.encode!(sandbox.runner)}
    exec = #{Jason.encode!(sandbox.exec)}
    """
  end

  @spec tools_table(String.t()) :: String.t()
  def tools_table(dir) do
    """
    [tools]
    paths = #{Jason.encode!([package_tools(), Path.join(dir, "tools")])}
    """
  end

  @spec package_tools() :: String.t()
  def package_tools, do: Application.app_dir(:omunculus, Path.join("priv", "tools"))

  @spec preset_dir(String.t()) :: String.t()
  def preset_dir(name),
    do: Path.join(Application.app_dir(:omunculus, Path.join("priv", "presets")), name)

  @spec config_path(String.t()) :: String.t()
  def config_path(dir), do: Path.join(dir, "omunculus.toml")

  @spec load_config(String.t()) :: {:ok, Config.t()} | {:error, term}
  def load_config(dir), do: Config.load(config_path(dir))

  @spec grant(String.t(), Config.grant_layer(), String.t()) :: :ok | {:error, term}
  def grant(dir, layer, name), do: Config.grant(config_path(dir), layer, name)

  @doc """
  Installs the default preset into `dir`, its skills read from `dir`'s own
  `.agents/skills` alone, so no test sees the skills of the machine.
  """
  @spec install_default(String.t()) :: :ok
  def install_default(dir) do
    %{"ok" => true} =
      Preset.run(%{
        args: %{"name" => "default", "from" => preset_dir("default")},
        config_path: config_path(dir)
      })

    path = config_path(dir)

    # The default preset's own agents alone: without the system team beside
    # the concierge, a message names no agent.
    data =
      path
      |> Toml.decode_file!()
      |> put_in(["skills", "paths"], [".agents/skills"])
      |> Map.delete("packs")

    File.write!(path, Config.Toml.encode(data))
  end
end
