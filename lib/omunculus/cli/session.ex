defmodule Omunculus.CLI.Session do
  @moduledoc false

  alias Omunculus.Runner
  alias Omunculus.CLI.Help
  alias Omunculus.{Config, Interceptor}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  def ephemeral_run(%{args: args, flags: flags}, env) do
    with {:ok, cwd} <- canonicalize_dir(args.dir),
         {:ok, config} <- Config.load(cwd: cwd, config_file: flags["config"], env: env),
         {:ok, checked} <- Config.check(config),
         {:ok, chat} <- provider_chat(config, flags, env) do
      db = ephemeral_db_path()
      workspace_id = ephemeral_workspace_id(config, cwd)
      session_id = Envelope.generate_id("session")

      {:ok, core} = EventCore.start_link(path: db, interceptors: checked.interceptors)
      {:ok, projector} = Projector.start_link(core: core)

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("session.created", payload: %{session_id: session_id})
        )

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("workspace.attached",
            session_id: session_id,
            payload: %{workspace_id: workspace_id, roots: [cwd]}
          )
        )

      runtime_opts = [
        core: core,
        max_depth: 0,
        agents: ephemeral_agents(chat, cwd),
        run_opts: [delegation_timeout: 600_000],
        config: ephemeral_runtime_config(flags, env, cwd)
      ]

      {:ok, runtime} = Runtime.start_link(runtime_opts)

      outcome =
        Runtime.request(core, args.instruction,
          session_id: session_id,
          workspace: workspace_id,
          timeout: 600_000
        )

      :ok = Projector.sync(projector)

      code =
        case outcome do
          {:ok, %{result: result}} ->
            IO.puts(result)
            0

          {:error, reason} ->
            IO.puts(:stderr, "error: #{inspect(reason)}")
            1
        end

      GenServer.stop(runtime)
      GenServer.stop(projector)
      GenServer.stop(core)
      File.rm(db)
      code
    else
      {:error, {:usage, reason}} -> usage(reason)
      {:error, reason} -> usage(reason)
    end
  end

  def session(%{args: args, flags: flags}, _env) do
    case args[:action] do
      "create" -> session_create(args, flags)
      "list" -> session_list(flags)
      other -> usage({:unknown_session_action, other})
    end
  end

  def workspace(%{args: args, flags: flags}, env) do
    case args[:action] do
      "attach" -> workspace_attach(args, flags, env)
      "detach" -> workspace_detach(args, flags)
      other -> usage({:unknown_workspace_action, other})
    end
  end

  def send(%{args: args, flags: flags}, env) do
    with {:ok, db} <- db_path(flags),
         {:ok, config} <- Config.load(cwd: File.cwd!(), config_file: flags["config"], env: env),
         {:ok, checked} <- Config.check(config) do
      {:ok, core0} = EventCore.start_link(path: db)
      session_id = ensure_session(core0)
      attached = attached_workspace_ids(core0)
      GenServer.stop(core0)

      interceptors = resolve_interceptors(checked.interceptors, attached, config)
      {:ok, core} = EventCore.start_link(path: db, interceptors: interceptors)
      {:ok, projector} = Projector.start_link(core: core)

      runtime_opts =
        [
          core: core,
          max_depth: max_depth(config),
          agents: SpikeAgents.resolver(),
          run_opts: [delegation_timeout: 600_000]
        ]
        |> maybe_runtime_config(flags, env)

      {:ok, runtime} = Runtime.start_link(runtime_opts)

      instruction = args.instruction
      workspace = flags["workspace"]

      outcome =
        if flags["detach"] == true do
          detach_request(core, instruction, session_id: session_id, workspace: workspace)
        else
          Runtime.request(core, instruction,
            session_id: session_id,
            workspace: workspace,
            timeout: 600_000
          )
        end

      :ok = Projector.sync(projector)

      code =
        case outcome do
          {:ok, :detached} ->
            0

          {:ok, %{result: result}} ->
            IO.puts(result)
            0

          {:error, reason} ->
            IO.puts(:stderr, "error: send failed: #{inspect(reason)}")
            1
        end

      GenServer.stop(runtime)
      GenServer.stop(projector)
      GenServer.stop(core)
      code
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp session_create(args, flags) do
    with {:ok, db} <- db_path(flags) do
      prepare_db_dir(db)
      session_id = args[:name] || Envelope.generate_id("session")

      {:ok, core} = EventCore.start_link(path: db)

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("session.created",
            payload: %{session_id: session_id}
          )
        )

      GenServer.stop(core)
      IO.puts(session_id)
      0
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp session_list(flags) do
    paths =
      [flags["db"], flags["session"], default_db()]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(paths, fn path ->
      if File.exists?(path) do
        case session_id_from_file(path) do
          {:ok, session_id} -> IO.puts(session_id)
          :error -> IO.puts(path)
        end
      end
    end)

    0
  end

  defp workspace_attach(args, flags, env) do
    name = args[:name]

    with {:ok, db} <- db_path(flags),
         {:ok, config} <- Config.load(cwd: File.cwd!(), config_file: flags["config"], env: env),
         {:ok, ws} <- fetch_workspace(config, name) do
      {:ok, core} = EventCore.start_link(path: db)
      session_id = ensure_session(core)

      payload =
        %{
          workspace_id: name,
          roots: ws.roots || []
        }
        |> maybe_put(:teams, ws.teams)

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("workspace.attached",
            session_id: session_id,
            payload: payload
          )
        )

      GenServer.stop(core)
      0
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp workspace_detach(args, flags) do
    name = args[:name]

    with {:ok, db} <- db_path(flags) do
      {:ok, core} = EventCore.start_link(path: db)
      session_id = ensure_session(core)

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("workspace.detached",
            session_id: session_id,
            payload: %{workspace_id: name}
          )
        )

      GenServer.stop(core)
      0
    else
      {:error, reason} -> usage(reason)
    end
  end

  defp detach_request(core, instruction, opts) do
    payload =
      %{instruction: instruction, depth: 0}
      |> maybe_put_string(:workspace, opts[:workspace])

    {:ok, _} =
      EventCore.append(
        core,
        Envelope.command("task.requested",
          session_id: opts[:session_id],
          workspace_id: opts[:workspace],
          payload: payload
        )
      )

    {:ok, :detached}
  end

  defp ensure_session(core) do
    case session_id_from_log(core) do
      {:ok, session_id} ->
        session_id

      :missing ->
        session_id = Envelope.generate_id("session")

        {:ok, _} =
          EventCore.append(
            core,
            Envelope.command("session.created", payload: %{session_id: session_id})
          )

        session_id
    end
  end

  defp session_id_from_log(core) do
    core
    |> EventCore.stream(0, type: "session.created")
    |> List.first()
    |> case do
      %Envelope{payload: %{"session_id" => session_id}} when is_binary(session_id) ->
        {:ok, session_id}

      _ ->
        :missing
    end
  end

  defp session_id_from_file(path) do
    {:ok, core} = EventCore.start_link(path: path)

    try do
      case session_id_from_log(core) do
        {:ok, session_id} -> {:ok, session_id}
        :missing -> :error
      end
    after
      GenServer.stop(core)
    end
  end

  defp attached_workspace_ids(core) do
    EventCore.query(
      core,
      "SELECT workspace_id FROM SESSION_WORKSPACES WHERE attached = 1 ORDER BY workspace_id"
    )
    |> Enum.map(fn [ws] -> ws end)
  rescue
    _ -> []
  end

  defp resolve_interceptors(items, attached_ids, config) do
    resolved =
      items
      |> Enum.map(&resolve_interceptor(&1, attached_ids, config))
      |> Enum.reject(&is_nil/1)

    maybe_add_workspace_gate(resolved, attached_ids)
  end

  defp resolve_interceptor(item, attached_ids, config) do
    case resolve_module(item.module) do
      {:ok, module} ->
        options =
          (item.options || %{})
          |> Map.merge(Map.take(item, [:teams, :agents]))
          |> Map.put(:attached, attached_ids)
          |> Map.merge(%{
            teams: config.teams,
            workspaces: config.workspaces,
            agents: config.agents
          })

        %{
          name: item.name,
          events: item.events,
          module: module,
          options: options,
          workspaces: item.workspaces
        }

      {:error, _} ->
        nil
    end
  end

  defp maybe_add_workspace_gate(interceptors, attached_ids) do
    cond do
      attached_ids == [] ->
        interceptors

      not Code.ensure_loaded?(Omunculus.Interceptors.WorkspaceGate) ->
        interceptors

      Enum.any?(interceptors, &(&1.name == "workspace-gate")) ->
        interceptors

      true ->
        interceptors ++
          [
            %{
              name: "workspace-gate",
              events: ["task.requested", "task.delegated"],
              module: Omunculus.Interceptors.WorkspaceGate,
              options: %{attached: attached_ids}
            }
          ]
    end
  end

  defp resolve_module(mod) when is_atom(mod), do: {:ok, mod}

  defp resolve_module(name) when is_binary(name), do: Interceptor.resolve(name)

  defp resolve_module(_), do: {:error, :invalid_module}

  defp max_depth(config) do
    depths =
      (config.policy || %{})
      |> Map.keys()
      |> Enum.map(&String.to_integer(to_string(&1)))
      |> Enum.sort(:desc)

    case depths do
      [] -> 1
      [max | _] -> max
    end
  end

  defp maybe_runtime_config(opts, flags, env) do
    case runtime_config(flags, env) do
      nil -> opts
      config -> Keyword.put(opts, :config, config)
    end
  end

  defp runtime_config(flags, env) do
    profile = flags["profile"] || flags["preset"]
    config_file = flags["config"]
    tools = flags["tools"]

    if config_file || profile || tools do
      [
        cwd: File.cwd!(),
        config_file: config_file,
        env: env,
        profile: profile,
        tools: tools
      ]
    else
      nil
    end
  end

  def db_path(flags) do
    {:ok, flags["db"] || flags["session"] || default_db()}
  end

  def default_db do
    Path.join([System.user_home!(), ".omunculus", "session.sqlite3"])
  end

  defp prepare_db_dir(db) do
    db |> Path.dirname() |> File.mkdir_p!()
  end

  defp fetch_workspace(config, name) do
    case Map.get(config.workspaces, name) do
      nil -> {:error, {:unknown_workspace, name}}
      ws -> {:ok, ws}
    end
  end

  defp canonicalize_dir(dir) do
    path = Path.expand(dir)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, {:not_a_directory, dir}}
    end
  end

  defp ephemeral_db_path do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(System.tmp_dir!(), "omunculus-run-#{suffix}.sqlite3")
  end

  defp ephemeral_workspace_id(config, cwd) do
    case Enum.find(config.workspaces, fn {_id, ws} ->
           roots = ws.roots || ws["roots"] || []
           Enum.any?(roots, fn root -> Path.expand(root, cwd) == cwd end)
         end) do
      {id, _} ->
        id

      _ ->
        case Map.keys(config.workspaces) do
          [] -> "default"
          keys -> keys |> Enum.sort() |> List.first()
        end
    end
  end

  defp ephemeral_agents(nil, _cwd), do: SpikeAgents.resolver()

  defp ephemeral_agents(chat, cwd) when is_map(chat) do
    fn ctx ->
      %{
        agent_id: "ephemeral@chat",
        kind: "worker",
        model: chat.model,
        tools: ["write", "read", "edit", "ls", "find", "grep"],
        max_turns: 8,
        chat: chat,
        tool_options: %{roots: ctx[:roots] || [cwd]}
      }
    end
  end

  defp ephemeral_runtime_config(flags, env, cwd) do
    [
      cwd: cwd,
      config_file: flags["config"],
      env: env,
      profile: flags["profile"] || flags["preset"]
    ]
  end

  defp provider_chat(config, flags, env) do
    provider =
      flags["provider"] ||
        if present?(env["OMUNCULUS_BASE_URL"]) || present?(flags["base_url"]),
          do: "chat",
          else: "fake"

    case provider do
      "fake" ->
        {:ok, nil}

      "chat" ->
        with {:ok, session} <- Config.resolve(config, flags) do
          Runner.build_chat(session.chat, flags, env)
        end

      other ->
        {:error, {:invalid_flag_value, "--provider", other}}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp usage(reason) do
    IO.puts(:stderr, Help.usage_error(reason))
    2
  end
end
