# Historical v1 protocol baseline (explicit workflow:false); new protocol coverage is in workflow_test.exs.
# Offline fault injection through the Runtime and agent resolver.
# Only the provider responses are replaced; no HTTP requests are made.
# Run: mise exec -- mix run scripts/probe_harness_resilience.exs
defmodule HarnessResilienceProbe do
  alias Omunculus.{Config, EventCore, Runtime}
  alias Omunculus.Chat.Fake
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents

  def run(mode) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "omunculus-resilience-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
      )

    File.mkdir_p!(dir)
    config_file = Path.join(dir, "omunculus.toml")
    fixture = Path.expand("../test/fixtures/config/complex.toml", __DIR__)
    File.cp!(fixture, config_file)
    lane = File.read!(Path.expand("../test/fixtures/config/lane.toml", __DIR__))
    File.write!(config_file, "\n" <> lane, [:append])
    {:ok, config} = Config.load(cwd: dir, config_file: config_file, env: %{})
    {:ok, checked} = Config.check(config)

    {:ok, core} =
      EventCore.start_link(
        path: Path.join(dir, "session.sqlite3"),
        interceptors: checked.interceptors
      )

    {:ok, projector} = Projector.start_link(core: core)
    owner = self()

    resolver = fn ctx ->
      turns = turns(ctx, mode, owner)
      chat = Fake.new(turns) |> Map.put(:model, "controlled-boundary")
      Agents.resolve(ctx, %{chat: chat}) |> Map.put(:workflow, false)
    end

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 2,
        agents: resolver,
        config: [cwd: dir, config_file: config_file, profile: "count", env: %{}],
        run_opts: [fs: Omunculus.FS.Memory.new()]
      )

    task =
      Task.async(fn -> Runtime.request(core, "conte até 10", workspace: "app", timeout: 2_000) end)

    try do
      before =
        case mode do
          :correct_chain ->
            caller =
              receive do
                {:leaf_ready, caller} -> caller
              after
                2_000 -> raise "leaf not reached"
              end

            await(fn -> Runtime.runs(runtime) |> Map.values() |> Enum.map(& &1.depth) == [2] end)
            events = EventCore.stream(core, 0)

            waiting =
              Enum.filter(
                events,
                &(&1.type == "run.completed" and &1.payload["outcome"] == "waiting")
              )

            sample = %{active_depths: [2], closed_waiting_runs: length(waiting)}
            send(caller, :release)
            sample

          m when m in [:child_error, :child_error_then_resume] ->
            await(fn -> EventCore.stream(core, 0, type: "run.failed") != [] end)
            await(fn -> Runtime.runs(runtime) == %{} end)
            Projector.sync(projector)
            failure = EventCore.stream(core, 0, type: "run.failed") |> hd()

            sample = %{
              active_runs: 0,
              work_item_statuses:
                EventCore.query(core, "SELECT status, COUNT(*) FROM WORK_ITEMS GROUP BY status"),
              resume_commands: length(EventCore.stream(core, 0, type: "task.resumed"))
            }

            if mode == :child_error_then_resume do
              {:ok, _} =
                Runtime.resume(core, failure.work_item_id,
                  correlation_id: failure.correlation_id,
                  causation_id: failure.event_id
                )
            end

            sample

          _ ->
            %{}
        end

      result = Task.await(task, 4_000)
      await(fn -> Runtime.runs(runtime) == %{} end)
      Projector.sync(projector)
      events = EventCore.stream(core, 0)
      starts = Enum.filter(events, &(&1.type == "run.started"))

      counter =
        Enum.filter(
          events,
          &(&1.type == "tool.call.completed" and &1.payload["tool"] == "counter" and
              &1.payload["outcome"] == "completed")
        )

      row = %{
        scenario: mode,
        client_success: match?({:ok, _}, result),
        client_outcome:
          case result do
            {:ok, _} -> "completed"
            {:error, :timeout} -> "timeout"
            {:error, reason} -> inspect(reason)
          end,
        counter_calls: length(counter),
        counter_sequences:
          counter
          |> Enum.group_by(& &1.work_item_id)
          |> Map.values()
          |> Enum.map(fn calls -> Enum.map(calls, & &1.payload["new"]) end)
          |> Enum.sort(),
        root_result: if(match?({:ok, _}, result), do: elem(result, 1).result, else: nil),
        active_runs_at_end: map_size(Runtime.runs(runtime)),
        depths: starts |> Enum.map(& &1.payload["depth"]) |> Enum.uniq() |> Enum.sort(),
        continuations: Enum.count(starts, &(&1.payload["reason"] == "continuation")),
        retry_runs: Enum.count(starts, &(&1.payload["reason"] == "retry")),
        provider_calls: Enum.count(events, &(&1.type == "model.call.completed")),
        rejections:
          events
          |> Enum.filter(&(&1.type == "delivery.rejected"))
          |> Enum.map(& &1.payload["reason"]),
        failures: Enum.count(events, &(&1.type == "run.failed")),
        checkpoint_observation: before,
        work_item_statuses:
          EventCore.query(core, "SELECT status, COUNT(*) FROM WORK_ITEMS GROUP BY status")
      }

      IO.puts(Jason.encode!(row))
      row
    after
      for pid <- [runtime, projector, core], Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp turns(ctx, mode, owner) do
    cond do
      mode == :parent_requests_correction and ctx.depth == 0 and ctx.reason == "continuation" ->
        [
          fn messages ->
            latest = messages |> Enum.filter(&(&1["role"] == "tool")) |> List.last()

            cond do
              String.contains?(latest["content"], "Result: Incomplete") ->
                Fake.tool_call(
                  "delegate",
                  %{"instruction" => "Correction: conte até 10 usando counter"},
                  "correction"
                )

              String.contains?(latest["content"], "Result: 10.") ->
                Fake.text("10")

              true ->
                {:error, :unexpected_review_input}
            end
          end
        ]

      mode == :parent_requests_correction and ctx.depth == 1 and ctx.reason == "initial" and
          not String.starts_with?(ctx.instruction, "Correction:") ->
        [Fake.text("Incomplete: no tools executed; please request correction.")]

      ctx.reason == "continuation" ->
        [
          fn messages ->
            observed =
              Enum.any?(
                messages,
                &(is_binary(&1["content"]) and
                    String.contains?(&1["content"], "Sub-agent completed. Result: 10."))
              )

            if observed, do: Fake.text("10"), else: {:error, :missing_child_result}
          end
        ]

      ctx.depth == 0 and mode == :root_false_done ->
        [Fake.text("10")]

      ctx.depth == 1 and mode == :middle_false_done ->
        [Fake.text("10")]

      ctx.depth == 1 and mode == :middle_executes_directly ->
        count_turns()

      ctx.depth == 0 and mode == :invalid_target_then_correct ->
        [
          Fake.tool_call("delegate", %{"instruction" => "conte até 10", "agent" => "ghost"}),
          fn messages ->
            rejected =
              Enum.any?(
                messages,
                &(is_binary(&1["content"]) and
                    String.contains?(&1["content"], "agent without team"))
              )

            if rejected, do: delegate(), else: {:error, :missing_rejection_feedback}
          end
        ]

      ctx.depth < 2 ->
        [delegate()]

      ctx.depth == 2 and mode in [:child_error, :child_error_then_resume] and
          ctx.reason != "retry" ->
        [{:error, :controlled_provider_timeout}]

      ctx.depth == 2 and mode == :worker_false_done ->
        List.duplicate(Fake.text("10"), 32)

      ctx.depth == 2 and mode == :correct_chain ->
        [
          fn _messages ->
            send(owner, {:leaf_ready, self()})

            receive do
              :release -> Fake.tool_call("counter", %{}, "counter-1")
            after
              3_000 -> {:error, :probe_release_timeout}
            end
          end
        ] ++
          Enum.map(2..10, &Fake.tool_call("counter", %{}, "counter-#{&1}")) ++ [Fake.text("10")]

      true ->
        count_turns()
    end
  end

  defp delegate, do: Fake.tool_call("delegate", %{"instruction" => "conte até 10"}, "delegate")

  defp count_turns,
    do: Enum.map(1..10, &Fake.tool_call("counter", %{}, "counter-#{&1}")) ++ [Fake.text("10")]

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 2_000)

  defp await(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "probe condition not reached"

      true ->
        Process.sleep(5)
        await(fun, deadline)
    end
  end
end

for mode <- [
      :correct_chain,
      :root_false_done,
      :middle_false_done,
      :middle_executes_directly,
      :worker_false_done,
      :invalid_target_then_correct,
      :parent_requests_correction,
      :child_error,
      :child_error_then_resume
    ] do
  HarnessResilienceProbe.run(mode)
end
