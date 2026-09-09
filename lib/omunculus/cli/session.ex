defmodule Omunculus.CLI.Session do
  @moduledoc false

  alias Omunculus.Runner
  alias Omunculus.CLI.Help
  alias Omunculus.{Config, Interceptor}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.Agents

  def ephemeral_run(%{args: args, flags: flags}, env) do
    with :ok <- Omunculus.CLI.UI.validate(flags),
         {:ok, cwd} <- canonicalize_dir(args.dir),
         {:ok, config} <- Config.load(cwd: cwd, config_file: flags["config"], env: env),
         {:ok, checked} <- Config.check(config),
         {:ok, chat} <- provider_chat(config, flags, env),
         {:ok, db} <- reserve_db(flags) do
      workspace_id = ephemeral_workspace_id(config, cwd)
      session_id = Envelope.generate_id("session")
      if flags["db"], do: IO.puts(:stderr, "Session: #{session_id} · Database: #{db}")

      {:ok, core} = EventCore.start_link(path: db, interceptors: checked.interceptors)
      {:ok, projector} = Projector.start_link(core: core)

      {:ok, reporter} =
        Omunculus.CLI.Reporter.start_link(
          core: core,
          ui: flags["ui"],
          detail: flags["detail"],
          path: db,
          session_id: session_id,
          io: :stderr,
          json_events?: flags["json_events"],
          timestamp_format: config.output.timestamp_format
        )

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("session.created",
            session_id: session_id,
            payload: %{session_id: session_id}
          )
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
        session_id: session_id,
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
          return_on_human: true,
          timeout: :infinity
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
      Omunculus.CLI.Reporter.finish(reporter)
      GenServer.stop(projector)
      GenServer.stop(core)
      unless flags["db"], do: File.rm(db)
      code
    else
      {:error, {:usage, reason}} -> usage(reason)
      {:error, reason} -> usage(reason)
    end
  end

  def session(%{args: args, flags: flags}, env) do
    case args[:action] do
      "replay" ->
        with :ok <- Omunculus.CLI.UI.validate(flags) do
          if args[:name],
            do: Omunculus.CLI.Replay.run(args.name, flags),
            else: usage({:missing_required_arg, "session_id"})
        else
          {:error, reason} -> usage(reason)
        end

      "create" ->
        session_create(args, flags)

      "list" ->
        session_list(flags)

      "resume" ->
        with {:ok, db} <- db_path(flags),
             {:ok, core} <- Omunculus.SessionExecutor.ensure(executor_opts(db, flags, env)) do
          IO.puts(ensure_session(core))
          close_client(core)
          0
        else
          {:error, reason} -> usage(reason)
        end

      other ->
        usage({:unknown_session_action, other})
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
         {:ok, _checked} <- Config.check(config),
         :ok <- validate_provider(flags["provider"]),
         {:ok, core} <- Omunculus.SessionExecutor.ensure(executor_opts(db, flags, env)) do
      session_id = ensure_session(core)

      execution =
        Map.take(flags, ["profile", "tools", "model", "base_url", "max_turns", "provider"])
        |> Map.put("cwd", File.cwd!())
        |> Map.put("config_file", flags["config"])
        |> Map.put("profile", flags["profile"] || flags["preset"] || config.defaults.preset)

      opts = [
        session_id: session_id,
        workspace: flags["workspace"],
        execution: execution,
        timeout: 600_000
      ]

      outcome =
        if flags["detach"] == true,
          do: detach_request(core, args.instruction, opts),
          else: Runtime.request(core, args.instruction, opts)

      Projector.sync_core(core)

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

      close_client(core)
      code
    else
      {:error, reason} -> usage(reason)
    end
  end

  def executor_opts(db, flags, env) do
    env = if flags["api_key"], do: Map.put(env, "OMUNCULUS_API_KEY", flags["api_key"]), else: env
    opts = [db: db, cwd: File.cwd!(), config_file: flags["config"], env: env]
    provider = flags["provider"] || if(flags["base_url"] || env["OMUNCULUS_BASE_URL"], do: "chat")
    if provider, do: Keyword.put(opts, :provider, provider), else: opts
  end

  defp validate_provider(provider) when provider in [nil, "fake", "chat"], do: :ok
  defp validate_provider(provider), do: {:error, {:invalid_flag_value, "--provider", provider}}

  def close_client(core) do
    if Process.get(:omunculus_external_cli), do: GenServer.stop(core)
    :ok
  end

  def execution_interceptors(core, checked, config),
    do: resolve_interceptors(checked.interceptors, attached_workspace_ids(core), config)

  defp session_create(args, flags) do
    with {:ok, db} <- db_path(flags) do
      prepare_db_dir(db)
      session_id = args[:name] || Envelope.generate_id("session")

      {:ok, core} = EventCore.start_link(path: db)

      {:ok, _} =
        EventCore.append(
          core,
          Envelope.command("session.created",
            session_id: session_id,
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
    {:ok, db} = db_path(flags)

    case Exqlite.Sqlite3.open(db, mode: :readonly) do
      {:ok, conn} ->
        try do
          for [id] <-
                Omunculus.EventCore.Store.query(
                  conn,
                  "SELECT session_id FROM EVENTS WHERE type = 'session.created' AND session_id IS NOT NULL GROUP BY session_id ORDER BY MIN(sequence)"
                ),
              do: IO.puts(id)

          0
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        usage(reason)
    end
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
      %{instruction: instruction, depth: 0, execution: opts[:execution] || %{}}
      |> maybe_put_string(:workspace, opts[:workspace])

    {:ok, _} =
      EventCore.append(
        core,
        Envelope.command("task.requested",
          work_item_id: Envelope.generate_id("wi"),
          correlation_id: Envelope.generate_id("corr"),
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
            Envelope.command("session.created",
              session_id: session_id,
              payload: %{session_id: session_id}
            )
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

  defp resolve_interceptor(%{agent: agent} = item, _attached_ids, _config) when is_binary(agent),
    do: item

  defp resolve_interceptor(%{actor: actor} = item, _attached_ids, _config) when is_binary(actor),
    do: item

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

  defp reserve_db(flags) do
    path = flags["db"] || ephemeral_db_path()
    with :ok <- File.mkdir_p(Path.dirname(path)), do: {:ok, path}
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

  defp ephemeral_agents(nil, _cwd), do: Agents.resolver()

  defp ephemeral_agents(chat, cwd) when is_map(chat) do
    fn ctx ->
      Agents.resolve(ctx, %{chat: chat})
      |> Map.update(
        :tool_options,
        %{roots: ctx[:roots] || [cwd]},
        &Map.put(&1, :roots, ctx[:roots] || [cwd])
      )
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
