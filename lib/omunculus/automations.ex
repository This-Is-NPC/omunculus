defmodule Omunculus.Automations do
  @moduledoc """
  External, asynchronous consumers configured as `[[automations]]`
  (docs/to-be/event-catalog.md).

  Each automation has its own cursor in `PROJECTION_CURSORS`
  (`automation:<name>`), advanced after the script returns, so delivery is
  at-least-once and the script must be idempotent by `event_id`. A non-zero
  exit is logged and the cursor still advances: an external script never gets
  veto power over the harness. The envelope reaches the script as JSON in
  `OMUNCULUS_ENVELOPE`.
  """

  use GenServer

  require Logger

  alias Omunculus.EventCore
  alias Omunculus.EventCore.Store
  alias Omunculus.Event.Envelope

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Block until every committed event has been offered to every automation."
  def sync(automations), do: GenServer.call(automations, :sync, :infinity)

  @doc "Per-automation counters: delivered, failed."
  def stats(automations), do: GenServer.call(automations, :stats, :infinity)

  @impl true
  def init(opts) do
    core = Keyword.fetch!(opts, :core)
    automations = Keyword.get(opts, :automations, [])
    :ok = EventCore.subscribe(core)

    state = %{
      core: core,
      automations: automations,
      db: EventCore.path(core),
      stats: Map.new(automations, &{&1.name, %{delivered: 0, failed: 0}})
    }

    {:ok, state, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state), do: {:noreply, catch_up(state)}

  @impl true
  def handle_info({:event_core, _env}, state), do: {:noreply, catch_up(state)}

  @impl true
  def handle_call(:sync, _from, state) do
    state = catch_up(state)
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  defp catch_up(state) do
    Enum.reduce(state.automations, state, fn automation, state ->
      cursor = read_cursor(state.core, automation.name)

      state.core
      |> EventCore.stream(cursor)
      |> Enum.reduce(state, fn env, state ->
        state =
          if env.type in automation.events, do: run(state, automation, env), else: state

        set_cursor(state.core, automation.name, env.sequence)
        state
      end)
    end)
  end

  defp run(state, automation, env) do
    json = Jason.encode!(Envelope.to_map(env))

    env_vars = [
      {"OMUNCULUS_ENVELOPE", json},
      {"OMUNCULUS_EVENT_TYPE", env.type},
      {"OMUNCULUS_EVENT_ID", env.event_id},
      {"OMUNCULUS_SEQUENCE", Integer.to_string(env.sequence)},
      {"OMUNCULUS_DB", state.db}
    ]

    outcome =
      try do
        case System.cmd("sh", ["-c", automation.run], env: env_vars, stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, status} -> {:error, {:exit, status, out}}
        end
      rescue
        e -> {:error, e}
      end

    key = if outcome == :ok, do: :delivered, else: :failed

    if outcome != :ok do
      Logger.warning(
        "automation #{automation.name} failed on #{env.type} #{env.event_id}: #{inspect(outcome)}"
      )
    end

    update_in(state.stats[automation.name][key], &(&1 + 1))
  end

  defp read_cursor(core, name) do
    case EventCore.query(
           core,
           "SELECT last_sequence FROM PROJECTION_CURSORS WHERE projection = ?",
           [
             "automation:" <> name
           ]
         ) do
      [[n]] -> n
      [] -> 0
    end
  end

  defp set_cursor(core, name, seq) do
    {:ok, _} =
      EventCore.transaction(core, fn conn ->
        Store.query(
          conn,
          "INSERT INTO PROJECTION_CURSORS (projection, last_sequence) VALUES (?, ?) ON CONFLICT(projection) DO UPDATE SET last_sequence = excluded.last_sequence",
          ["automation:" <> name, seq]
        )
      end)
  end
end
