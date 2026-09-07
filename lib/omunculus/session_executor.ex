defmodule Omunculus.SessionExecutor do
  @moduledoc "Resident execution owner; durable session identity and work remain in EVENTS."
  use GenServer
  alias Omunculus.{Config, EventCore, Runtime}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents

  def start_link(opts) do
    db = Path.expand(Keyword.fetch!(opts, :db))

    GenServer.start_link(__MODULE__, Keyword.put(opts, :db, db),
      name: {:global, {__MODULE__, db}}
    )
  end

  def ensure_started(opts) do
    db = Path.expand(Keyword.fetch!(opts, :db))
    opts = Keyword.put(opts, :db, db)

    case :global.whereis_name({__MODULE__, db}) do
      pid when is_pid(pid) ->
        {:ok, pid}

      :undefined ->
        case DynamicSupervisor.start_child(Omunculus.SessionExecutors, {__MODULE__, opts}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  def core(pid), do: GenServer.call(pid, :core)
  def stop(pid), do: DynamicSupervisor.terminate_child(Omunculus.SessionExecutors, pid)

  def ensure(opts) do
    if Process.get(:omunculus_external_cli) do
      ensure_external(opts)
    else
      with {:ok, pid} <- ensure_started(opts), do: {:ok, core(pid)}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    db = Keyword.fetch!(opts, :db)
    File.mkdir_p!(Path.dirname(db))
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    config_file = Keyword.get(opts, :config_file)
    env = Keyword.get(opts, :env, %{})

    with {:ok, config} <- Config.load(cwd: cwd, config_file: config_file, env: env),
         {:ok, checked} <- Config.check(config),
         {:ok, core} <-
           EventCore.start_link(path: db, interceptors: checked.interceptors, poll_ms: 100),
         {:ok, projector} <- Projector.start_link(core: core) do
      Projector.sync(projector)

      EventCore.configure_interceptors(
        core,
        Omunculus.CLI.Session.execution_interceptors(core, checked, config)
      )

      if EventCore.stream(core, 0, type: "session.created") == [] do
        EventCore.append!(
          core,
          Envelope.command("session.created",
            idempotency_key: "default-session",
            payload: %{session_id: Envelope.generate_id("session")}
          )
        )
      end

      depth =
        config.policy |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> 0 end)

      provider = Keyword.get(opts, :provider, if(config.chat.base_url, do: "chat", else: "fake"))

      {:ok, runtime} =
        Runtime.start_link(
          core: core,
          max_depth: depth,
          recover: true,
          agents: Keyword.get(opts, :agents, Agents.resolver(provider: provider, env: env)),
          config: [cwd: cwd, config_file: config_file, env: env]
        )

      {:ok, automations} =
        Omunculus.Automations.start_link(core: core, automations: checked.automations)

      {:ok, %{core: core, projector: projector, runtime: runtime, automations: automations}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:core, _from, state), do: {:reply, state.core, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    if pid in [state.core, state.projector, state.runtime, state.automations],
      do: {:stop, {:component_exit, reason}, state},
      else: {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for pid <- [state.runtime, state.automations, state.projector, state.core],
        Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # The OS lock owns the executor for the lifetime of its VM. Sidecar files
  # are disposable readiness/diagnostic data, never a command transport.
  defp ensure_external(opts) do
    db = opts |> Keyword.fetch!(:db) |> Path.expand()
    ready = db <> ".executor-ready"
    File.mkdir_p!(Path.dirname(db))

    unless ready?(ready) do
      script = :escript.script_name() |> to_string() |> Path.expand()
      public = opts |> Keyword.take([:cwd, :config_file, :provider]) |> Map.new()
      encoded = Jason.encode!(Map.put(public, :db, db)) |> Base.url_encode64()

      argv = [
        "setsid",
        "--fork",
        "flock",
        "--nonblock",
        db <> ".executor-lock",
        script,
        "__session-worker",
        encoded
      ]

      env = opts[:env] || %{}

      {_out, 0} =
        System.cmd(
          "sh",
          ["-c", "exec \"$@\" </dev/null >>\"$OMUNCULUS_EXECUTOR_LOG\" 2>&1", "omunculus" | argv],
          env: Map.to_list(Map.put(env, "OMUNCULUS_EXECUTOR_LOG", db <> ".executor.log"))
        )
    end

    with :ok <- await_ready(ready, System.monotonic_time(:millisecond) + 15_000) do
      EventCore.start_link(path: db, poll_ms: 100)
    end
  end

  def worker(encoded) do
    args = encoded |> Base.url_decode64!() |> Jason.decode!()

    opts = [
      db: args["db"],
      cwd: args["cwd"] || File.cwd!(),
      config_file: args["config_file"],
      env: System.get_env()
    ]

    opts = if args["provider"], do: Keyword.put(opts, :provider, args["provider"]), else: opts
    {:ok, owner} = ensure_started(opts)
    ready = args["db"] <> ".executor-ready"
    File.write!(ready, Jason.encode!(%{pid: System.pid(), start: process_start(System.pid())}))
    ref = Process.monitor(owner)

    receive do
      {:DOWN, ^ref, _, _, _} -> File.rm(ready)
    end

    1
  end

  defp process_start(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        stat |> String.split(") ", parts: 2) |> List.last() |> String.split() |> Enum.at(19)

      _ ->
        nil
    end
  end

  defp ready?(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"pid" => pid, "start" => start}} <- Jason.decode(body),
         true <- is_binary(pid) and Regex.match?(~r/^\d+$/, pid),
         true <- is_binary(start) do
      process_start(pid) == start
    else
      _ -> false
    end
  end

  defp await_ready(path, deadline) do
    cond do
      ready?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :executor_start_timeout}

      true ->
        Process.sleep(25)
        await_ready(path, deadline)
    end
  end
end
