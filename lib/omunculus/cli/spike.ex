defmodule Omunculus.CLI.Spike do
  @moduledoc """
  `omunculus spike`: run the planned Event Core end to end.

  The command enters as a `task.requested` envelope, Runs are activated from
  delivered events, every tool call and delegation round-trips through
  `EVENTS`, and the CLI only ever shows durable state: the ordered log, the
  projections, and a replay check. `--fail-at n` kills the counting worker
  after it reaches `n` and resumes the work item as a new attempt.
  """

  alias Omunculus.CLI.Help
  alias Omunculus.{Automations, Config, Runner}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  def run(%{args: args, flags: flags}, env \\ %{}) do
    with {:ok, depth} <- parse_nonneg(flags["depth"] || "1", :depth),
         {:ok, fail_at} <- parse_optional_positive(flags["fail_at"], :fail_at),
         {:ok, delay_ms} <- parse_duration(flags["delay"]),
         {:ok, config} <- Config.load(cwd: File.cwd!(), config_file: flags["config"], env: env),
         {:ok, checked} <- Config.check(config),
         {:ok, chat} <- provider_chat(config, flags, env) do
      db = flags["db"] || default_db()
      instruction = args.instruction

      {:ok, core} = EventCore.start_link(path: db, interceptors: checked.interceptors)
      {:ok, projector} = Projector.start_link(core: core)

      automations =
        if checked.automations != [] do
          {:ok, pid} = Automations.start_link(core: core, automations: checked.automations)
          pid
        end

      {:ok, runtime} =
        Runtime.start_link(
          core: core,
          max_depth: depth,
          agents: SpikeAgents.resolver(delay_ms: delay_ms, chat: chat),
          run_opts: [delegation_timeout: 600_000]
        )

      outcome = execute(core, runtime, instruction, depth, fail_at)
      :ok = Projector.sync(projector)

      code =
        case outcome do
          {:ok, %{result: result, requested: requested}} ->
            report(core, projector, requested.correlation_id, db, flags["json_events"] || false)
            report_lanes(core, automations, checked, flags["json_events"] || false)
            IO.puts(result)
            0

          {:error, reason} ->
            IO.puts(:stderr, "error: spike failed: #{inspect(reason)}")
            report(core, projector, nil, db, flags["json_events"] || false)
            report_lanes(core, automations, checked, flags["json_events"] || false)
            1
        end

      if automations, do: Automations.sync(automations)
      if automations, do: GenServer.stop(automations)
      GenServer.stop(runtime)
      GenServer.stop(projector)
      GenServer.stop(core)
      code
    else
      {:error, reason} ->
        IO.puts(:stderr, Help.usage_error(reason))
        2
    end
  end

  defp report_lanes(_core, _automations, _checked, true), do: :ok

  defp report_lanes(core, automations, checked, false) do
    if checked.interceptors != [] do
      stats = EventCore.interceptor_stats(core)

      Enum.each(checked.interceptors, fn i ->
        s = stats[i.name]

        IO.puts(
          :stderr,
          "interceptor #{i.name} on #{Enum.join(i.events, ",")}: evaluated=#{s.evaluated} delivered=#{s.delivered} rejected=#{s.rejected}"
        )
      end)
    else
      IO.puts(
        :stderr,
        "interceptor: none configured, deliveries went directly from the Event Core"
      )
    end

    if automations do
      Automations.sync(automations)

      Enum.each(Automations.stats(automations), fn {name, s} ->
        IO.puts(:stderr, "automation #{name}: delivered=#{s.delivered} failed=#{s.failed}")
      end)
    end
  end

  # --- execution --------------------------------------------------------------------

  defp execute(core, _runtime, instruction, _depth, nil) do
    Runtime.request(core, instruction, idempotency_key: "spike:" <> instruction, timeout: 600_000)
  end

  defp execute(core, runtime, instruction, depth, fail_at) do
    correlation_id = Envelope.generate_id("corr")
    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    task =
      Task.async(fn ->
        Runtime.request(core, instruction, correlation_id: correlation_id, timeout: 60_000)
      end)

    with {:ok, at} <-
           await(fn
             %Envelope{type: "tool.call.completed", payload: %{"new" => ^fail_at}} = env -> env
             _ -> nil
           end),
         {_id, worker} <- find_run(runtime, depth),
         true <- Process.exit(worker.pid, :kill),
         {:ok, failed} <-
           await(fn
             %Envelope{type: "run.failed", work_item_id: wid} = env when wid == at.work_item_id ->
               env

             _ ->
               nil
           end),
         {:ok, _} <-
           Runtime.resume(core, at.work_item_id,
             correlation_id: correlation_id,
             causation_id: failed.event_id,
             reason: "spike --fail-at #{fail_at}"
           ) do
      Task.await(task, 65_000)
    else
      nil -> {:error, :worker_not_found}
      other -> other
    end
  end

  defp await(match, timeout \\ 10_000) do
    receive do
      {:event_core, env} ->
        case match.(env) do
          nil -> await(match, timeout)
          found -> {:ok, found}
        end
    after
      timeout -> {:error, :timeout_waiting_for_event}
    end
  end

  defp find_run(runtime, depth) do
    runtime |> Runtime.runs() |> Enum.find(fn {_, r} -> r.depth == depth end)
  end

  # --- report ---------------------------------------------------------------------------

  defp report(core, projector, correlation_id, db, json?) do
    events =
      if correlation_id,
        do: EventCore.stream(core, 0, correlation_id: correlation_id),
        else: EventCore.stream(core, 0)

    if json? do
      Enum.each(events, &IO.puts(:stderr, Jason.encode!(Envelope.to_map(&1))))
    else
      IO.puts(:stderr, "EVENTS (#{length(events)} envelopes, correlation #{correlation_id})")
      Enum.each(events, &IO.puts(:stderr, "  " <> line(&1)))
    end

    before = Projector.snapshot(core)
    :ok = Projector.rebuild(projector)
    replay_ok? = Projector.snapshot(core) == before

    unless json? do
      IO.puts(:stderr, "")
      IO.puts(:stderr, "ARCHIVE_RUNS")

      core
      |> EventCore.query(
        "SELECT depth, attempt, agent_kind, status, run_id, parent_run_id FROM ARCHIVE_RUNS ORDER BY started_at"
      )
      |> Enum.each(fn [depth, attempt, kind, status, run_id, parent] ->
        IO.puts(
          :stderr,
          "  depth=#{depth} attempt=#{attempt} #{kind} #{status} #{run_id}#{if parent, do: " parent=" <> parent, else: ""}"
        )
      end)

      IO.puts(:stderr, "WORK_ITEMS")

      core
      |> EventCore.query(
        "SELECT work_item_id, status, result, checkpoint FROM WORK_ITEMS ORDER BY created_at"
      )
      |> Enum.each(fn [id, status, result, checkpoint] ->
        IO.puts(:stderr, "  #{id} #{status} result=#{inspect(result)} checkpoint=#{checkpoint}")
      end)

      IO.puts(:stderr, "")

      IO.puts(
        :stderr,
        "replay: projections rebuilt from EVENTS #{if replay_ok?, do: "identically", else: "WITH DIFFERENCES"}"
      )

      IO.puts(:stderr, "db: #{db}")
    end
  end

  defp line(env) do
    depth =
      case env.payload do
        %{"depth" => d} -> " depth=#{d}"
        %{"to_depth" => d} -> " to_depth=#{d}"
        _ -> ""
      end

    detail =
      case env.type do
        "tool.call.completed" ->
          " #{env.payload["tool"]} #{env.payload["previous"]}->#{env.payload["new"]}"

        "tool.call.requested" ->
          " #{env.payload["tool"]} round=#{env.payload["round"]}"

        "task.completed" ->
          " result=#{inspect(env.payload["result"])}"

        "run.started" ->
          " attempt=#{env.payload["attempt"]} #{env.payload["agent_id"]}"

        "run.failed" ->
          " #{env.payload["reason"]}"

        _ ->
          ""
      end

    String.pad_leading(Integer.to_string(env.sequence), 4) <>
      "  " <>
      String.pad_trailing("#{env.kind}", 8) <>
      String.pad_trailing(env.type, 22) <>
      "#{env.event_id} <- #{env.causation_id || "-"}" <> depth <> detail
  end

  # --- provider -----------------------------------------------------------------------------

  # --provider fake keeps the scripted Chat.Fake even when a config file is
  # given (the file then only supplies interceptors and automations).
  # --provider chat builds a real OpenAI-compatible chat through the same
  # Config/Runner path as `run`; every node shares it and Agent config stays
  # generic, only kind/tools/prompt differ per depth.
  defp provider_chat(config, flags, env) do
    case flags["provider"] || "fake" do
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

  # --- parsing ------------------------------------------------------------------------------

  defp default_db do
    Path.join(System.tmp_dir!(), "omunculus-spike-#{System.unique_integer([:positive])}.sqlite3")
  end

  defp parse_nonneg(raw, flag) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_flag_value, "--#{flag}", raw}}
    end
  end

  defp parse_optional_positive(nil, _flag), do: {:ok, nil}

  defp parse_optional_positive(raw, flag) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_flag_value, "--#{flag}", raw}}
    end
  end

  defp parse_duration(nil), do: {:ok, 0}

  defp parse_duration(raw) do
    case Regex.run(~r/^(\d+)(ms|s)?$/, raw) do
      [_, value, "ms"] -> {:ok, String.to_integer(value)}
      [_, value, _] -> {:ok, String.to_integer(value) * 1_000}
      _ -> {:error, {:invalid_delay, raw}}
    end
  end
end
