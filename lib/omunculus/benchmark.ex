defmodule Omunculus.Benchmark do
  @moduledoc """
  Measures concurrent work in the current BEAM runtime.

  `:actor_density` is deliberately provider-free: agents build their state and
  tool schemas, report `round_started`, and wait at an internal latch.  This
  makes the plateau/RSS measurement independent of Finch or a provider.
  `:agent_tree` is a synthetic provider-free resident topology benchmark. It
  creates nodes by depth waves, links stable tree/path IDs, and keeps every
  ancestor blocked at the latch.
  `:http_load` sends requests to the external benchmark stub through a
  dedicated Finch pool.
  """

  alias Omunculus.{Agent, Auth, Chat, Config, FS}
  alias Omunculus.Chat.Completions
  alias Omunculus.Benchmark.Stub

  @type event :: map()
  # A mailbox full of readiness notifications must not starve RSS sampling.
  # Keep this small so a crossing is observed after a bounded number of
  # arrivals even when the mailbox never becomes empty.
  @density_sample_batch 16
  @tree_wave_chunk_size 256


  def run(opts) when is_map(opts) do
    opts = normalize(opts)
    reporter = Map.get(opts, :reporter, fn _ -> :ok end)

    with :ok <- validate(opts) do
      started = now_ms()
      emit(reporter, %{type: :benchmark_started, config: public_config(opts)})
      previous_schedulers = set_cpu_limit(opts[:cpu_limit])

      try do
        run_scenario(opts, reporter, started)
      catch
        kind, reason -> {:error, {:benchmark_crashed, kind, reason}}
      after
        restore_cpu_limit(previous_schedulers)
      end
    end
  end

  def run(opts) when is_list(opts), do: run(Map.new(opts))

  def run(opts, reporter) when is_map(opts) and is_function(reporter, 1),
    do: run(Map.put(opts, :reporter, reporter))

  defp normalize(opts) do
    opts
    |> Map.put_new(:scenario, :actor_density)
    |> Map.put_new(:provider, :stub)
    |> Map.put_new(:tools, :none)
    |> Map.put_new(:rounds, 1)
    |> Map.put_new(:stub_delay_ms, 0)
    |> Map.put_new(:payload_bytes, 0)
    |> Map.put_new(:sample_ms, 100)
    |> Map.put_new(:step, nil)
    |> Map.put_new(:cwd, File.cwd!())
    |> Map.put_new(:max_agents, nil)
    |> Map.put_new(:max_trees, nil)
    |> Map.put_new(:tree_shape, [1, 1, 2, 4])
    |> Map.put_new(:tree_mode, :resident)
    |> Map.put_new(:memory_limit, nil)
    |> Map.put_new(:cpu_limit, nil)
    |> Map.put_new(:http_concurrency, 1)
    |> Map.update!(:scenario, &to_atom/1)
    |> Map.update!(:provider, &to_atom/1)
    |> Map.update!(:tree_mode, &to_atom/1)
    |> Map.update!(:tree_shape, &normalize_shape/1)
    |> Map.update!(:tools, &normalize_tools/1)
  end

  defp validate(opts) do
    cond do
      opts[:scenario] == :agent_tree and is_nil(opts[:max_trees]) and
          is_nil(opts[:memory_limit]) ->
        {:error, {:usage, :benchmark_tree_limit_required}}

      opts[:scenario] != :agent_tree and is_nil(opts[:max_agents]) and
          is_nil(opts[:memory_limit]) ->
        {:error, {:usage, :benchmark_limit_required}}

      opts[:scenario] not in [:actor_density, :http_load, :agent_tree] ->
        {:error, {:usage, {:invalid_scenario, opts[:scenario]}}}

      opts[:scenario] == :agent_tree and opts[:tree_mode] != :resident ->
        {:error, {:usage, {:invalid_tree_mode, opts[:tree_mode]}}}

      opts[:scenario] == :agent_tree and not valid_shape?(opts[:tree_shape]) ->
        {:error, {:usage, {:invalid_tree_shape, opts[:tree_shape]}}}

      not is_nil(opts[:max_agents]) and not positive?(opts[:max_agents]) ->
        {:error, {:usage, {:invalid_max_agents, opts[:max_agents]}}}

      not is_nil(opts[:max_trees]) and not positive?(opts[:max_trees]) ->
        {:error, {:usage, {:invalid_max_trees, opts[:max_trees]}}}

      not is_nil(opts[:memory_limit]) and not positive?(opts[:memory_limit]) ->
        {:error, {:usage, {:invalid_memory_limit, opts[:memory_limit]}}}

      opts[:provider] not in [:stub, :real] ->
        {:error, {:usage, {:invalid_provider, opts[:provider]}}}

      opts[:scenario] == :http_load and opts[:provider] == :real ->
        {:error, {:usage, {:provider_not_supported, :real, :http_load}}}

      opts[:tools] not in [[], ["counter"]] ->
        {:error, {:usage, {:invalid_tools, opts[:tools]}}}

      not positive?(opts[:rounds]) ->
        {:error, {:usage, {:invalid_rounds, opts[:rounds]}}}

      not nonnegative?(opts[:stub_delay_ms]) ->
        {:error, {:usage, {:invalid_stub_delay, opts[:stub_delay_ms]}}}

      not nonnegative?(opts[:payload_bytes]) ->
        {:error, {:usage, {:invalid_payload_bytes, opts[:payload_bytes]}}}

      not positive?(opts[:sample_ms]) ->
        {:error, {:usage, {:invalid_sample_ms, opts[:sample_ms]}}}

      not is_nil(opts[:step]) and not positive?(opts[:step]) ->
        {:error, {:usage, {:invalid_step, opts[:step]}}}

      not positive?(opts[:http_concurrency]) ->
        {:error, {:usage, {:invalid_http_concurrency, opts[:http_concurrency]}}}

      not is_nil(opts[:cpu_limit]) and
          (not positive?(opts[:cpu_limit]) or opts[:cpu_limit] > System.schedulers_online()) ->
        {:error, {:usage, {:invalid_cpu_limit, opts[:cpu_limit], System.schedulers_online()}}}

      true ->
        :ok
    end
  end

  defp normalize_shape(shape) when is_binary(shape),
    do: String.split(shape, ",", trim: false) |> normalize_shape()

  defp normalize_shape(shape) when is_list(shape) do
    Enum.map(shape, fn
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {number, ""} -> number
          _ -> value
        end

      value ->
        value
    end)
  end

  defp valid_shape?(shape) when is_list(shape) and shape != [] do
    hd(shape) == 1 and
      Enum.all?(shape, &positive?/1) and
      Enum.chunk_every(shape, 2, 1, :discard)
      |> Enum.all?(fn [previous, width] -> rem(width, previous) == 0 end)
  end

  defp valid_shape?(_), do: false

  defp run_scenario(%{scenario: :agent_tree} = opts, reporter, started),
    do: execute_tree(opts, reporter, started)

  defp run_scenario(%{scenario: :actor_density, provider: :real} = opts, reporter, started) do
    # Resolve the explicit real provider for configuration/auth errors, but
    # never issue a request in actor-density.
    with {:ok, provider} <- start_provider(opts) do
      try do
        execute_density(opts, reporter, started)
      after
        stop_provider(provider)
      end
    end
  end

  defp run_scenario(%{scenario: :actor_density} = opts, reporter, started),
    do: execute_density(opts, reporter, started)

  defp run_scenario(%{scenario: :http_load} = opts, reporter, started),
    do: execute_http(opts, reporter, started)

  defp execute_density(opts, reporter, started) do
    baseline = metrics(opts, 0, 0, 0, 0, nil, 0, 0)
    emit(reporter, %{type: :sample, metrics: baseline})
    targets = targets(opts)
    state = run_levels(opts, reporter, targets, baseline, :actor_density)
    summary = finish_summary(opts, state, baseline)
    result = %{summary: summary, duration_ms: now_ms() - started}
    emit(reporter, %{type: :benchmark_finished, summary: result})
    maybe_write_json(opts[:json], result)
    {:ok, result}
  end

  defp execute_tree(opts, reporter, started) do
    baseline = metrics(opts, 0, 0, 0, 0, nil, 0, 0)
    emit(reporter, %{type: :sample, metrics: baseline})
    state = run_tree_levels(opts, reporter, tree_targets(opts), baseline)
    summary = finish_tree_summary(opts, state, baseline)
    result = %{summary: summary, duration_ms: now_ms() - started}
    emit(reporter, %{type: :benchmark_finished, summary: result})
    maybe_write_json(opts[:json], result)
    {:ok, result}
  end

  defp run_tree_levels(opts, reporter, targets, baseline) do
    Enum.reduce_while(
      targets,
      %{
        max_good_trees: 0,
        peak: baseline,
        summaries: [],
        ready: 0,
        active_peak: 0,
        failed: 0,
        over: false,
        stop_reason: nil
      },
      fn target, acc ->
        emit(reporter, %{type: :level_started, target: target})
        level = run_tree_level(opts, reporter, target, baseline)
        emit(reporter, %{type: :level_finished, summary: level.summary})

        acc = %{
          acc
          | peak: max_metrics(acc.peak, level.peak),
            summaries: [level.summary | acc.summaries],
            ready: level.ready,
            active_peak: max(acc.active_peak, level.active_peak),
            failed: level.summary.failed,
            over: level.summary.over
        }

        if level.good? do
          {:cont, %{acc | max_good_trees: target}}
        else
          {:halt, %{acc | stop_reason: level.stop_reason}}
        end
      end
    )
  end

  defp run_tree_level(opts, reporter, target, baseline) do
    if over_limit?(opts, baseline) do
      tree_result(opts, reporter, target, baseline, empty_tree_state(baseline), :memory_limit)
    else
      parent = self()
      {:ok, supervisor} = Task.Supervisor.start_link()
      chat = Omunculus.Chat.Fake.new([%{content: "benchmark", tool_calls: [], usage: nil}])
      initial = empty_tree_state(baseline)

      outcome =
        try do
          run_tree_waves(opts, reporter, parent, supervisor, chat, target, initial)
        after
          :ok
        end

      state =
        case outcome do
          {:ok, state} -> state
          {:stop, state, reason} -> %{state | stop_reason: reason}
        end

      Enum.each(state.tasks, fn {_id, task} ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)

      Supervisor.stop(supervisor)
      Elixir.Agent.stop(chat.pid)
      tree_result(opts, reporter, target, baseline, state, state.stop_reason)
    end
  end

  defp empty_tree_state(baseline) do
    %{
      tasks: %{},
      nodes: %{},
      ready_ids: MapSet.new(),
      failed: 0,
      active_peak: 0,
      peak: baseline,
      spawned: 0,
      edges: 0,
      depth_counts: %{},
      stop_reason: nil
    }
  end

  defp run_tree_waves(opts, reporter, parent, supervisor, chat, target, state) do
    shape = opts[:tree_shape]

    Enum.reduce_while(Enum.with_index(shape), {:ok, state}, fn {width, depth},
                                                               {:ok, state} ->
      nodes = tree_depth_nodes(target, depth, width, shape)

      Enum.reduce_while(Stream.chunk_every(nodes, @tree_wave_chunk_size), {:ok, state}, fn chunk,
                                                                                           {:ok,
                                                                                            state} ->
        case spawn_tree_wave(
               opts,
               reporter,
               parent,
               supervisor,
               chat,
               depth,
               chunk,
               state
             ) do
          {:stop, state, reason} ->
            {:halt, {:stop, state, reason}}

          {:ok, state} ->
            expected = MapSet.new(chunk, fn {id, _parent_id, _path} -> id end)

            case await_tree_wave(
                   opts,
                   reporter,
                   target,
                   supervisor,
                   state,
                   expected,
                   now_ms() + max(opts[:sample_ms], 1),
                   0
                 ) do
              {:stop, state, reason} -> {:halt, {:stop, state, reason}}
              {:ok, state} -> {:cont, {:ok, state}}
            end
        end
      end)
      |> case do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, state, reason} -> {:halt, {:stop, state, reason}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {:stop, state, reason} -> {:stop, state, reason}
    end
  end

  # Keep only one bounded chunk of topology tuples alive while a wave is
  # spawned. In particular, do not build a list containing every tree/depth
  # node before checking the RSS limit.
  defp tree_depth_nodes(trees, depth, width, shape) do
    Stream.flat_map(1..trees, fn tree ->
      Stream.map(0..(width - 1), fn index ->
        path = tree_path(tree, depth, index, shape)
        id = "tree-#{tree}/#{path}"
        parent_id = if depth == 0, do: nil, else: parent_tree_id(tree, path)
        {id, parent_id, path}
      end)
    end)
  end

  defp tree_path(_tree, 0, index, _shape), do: Integer.to_string(index)

  defp tree_path(_tree, depth, index, shape) do
    {root, segments} =
      Enum.reduce(depth..1, {index, []}, fn level, {child, segments} ->
        ratio = div(Enum.at(shape, level), Enum.at(shape, level - 1))
        {div(child, ratio), [Integer.to_string(rem(child, ratio)) | segments]}
      end)

    Enum.join([Integer.to_string(root) | segments], ".")
  end

  defp parent_tree_id(tree, path) do
    parent_path = path |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")
    "tree-#{tree}/#{parent_path}"
  end

  defp spawn_tree_wave(opts, reporter, parent, supervisor, chat, depth, nodes, state) do
    Enum.reduce_while(nodes, {:ok, state}, fn {id, parent_id, path}, {:ok, state} ->
      # Check before allocating the task and node metadata, then sample again
      # after each allocation so a low RSS ceiling cannot force a full wave.
      state = sample_tree(opts, reporter, state)

      if over_limit?(opts, state.peak) do
        {:halt, {:stop, state, :memory_limit}}
      else
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:benchmark_agent, id, :started, now_ms()})

            latch = fn event ->
              if event[:type] == :round_started do
                send(parent, {:benchmark_agent, id, :ready, now_ms(), event[:round]})

                receive do
                  {:benchmark_release, ^id} -> :ok
                end
              end

              :ok
            end

            outcome =
              Agent.run(
                instruction: payload(opts[:payload_bytes]),
                chat: chat,
                fs: FS.Memory.new(),
                tools: opts[:tools],
                max_turns: opts[:rounds],
                tool_options: %{tools: %{"counter" => %{increment: 1}}},
                reporter: latch
              )

            send(parent, {:benchmark_agent, id, :done, outcome})
            :ok
          end)

        nodes_map =
          Map.put(state.nodes, id, %{
            id: id,
            parent_id: parent_id,
            depth: depth,
            path: path
          })

        state = %{
          state
          | tasks: Map.put(state.tasks, id, task),
            nodes: nodes_map,
            spawned: state.spawned + 1,
            edges: state.edges + if(is_nil(parent_id), do: 0, else: 1),
            depth_counts: Map.update(state.depth_counts, depth, 1, &(&1 + 1))
        }

        state = sample_tree(opts, reporter, state)

        if over_limit?(opts, state.peak),
          do: {:halt, {:stop, state, :memory_limit}},
          else: {:cont, {:ok, state}}
      end
    end)
  end

  defp sample_tree(opts, reporter, state) do
    sample =
      metrics(
        opts,
        MapSet.size(state.ready_ids),
        0,
        state.failed,
        0,
        nil,
        MapSet.size(state.ready_ids),
        state.active_peak
      )

    emit(reporter, %{type: :sample, metrics: sample})
    %{state | peak: max_metrics(state.peak, sample)}
  end


  defp await_tree_wave(opts, reporter, target, supervisor, state, expected, deadline, arrivals) do
    ready = MapSet.intersection(state.ready_ids, expected)

    cond do
      state.failed > 0 ->
        {:stop, state, :agent_crash}

      MapSet.size(ready) == MapSet.size(expected) ->
        {:ok, state}

      arrivals >= @density_sample_batch or now_ms() >= deadline ->
        sample =
          metrics(
            opts,
            MapSet.size(state.ready_ids),
            0,
            state.failed,
            max(target * Enum.sum(opts[:tree_shape]) - state.spawned, 0),
            nil,
            MapSet.size(state.ready_ids),
            state.active_peak
          )

        emit(reporter, %{type: :sample, metrics: sample})
        state = %{state | peak: max_metrics(state.peak, sample)}

        if over_limit?(opts, state.peak),
          do: {:stop, state, :memory_limit},
          else:
            await_tree_wave(
              opts,
              reporter,
              target,
              supervisor,
              state,
              expected,
              now_ms() + max(opts[:sample_ms], 1),
              0
            )

      true ->
        receive do
          {:benchmark_agent, id, :started, at} ->
            node = Map.fetch!(state.nodes, id)
            emit_agent(opts, reporter, id, :running, 0, at, node.parent_id, node.depth, node.path)

            await_tree_wave(
              opts,
              reporter,
              target,
              supervisor,
              state,
              expected,
              deadline,
              arrivals
            )

          {:benchmark_agent, id, :ready, at, round} ->
            node = Map.fetch!(state.nodes, id)
            ready_ids = MapSet.put(state.ready_ids, id)
            active_peak = max(state.active_peak, MapSet.size(ready_ids))

            emit_agent(
              opts,
              reporter,
              id,
              :waiting_ai,
              round,
              at,
              node.parent_id,
              node.depth,
              node.path
            )

            await_tree_wave(
              opts,
              reporter,
              target,
              supervisor,
              %{state | ready_ids: ready_ids, active_peak: active_peak},
              expected,
              deadline,
              arrivals + 1
            )

          {:benchmark_agent, id, :done, _result} ->
            node = Map.fetch!(state.nodes, id)

            emit_agent(
              opts,
              reporter,
              id,
              :completed,
              0,
              now_ms(),
              node.parent_id,
              node.depth,
              node.path
            )

            await_tree_wave(
              opts,
              reporter,
              target,
              supervisor,
              state,
              expected,
              deadline,
              arrivals
            )

          {:DOWN, ref, :process, _pid, reason} ->
            failed =
              case Enum.find(state.tasks, fn {_id, task} -> task.ref == ref end) do
                nil -> state.failed
                _ when reason in [:normal, :shutdown] -> state.failed
                _ -> state.failed + 1
              end

            await_tree_wave(
              opts,
              reporter,
              target,
              supervisor,
              %{state | failed: failed},
              expected,
              deadline,
              arrivals
            )
        after
          max(deadline - now_ms(), 0) ->
            await_tree_wave(
              opts,
              reporter,
              target,
              supervisor,
              state,
              expected,
              deadline,
              arrivals
            )
        end
    end
  end

  defp tree_result(opts, _reporter, target, baseline, state, reason) do
    total_per_tree = Enum.sum(opts[:tree_shape])
    expected = target * total_per_tree
    nodes = state.spawned
    ready = MapSet.size(state.ready_ids)
    over = reason == :memory_limit or over_limit?(opts, state.peak)

    good =
      nodes == expected and ready == expected and state.active_peak == expected and
        state.failed == 0 and not over

    summary = %{
      scenario: :agent_tree,
      synthetic: true,
      tree_mode: opts[:tree_mode],
      tree_shape: opts[:tree_shape],
      trees: target,
      target: target,
      nodes: nodes,
      edges: state.edges,
      # Resident mode executes synthetic agent nodes directly. It does not
      # create durable Work Items/Runs, so only the to-be durable cardinality
      # is reported as an explicitly expected, not observed, value.
      agent_executions: nodes,
      durable_runs_observed: 0,
      to_be_runs_expected: target * runs_per_tree(opts[:tree_shape]),
      max_depth: length(opts[:tree_shape]) - 1,
      depth_counts: depth_counts(state.depth_counts, opts[:tree_shape]),
      ready: ready,
      active_peak: state.active_peak,
      baseline: baseline,
      peak: state.peak,
      completed: if(good, do: nodes, else: 0),
      failed: state.failed,
      over: over,
      over_limit?: over,
      valid?: good
    }

    %{
      summary: summary,
      peak: state.peak,
      ready: ready,
      active_peak: state.active_peak,
      good?: good,
      stop_reason: reason || if(good, do: nil, else: :agent_crash)
    }
  end

  defp depth_counts(counts, shape),
    do: Enum.map(0..(length(shape) - 1), &Map.get(counts, &1, 0))

  defp runs_per_tree(shape), do: Enum.sum(shape) + Enum.sum(Enum.drop(shape, -1))


  defp execute_http(opts, reporter, started) do
    case Stub.start(
           delay_ms: opts[:stub_delay_ms],
           rounds: opts[:rounds],
           payload_bytes: opts[:payload_bytes],
           barrier_timeout_ms: max(opts[:sample_ms] * 10, 1_000)
         ) do
      {:ok, stub} ->
        case start_finch(opts[:http_concurrency]) do
          {:ok, finch} ->
            try do
              baseline = metrics(opts, 0, 0, 0, 0, 0, 0, 0)
              emit(reporter, %{type: :sample, metrics: baseline})

              state =
                run_levels(opts, reporter, targets(opts), baseline, {:http_load, stub, finch})

              summary = finish_summary(opts, state, baseline)
              result = %{summary: summary, duration_ms: now_ms() - started}
              emit(reporter, %{type: :benchmark_finished, summary: result})
              maybe_write_json(opts[:json], result)
              {:ok, result}
            after
              stop_finch(finch)
              Stub.stop(stub)
            end

          {:error, _reason} = error ->
            Stub.stop(stub)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp run_levels(opts, reporter, targets, baseline, scenario) do
    Enum.reduce_while(
      targets,
      %{max_good: 0, peak: baseline, summaries: [], stop_reason: nil, ready: 0, active_peak: 0},
      fn target, acc ->
        emit(reporter, %{type: :level_started, target: target})
        level = run_level(opts, reporter, target, baseline, scenario)
        emit(reporter, %{type: :level_finished, summary: level.summary})

        acc = %{
          acc
          | peak: max_metrics(acc.peak, level.peak),
            summaries: [level.summary | acc.summaries],
            ready: level.ready,
            active_peak: max(acc.active_peak, level.active_peak)
        }

        if level.good? do
          {:cont, %{acc | max_good: target}}
        else
          {:halt, %{acc | stop_reason: level.stop_reason}}
        end
      end
    )
  end

  defp run_level(opts, reporter, target, baseline, :actor_density) do
    if over_limit?(opts, baseline) do
      density_result(opts, reporter, target, baseline, %{}, 0, 0, 0, baseline, :memory_limit)
    else
      parent = self()
      {:ok, supervisor} = Task.Supervisor.start_link()
      chat = Omunculus.Chat.Fake.new([%{content: "benchmark", tool_calls: [], usage: nil}])

      {tasks, peak, _spawn_over?} =
        spawn_density_tasks(opts, reporter, parent, supervisor, chat, target, baseline)

      try do
        collect_density(
          opts,
          reporter,
          target,
          baseline,
          tasks,
          MapSet.new(),
          0,
          0,
          peak,
          now_ms() + max(opts[:sample_ms], 1),
          0
        )
      after
        Enum.each(tasks, fn {_id, task} ->
          if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
        end)

        Supervisor.stop(supervisor)
        Elixir.Agent.stop(chat.pid)
      end
    end
  end

  defp run_level(opts, reporter, target, baseline, {:http_load, stub, finch}),
    do: run_http_level(opts, reporter, target, baseline, stub, finch)

  defp spawn_density_tasks(opts, reporter, parent, supervisor, chat, target, baseline) do
    Enum.reduce_while(1..target, {%{}, baseline}, fn id, {tasks, peak} ->
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:benchmark_agent, id, :started, now_ms()})

          latch = fn event ->
            if event[:type] == :round_started do
              send(parent, {:benchmark_agent, id, :ready, now_ms(), event[:round]})

              receive do
                {:benchmark_release, ^id} -> :ok
              end
            end

            :ok
          end

          outcome =
            Agent.run(
              instruction: payload(opts[:payload_bytes]),
              chat: chat,
              fs: FS.Memory.new(),
              tools: opts[:tools],
              max_turns: opts[:rounds],
              tool_options: %{tools: %{"counter" => %{increment: 1}}},
              reporter: latch
            )

          send(parent, {:benchmark_agent, id, :done, outcome})
          :ok
        end)

      tasks = Map.put(tasks, id, task)

      if rem(id, @density_sample_batch) == 0 do
        sample = metrics(opts, 0, 0, 0, 0, nil, 0, 0)
        emit(reporter, %{type: :sample, metrics: sample})
        peak = max_metrics(peak, sample)

        if over_limit?(opts, peak),
          do: {:halt, {tasks, peak}},
          else: {:cont, {tasks, peak}}
      else
        {:cont, {tasks, peak}}
      end
    end)
    |> then(fn {tasks, peak} -> {tasks, peak, over_limit?(opts, peak)} end)
  end

  defp collect_density(
         opts,
         reporter,
         target,
         baseline,
         tasks,
         ready_ids,
         failed,
         active_peak,
         peak,
         sample_deadline,
         arrivals
       ) do
    ready = MapSet.size(ready_ids)

    cond do
      failed > 0 ->
        density_result(
          opts,
          reporter,
          target,
          baseline,
          tasks,
          ready,
          failed,
          active_peak,
          peak,
          :agent_crash
        )

      ready == target ->
        # Every worker is blocked in the latch.  One sample is sufficient to
        # capture the plateau; do not release workers or wait for a timeout.
        plateau = metrics(opts, target, target, failed, 0, nil, ready, active_peak)
        emit(reporter, %{type: :sample, metrics: plateau})
        peak = max_metrics(peak, plateau)

        density_result(
          opts,
          reporter,
          target,
          baseline,
          tasks,
          ready,
          failed,
          active_peak,
          peak,
          if(over_limit?(opts, peak), do: :memory_limit, else: nil)
        )

      arrivals >= @density_sample_batch or now_ms() >= sample_deadline ->
        {peak, over?} =
          sample_density(opts, reporter, target, baseline, ready, failed, active_peak, peak)

        if over? do
          density_result(
            opts,
            reporter,
            target,
            baseline,
            tasks,
            ready,
            failed,
            active_peak,
            peak,
            :memory_limit
          )
        else
          collect_density(
            opts,
            reporter,
            target,
            baseline,
            tasks,
            ready_ids,
            failed,
            active_peak,
            peak,
            now_ms() + max(opts[:sample_ms], 1),
            0
          )
        end

      true ->
        receive do
          {:benchmark_agent, id, :started, at} ->
            emit_agent(opts, reporter, id, :running, 0, at)

            collect_density(
              opts,
              reporter,
              target,
              baseline,
              tasks,
              ready_ids,
              failed,
              active_peak,
              peak,
              sample_deadline,
              arrivals
            )

          {:benchmark_agent, id, :ready, at, round} ->
            emit_agent(opts, reporter, id, :waiting_ai, round, at)
            ready_ids = MapSet.put(ready_ids, id)

            collect_density(
              opts,
              reporter,
              target,
              baseline,
              tasks,
              ready_ids,
              failed,
              max(active_peak, MapSet.size(ready_ids)),
              peak,
              sample_deadline,
              arrivals + 1
            )

          # A normal completion is not a benchmark failure.  It can only
          # happen before the latch is reached (for example, a malformed
          # scripted chat), so readiness still determines validity.
          {:benchmark_agent, id, :done, _result} ->
            emit_agent(opts, reporter, id, :completed, 0, now_ms())

            collect_density(
              opts,
              reporter,
              target,
              baseline,
              tasks,
              ready_ids,
              failed,
              active_peak,
              peak,
              sample_deadline,
              arrivals
            )

          {:DOWN, ref, :process, _pid, reason} ->
            case Enum.find(tasks, fn {_id, task} -> task.ref == ref end) do
              nil ->
                collect_density(
                  opts,
                  reporter,
                  target,
                  baseline,
                  tasks,
                  ready_ids,
                  failed,
                  active_peak,
                  peak,
                  sample_deadline,
                  arrivals
                )

              {_id, _task} when reason in [:normal, :shutdown] ->
                collect_density(
                  opts,
                  reporter,
                  target,
                  baseline,
                  tasks,
                  ready_ids,
                  failed,
                  active_peak,
                  peak,
                  sample_deadline,
                  arrivals
                )

              {_id, _task} ->
                collect_density(
                  opts,
                  reporter,
                  target,
                  baseline,
                  tasks,
                  ready_ids,
                  failed + 1,
                  active_peak,
                  peak,
                  sample_deadline,
                  arrivals
                )
            end
        after
          max(sample_deadline - now_ms(), 0) ->
            collect_density(
              opts,
              reporter,
              target,
              baseline,
              tasks,
              ready_ids,
              failed,
              active_peak,
              peak,
              sample_deadline,
              arrivals
            )
        end
    end
  end

  defp finish_tree_summary(opts, state, baseline) do
    max_good_trees = state.max_good_trees
    shape = opts[:tree_shape]
    max_good_agents = max_good_trees * Enum.sum(shape)

    stop_reason =
      state.stop_reason ||
        if(is_integer(opts[:max_trees]) and max_good_trees == opts[:max_trees],
          do: :max_trees,
          else: :completed
        )

    %{
      scenario: :agent_tree,
      synthetic: true,
      tree_mode: opts[:tree_mode],
      tree_shape: shape,
      cpu_limit: opts[:cpu_limit],
      runtime: :current_runtime,
      baseline: baseline,
      peak: state.peak,
      max_good_trees: max_good_trees,
      max_good_agents: max_good_agents,
      max_good: max_good_trees,
      trees: max_good_trees,
      nodes: max_good_agents,
      edges: max_good_trees * (Enum.sum(shape) - 1),
      agent_executions: max_good_agents,
      durable_runs_observed: 0,
      to_be_runs_expected: max_good_trees * runs_per_tree(shape),
      max_depth: length(shape) - 1,
      depth_counts: Enum.map(shape, &(&1 * max_good_trees)),
      ready: state.ready,
      active_peak: state.active_peak,
      failed: state.failed,
      over: state.over,
      over_limit?: state.over,
      stop_reason: stop_reason,
      levels: Enum.reverse(state.summaries)
    }
  end

  defp sample_density(opts, reporter, target, _baseline, ready, failed, active_peak, peak) do
    sample = metrics(opts, ready, 0, failed, max(target - ready, 0), nil, ready, active_peak)
    emit(reporter, %{type: :sample, metrics: sample})
    peak = max_metrics(peak, sample)
    {peak, over_limit?(opts, peak)}
  end

  defp density_result(
         opts,
         _reporter,
         target,
         baseline,
         tasks,
         ready,
         failed,
         active_peak,
         peak,
         reason
       ) do
    # Workers are intentionally cancelled neutrally after the plateau.  In
    # particular, never send benchmark_release: density must not resume an AI
    # call or turn into an HTTP benchmark.
    Enum.each(tasks, fn {_id, task} ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)

    over = over_limit?(opts, peak)
    good = ready == target and active_peak == target and failed == 0 and not over

    summary = %{
      scenario: :actor_density,
      target: target,
      ready: ready,
      active_peak: active_peak,
      baseline: baseline,
      peak: peak,
      completed: if(good, do: target, else: 0),
      failed: failed,
      over_limit?: over,
      valid?: good
    }

    %{
      summary: summary,
      peak: peak,
      ready: ready,
      active_peak: active_peak,
      good?: good,
      stop_reason: reason || if(good, do: nil, else: :agent_crash),
      level: tasks
    }
  end

  defp run_http_level(opts, reporter, target, baseline, stub, finch) do
    expected = min(target, opts[:http_concurrency])
    :ok = configure_stub(stub, expected, opts)
    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    tasks =
      for id <- 1..target, into: %{} do
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:http_request, id, http_request(opts, stub, finch)})
            :ok
          end)

        {id, task}
      end

    try do
      collect_http(opts, reporter, target, baseline, stub, tasks, 0, 0, 0, 0, baseline)
    after
      Enum.each(tasks, fn {_id, task} ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)

      Supervisor.stop(supervisor)
    end
  end

  defp collect_http(
         opts,
         reporter,
         target,
         baseline,
         stub,
         tasks,
         completed,
         failed,
         ready,
         active_peak,
         peak
       ) do
    stats = stub_stats(stub)
    in_flight = stat(stats, :in_flight, stat(stats, :active, 0))
    active_peak = max(active_peak, stat(stats, :active_peak, in_flight))

    sample =
      metrics(
        opts,
        in_flight,
        completed,
        failed,
        max(target - completed - failed, 0),
        in_flight,
        ready,
        active_peak
      )

    peak = max_metrics(peak, sample)
    emit(reporter, %{type: :sample, metrics: sample})

    cond do
      over_limit?(opts, peak) ->
        http_result(
          opts,
          target,
          baseline,
          completed,
          failed,
          active_peak,
          peak,
          :memory_limit
        )

      map_size(tasks) == 0 ->
        http_result(opts, target, baseline, completed, failed, active_peak, peak, nil)

      true ->
        receive do
          {:http_request, id, result} ->
            successful? = match?({:ok, _}, result)

            {completed, failed} =
              if successful?, do: {completed + 1, failed}, else: {completed, failed + 1}

            emit_agent(
              opts,
              reporter,
              id,
              if(successful?, do: :completed, else: :failed),
              1,
              now_ms()
            )

            collect_http(
              opts,
              reporter,
              target,
              baseline,
              stub,
              Map.delete(tasks, id),
              completed,
              failed,
              ready,
              active_peak,
              peak
            )

          {:DOWN, ref, :process, _pid, reason} ->
            case Enum.find(tasks, fn {_id, task} -> task.ref == ref end) do
              {id, _} ->
                emit_agent(opts, reporter, id, :failed, 0, now_ms())

                collect_http(
                  opts,
                  reporter,
                  target,
                  baseline,
                  stub,
                  Map.delete(tasks, id),
                  completed,
                  failed + if(reason in [:normal, :shutdown], do: 0, else: 1),
                  ready,
                  active_peak,
                  peak
                )

              nil ->
                collect_http(
                  opts,
                  reporter,
                  target,
                  baseline,
                  stub,
                  tasks,
                  completed,
                  failed,
                  ready,
                  active_peak,
                  peak
                )
            end
        after
          max(opts[:sample_ms], 1) ->
            collect_http(
              opts,
              reporter,
              target,
              baseline,
              stub,
              tasks,
              completed,
              failed,
              ready,
              active_peak,
              peak
            )
        end
    end
  end

  defp http_result(opts, target, baseline, completed, failed, active_peak, peak, reason) do
    over = reason == :memory_limit or over_limit?(opts, peak)
    good = completed == target and failed == 0 and not over

    summary = %{
      scenario: :http_load,
      target: target,
      ready: target,
      active_peak: active_peak,
      baseline: baseline,
      peak: peak,
      completed: completed,
      failed: failed,
      over_limit?: over,
      valid?: good
    }

    %{
      summary: summary,
      peak: peak,
      ready: target,
      active_peak: active_peak,
      good?: good,
      stop_reason: reason || if(good, do: nil, else: :http_failed)
    }
  end

  defp http_request(opts, stub, finch) do
    messages = [%{role: "user", content: payload(opts[:payload_bytes])}]
    http_request(opts, stub, finch, messages, 0)
  end

  defp http_request(opts, stub, finch, messages, round) do
    request = %{
      model: opts[:model] || "benchmark-stub",
      messages: messages,
      tools: tools_payload(opts[:tools])
    }

    case Req.post(stub.base_url <> "/v1/chat/completions",
           json: request,
           finch: [
             name: finch,
             pool_timeout: max(opts[:sample_ms] * 20, 1_000),
             receive_timeout: max(opts[:sample_ms] * 20, 1_000)
           ],
           retry: false
         ) do
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        tool_calls = get_in(body, ["choices", Access.at(0), "message", "tool_calls"])

        if is_list(tool_calls) and tool_calls != [] and round < opts[:rounds] do
          next_messages =
            (messages ++
               [
                 get_in(body, ["choices", Access.at(0), "message"]),
                 Enum.map(tool_calls, fn call ->
                   %{
                     role: "tool",
                     content: "Counter value: 1",
                     tool_call_id: call["id"]
                   }
                 end)
               ])
            |> List.flatten()

          http_request(opts, stub, finch, next_messages, round + 1)
        else
          {:ok, response}
        end

      {:ok, response} ->
        {:error, {:http, response.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_stub(stub, expected, opts) do
    case Stub.configure(stub,
           expected_in_flight: expected,
           delay_ms: opts[:stub_delay_ms],
           rounds: opts[:rounds],
           payload_bytes: opts[:payload_bytes],
           barrier_timeout_ms: max(opts[:sample_ms] * 10, 1_000)
         ) do
      :ok -> :ok
      {:error, reason} -> throw({:stub_configure_failed, reason})
    end
  end

  defp start_finch(size) do
    name = Omunculus.Benchmark.Finch

    case Finch.start_link(name: name, pools: %{default: [size: size]}) do
      {:ok, _pid} -> {:ok, name}
      other -> other
    end
  end

  defp stop_finch(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp start_provider(%{provider: :stub} = opts) do
    with {:ok, stub} <-
           Stub.start(
             delay_ms: opts[:stub_delay_ms],
             rounds: opts[:rounds],
             payload_bytes: opts[:payload_bytes]
           ),
         {:ok, auth} <- Auth.resolve("none") do
      {:ok,
       %{
         chat:
           Completions.new(
             base_url: stub.base_url,
             model: opts[:model] || "benchmark-stub",
             auth: auth
           ),
         stub: stub
       }}
    end
  end

  defp start_provider(%{provider: :real} = opts) do
    env = Map.merge(System.get_env(), Map.get(opts, :env, %{}))

    with {:ok, config} <- Config.load(cwd: opts[:cwd], config_file: opts[:config], env: env),
         {:ok, auth} <- build_auth(config.chat, opts, env),
         {:ok, mod} <- Chat.resolve(config.chat.api || "openai-completions"),
         model when is_binary(model) and model != "" <-
           opts[:model] || config.chat.model || env["OMUNCULUS_MODEL"] do
      base_url = config.chat.base_url || env["OMUNCULUS_BASE_URL"]

      if is_binary(base_url) and base_url != "",
        do: {:ok, %{chat: mod.new(base_url: base_url, model: model, auth: auth), stub: nil}},
        else: {:error, {:missing_base_url, nil}}
    else
      nil -> {:error, {:missing_model, nil}}
      {:error, _} = error -> error
    end
  end

  defp build_auth(chat, opts, env) do
    type =
      chat.auth ||
        if((opts[:api_key] || env["OMUNCULUS_API_KEY"] || "") == "", do: "none", else: "api_key")

    with {:ok, {mod, cred}} <- Auth.resolve(type),
         do:
           {:ok,
            {mod,
             Map.put(cred, :key, opts[:api_key] || chat.api_key || env["OMUNCULUS_API_KEY"] || "")}}
  end

  defp stop_provider(%{stub: nil}), do: :ok
  defp stop_provider(%{stub: stub}), do: Stub.stop(stub)

  defp finish_summary(opts, state, baseline) do
    stop_reason =
      state.stop_reason ||
        if(is_integer(opts[:max_agents]) and state.max_good == opts[:max_agents],
          do: :max_agents,
          else: :completed
        )

    %{
      scenario: opts[:scenario],
      cpu_limit: opts[:cpu_limit],
      runtime: :current_runtime,
      baseline: baseline,
      peak: state.peak,
      max_good: state.max_good,
      ready: state.ready,
      active_peak: state.active_peak,
      stop_reason: stop_reason,
      levels: Enum.reverse(state.summaries),
      per_agent: per_agent(baseline, state.peak, state.max_good)
    }
  end

  defp tree_targets(%{max_trees: nil, step: _step}), do: Stream.iterate(1, &(&1 * 2))
  defp tree_targets(%{max_trees: max, step: nil}), do: geometric_targets(max)
  defp tree_targets(%{max_trees: max, step: step}), do: linear_targets(max, step)

  defp targets(%{max_agents: nil, step: nil, memory_limit: _}), do: Stream.iterate(1, &(&1 * 2))

  defp targets(%{max_agents: nil, step: step, memory_limit: _}),
    do: Stream.iterate(step, &(&1 + step))

  defp targets(%{max_agents: max, step: nil}), do: geometric_targets(max)
  defp targets(%{max_agents: max, step: step}), do: linear_targets(max, step)

  defp geometric_targets(max) do
    levels = Enum.take_while(Stream.iterate(1, &(&1 * 2)), &(&1 <= max))
    if List.last(levels) == max, do: levels, else: levels ++ [max]
  end

  defp linear_targets(max, step) do
    levels = Enum.take_while(Stream.iterate(step, &(&1 + step)), &(&1 <= max))
    if List.last(levels) == max, do: levels, else: levels ++ [max]
  end

  defp metrics(opts, active, completed, failed, queued, http, ready, active_peak) do
    %{
      scenario: opts[:scenario],
      cpu_limit: opts[:cpu_limit],
      rss_bytes: rss_bytes(),
      limit_bytes: opts[:memory_limit],
      beam_bytes: :erlang.memory(:total),
      processes: length(Process.list()),
      active: active,
      completed: completed,
      failed: failed,
      queued: queued,
      ready: ready,
      active_peak: active_peak,
      http_in_flight: http
    }
  end

  defp max_metrics(a, b) do
    Enum.reduce(
      [:rss_bytes, :beam_bytes, :processes, :active, :ready, :active_peak, :http_in_flight],
      a,
      fn key, acc ->
        av = acc[key]
        bv = b[key]
        if is_number(bv) and (not is_number(av) or bv > av), do: Map.put(acc, key, bv), else: acc
      end
    )
  end

  defp rss_bytes do
    case File.read("/proc/self/status") do
      {:ok, body} ->
        case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB$/m, body) do
          [_, kb] -> String.to_integer(kb) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp tools_payload([]), do: []

  defp tools_payload(["counter"]) do
    [
      %{
        type: "function",
        function: %{
          name: "counter",
          description: "Increment the benchmark counter",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    ]
  end

  defp over_limit?(%{memory_limit: nil}, _), do: false
  defp over_limit?(%{memory_limit: limit}, metrics), do: metrics.rss_bytes >= limit

  defp per_agent(baseline, peak, count) when is_integer(count) and count > 0,
    do: %{
      slope_bytes: (peak.rss_bytes - baseline.rss_bytes) / count,
      estimate_bytes: peak.rss_bytes
    }

  defp per_agent(_, _, _), do: %{slope_bytes: nil, estimate_bytes: nil}

  defp public_config(opts),
    do:
      Map.take(opts, [
        :scenario,
        :tree_mode,
        :tree_shape,
        :cpu_limit,
        :provider,
        :model,
        :tools,
        :max_agents,
        :max_trees,
        :memory_limit,
        :rounds,
        :stub_delay_ms,
        :payload_bytes,
        :step,
        :sample_ms,
        :http_concurrency
      ])

  defp emit(reporter, event), do: reporter.(event)

  defp payload(0), do: "benchmark"
  defp payload(n), do: "benchmark " <> String.duplicate("x", max(n - 10, 0))

  defp emit_agent(opts, reporter, id, state, round, at),
    do: emit_agent(opts, reporter, id, state, round, at, nil, nil, nil)

  defp emit_agent(opts, reporter, id, state, round, at, parent_id, depth, path) do
    if opts[:live] != false do
      agent = %{
        id: id,
        parent_id: parent_id,
        state: state,
        round: round,
        tool: nil,
        started_at_ms: at
      }

      agent =
        if is_nil(depth),
          do: agent,
          else: Map.merge(agent, %{depth: depth, path: path})

      emit(reporter, %{type: :agent_updated, agent: agent})
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp positive?(n), do: is_integer(n) and n > 0
  defp nonnegative?(n), do: is_integer(n) and n >= 0

  defp to_atom("actor-density"), do: :actor_density
  defp to_atom("agent-tree"), do: :agent_tree
  defp to_atom("http-load"), do: :http_load
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v), do: String.to_atom(to_string(v))
  defp normalize_tools(:none), do: []
  defp normalize_tools("none"), do: []
  defp normalize_tools("counter"), do: ["counter"]
  defp normalize_tools(v) when is_binary(v), do: String.split(v, ",", trim: true)

  defp normalize_tools(v) when is_list(v),
    do:
      Enum.map(v, fn
        item when is_atom(item) -> Atom.to_string(item)
        item -> item
      end)

  defp stat(map, key, fallback),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), fallback))

  defp stub_stats(stub) do
    case Stub.stats(stub) do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end

  defp set_cpu_limit(nil), do: nil

  defp set_cpu_limit(limit) do
    previous = System.schedulers_online()
    :erlang.system_flag(:schedulers_online, limit)
    previous
  end

  defp restore_cpu_limit(nil), do: :ok
  defp restore_cpu_limit(previous), do: :erlang.system_flag(:schedulers_online, previous)
  defp maybe_write_json(nil, _), do: :ok

  defp maybe_write_json(path, result) when is_binary(path),
    do: File.write(path, Jason.encode!(result, pretty: true) <> "\n")
end
