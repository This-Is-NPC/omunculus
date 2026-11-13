defmodule Omunculus.Jobs.Scheduler do
  @moduledoc """
  The scheduler of one project, a process of the server that owns it. Every
  second it asks `plan/3` what to do and starts a process for each fire that
  may begin; the fires run at once, as many as `[jobs] max_parallel` allows.

  `plan/3` is the whole decision, given the time `now`, so a test drives it
  with any clock and no waiting. In order it

  1. at the server's start only (`boot?`), fails the fires a stopped server
     left `running`, and applies `[jobs] missed` to the slots that passed
     while it was down: `skip` records each as `missed`, `run_once` records
     all but the latest as `missed` and runs that one;
  2. claims every slot of an active job that has come (`Omunculus.Jobs.due/2`)
     as a `due` fire;
  3. moves the active jobs whose end date has passed to `ended`;
  4. goes through the fires still `due` or `late`, oldest first: a fire of a
     job paused since is `cancelled`; one not started within
     `[jobs] lateness_seconds` of its slot is marked `late` and its owner told;
     one that finds the project at `max_parallel` waits; one whose condition
     says no is `skipped` (and the job paused when the condition says its
     entitlement is gone); every other is recorded `running` and returned.
  """

  use GenServer

  require Logger

  alias Omunculus.{Config, Jobs}
  alias Omunculus.Jobs.{Fire, Notice}
  alias Omunculus.Server.Project, as: Served

  # The scheduler looks at the clock this often; schedules are to the minute.
  @tick_ms 1_000

  @spec start_link({String.t(), keyword}) :: GenServer.on_start()
  def start_link({id, opts}), do: GenServer.start_link(__MODULE__, {id, opts})

  @impl true
  def init({id, opts}) do
    send(self(), :tick)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {:ok, %{id: id, clock: clock, boot?: true, fires: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    project = Served.project(state.id)

    fires =
      case plan(project, state.clock.(), state.boot?) do
        {:ok, started} ->
          Enum.reduce(started, state.fires, &start(project, &1, &2))

        {:error, reason} ->
          Logger.error("jobs of #{state.id}: #{inspect(reason)}")
          state.fires
      end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | boot?: false, fires: fires}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {fire, fires} = Map.pop(state.fires, ref)

    if fire && reason != :normal do
      project = Served.project(state.id)

      Jobs.record_fire(project.conn, fire.job["id"], %{
        "fire_id" => fire.fire["fire_id"],
        "state" => "failed",
        "reason" => "the fire stopped: #{inspect(reason)}"
      })
    end

    {:noreply, %{state | fires: fires}}
  end

  defp start(project, %{job: job, fire: fire} = started, fires) do
    {_pid, ref} =
      spawn_monitor(fn ->
        with {:error, reason} <- Fire.run(project, job, fire), do: exit({:fire, reason})
      end)

    Map.put(fires, ref, started)
  end

  @doc """
  What to do at `now`; the fires to start, each `%{job: job, fire: fire}`
  already recorded `running`. `boot?` is true for the first call after the
  server starts.
  """
  @spec plan(Omunculus.Project.t(), DateTime.t(), boolean) :: {:ok, [map]} | {:error, term}
  def plan(project, now, boot? \\ false) do
    with {:ok, config} <- Config.load(project.config_path) do
      case config.jobs do
        nil -> {:ok, []}
        policy -> plan(project, config, policy, now, boot?)
      end
    end
  end

  defp plan(project, config, policy, now, boot?) do
    conn = project.conn

    with :ok <- if(boot?, do: abandon(project, config), else: :ok),
         {:ok, exempt} <- claim(conn, policy, now, boot?),
         :ok <- finish_ended(conn, now),
         {:ok, pending} <- Jobs.pending(conn) do
      running = Enum.count(pending, &(&1["state"] == "running"))
      begin(project, policy, now, exempt, pending, running)
    end
  end

  # A server that stopped left its running fires without a process.
  defp abandon(project, config) do
    with {:ok, pending} <- Jobs.pending(project.conn) do
      pending
      |> Enum.filter(&(&1["state"] == "running"))
      |> each(fn fire ->
        with {:ok, _fire} <-
               Jobs.record_fire(project.conn, fire["id"], %{
                 "fire_id" => fire["fire_id"],
                 "state" => "failed",
                 "reason" => "the server stopped while the fire ran"
               }),
             do: Fire.pause_after_failures(project, config, fire["id"])
      end)
    end
  end

  defp claim(conn, policy, now, boot?) do
    with {:ok, due} <- Jobs.due(conn, now) do
      Enum.reduce_while(due, {:ok, MapSet.new()}, fn %{job: job, slots: slots}, {:ok, exempt} ->
        case claim_job(conn, policy, now, boot?, job, Enum.to_list(slots)) do
          {:ok, ids} -> {:cont, {:ok, MapSet.union(exempt, MapSet.new(ids))}}
          error -> {:halt, error}
        end
      end)
    end
  end

  # At the start, the slots that came more than the lateness ago passed while
  # the server was down. Gives the ids of the fires `run_once` lets through.
  defp claim_job(conn, policy, now, boot?, job, slots) do
    {passed, current} =
      if boot?, do: Enum.split_with(slots, &overdue?(&1, now, policy)), else: {[], slots}

    {missed, once} =
      case {policy.missed, passed} do
        {_policy, []} -> {[], []}
        {"skip", passed} -> {passed, []}
        {"run_once", passed} -> {Enum.drop(passed, -1), [List.last(passed)]}
      end

    with :ok <-
           each(missed, fn slot ->
             with {:ok, fire} <- slot_fire(conn, job, slot),
                  {:ok, _fire} <-
                    Jobs.record_fire(conn, job["id"], %{
                      "fire_id" => fire["fire_id"],
                      "state" => "missed",
                      "reason" => "the server was down"
                    }),
                  do: :ok
           end),
         :ok <- each(current, &with({:ok, _fire} <- slot_fire(conn, job, &1), do: :ok)) do
      collect(once, fn slot ->
        with {:ok, fire} <- slot_fire(conn, job, slot), do: {:ok, fire["fire_id"]}
      end)
    end
  end

  defp slot_fire(conn, job, slot),
    do:
      Jobs.record_fire(conn, job["id"], %{
        "state" => "due",
        "scheduled_for" => DateTime.to_iso8601(slot)
      })

  defp overdue?(slot, now, policy), do: DateTime.diff(now, slot) > policy.lateness_seconds

  defp finish_ended(conn, now) do
    with {:ok, jobs} <- Jobs.list(conn) do
      jobs
      |> Enum.filter(&(&1["state"] == "active" and ended?(&1["end_at"], now)))
      |> each(fn job ->
        with {:ok, _event} <- Jobs.transition(conn, job["id"], "ended", "the end date passed"),
             do: :ok
      end)
    end
  end

  defp ended?(nil, _now), do: false

  defp ended?(end_at, now) do
    {:ok, instant, _offset} = DateTime.from_iso8601(end_at)
    DateTime.compare(instant, now) != :gt
  end

  defp begin(project, policy, now, exempt, pending, running) do
    pending
    |> Enum.filter(&(&1["state"] in ~w(due late)))
    |> Enum.reduce_while({:ok, running, []}, fn fire, {:ok, running, started} ->
      case consider(project, policy, now, exempt, fire, running) do
        {:ok, :held} ->
          {:cont, {:ok, running, started}}

        {:ok, :finished} ->
          {:cont, {:ok, running, started}}

        {:ok, {:started, job, running_fire}} ->
          {:cont, {:ok, running + 1, started ++ [%{job: job, fire: running_fire}]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _running, started} -> {:ok, started}
      error -> error
    end
  end

  defp consider(project, policy, now, exempt, fire, running) do
    conn = project.conn

    with {:ok, job} <- Jobs.get(conn, fire["id"]) do
      cond do
        fire["manual"] != true and job["state"] in ~w(paused archived) ->
          finish(conn, fire, "cancelled", "the job was #{job["state"]}")

        fire["state"] == "due" and not MapSet.member?(exempt, fire["fire_id"]) and
            overdue?(DateTime.from_iso8601(fire["scheduled_for"]) |> elem(1), now, policy) ->
          with {:ok, late} <- mark_late(project, job, fire, policy) do
            consider(project, policy, now, exempt, late, running)
          end

        running >= policy.max_parallel ->
          {:ok, :held}

        true ->
          gate(project, job, fire)
      end
    end
  end

  defp finish(conn, fire, state, reason) do
    with {:ok, _fire} <-
           Jobs.record_fire(conn, fire["id"], %{
             "fire_id" => fire["fire_id"],
             "state" => state,
             "reason" => reason
           }),
         do: {:ok, :finished}
  end

  defp mark_late(project, job, fire, policy) do
    reason =
      "it did not start within #{policy.lateness_seconds} seconds of #{fire["scheduled_for"]}"

    with {:ok, late} <-
           Jobs.record_fire(project.conn, job["id"], %{
             "fire_id" => fire["fire_id"],
             "state" => "late",
             "reason" => reason
           }),
         :ok <- Notice.owner(project.conn, job, "a fire is late: #{reason}") do
      {:ok, Map.merge(fire, late)}
    end
  end

  defp gate(project, job, fire) do
    case Fire.condition(project, job) do
      :run ->
        with {:ok, running} <-
               Jobs.record_fire(project.conn, job["id"], %{
                 "fire_id" => fire["fire_id"],
                 "state" => "running"
               }),
             do: {:ok, {:started, job, Map.merge(fire, running)}}

      {:skip, reason} ->
        finish(project.conn, fire, "skipped", reason)

      {:pause, reason} ->
        with {:ok, :finished} <- finish(project.conn, fire, "skipped", reason),
             :ok <- Fire.pause(project.conn, job, reason),
             do: {:ok, :finished}
    end
  end

  defp each(list, fun),
    do: collect(list, fn item -> with :ok <- fun.(item), do: {:ok, nil} end) |> ok()

  defp ok({:ok, _values}), do: :ok
  defp ok(error), do: error

  defp collect(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end
end
