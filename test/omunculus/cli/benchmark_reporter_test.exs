defmodule Omunculus.CLI.BenchmarkReporterTest do
  use ExUnit.Case, async: true

  alias Omunculus.CLI.BenchmarkReporter

  defp reporter(opts \\ []) do
    {:ok, io} = StringIO.open("")

    {:ok, pid} =
      BenchmarkReporter.start_link(
        Keyword.merge([io: io, terminal?: false, live?: false, line_limit: 24], opts)
      )

    {pid, io}
  end

  defp output(io) do
    {_input, output} = StringIO.contents(io)
    output
  end

  test "renders ASCII-only fallback snapshots with RAM and counters" do
    {pid, io} = reporter()

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :benchmark_started,
        config: %{provider: :stub, model: "small", tools: :none, max_agents: 4}
      })

    :ok = BenchmarkReporter.event(pid, %{type: :level_started, target: 2})

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :sample,
        metrics: %{
          rss_bytes: 4 * 1_048_576,
          limit_bytes: 8 * 1_048_576,
          active: 2,
          completed: 1,
          failed: 0,
          queued: 1,
          processes: 7,
          http_in_flight: 2
        }
      })

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :agent_updated,
        agent: %{id: "agent-1", parent_id: nil, state: :running_tool, round: 1, tool: "counter"}
      })

    rendered = output(io)
    assert rendered =~ "Omunculus benchmark"
    assert rendered =~ "Level: target=2"
    assert rendered =~ "RAM [##########..........] 4 MiB / 8 MiB (RSS soft limit)"
    assert rendered =~ "active=2 completed=1 failed=0 queued=1"
    refute rendered =~ "|- agent-1 [running_tool] round=1 tool=counter"
    refute rendered =~ "\e["
    assert Enum.all?(String.to_charlist(rendered), &(&1 < 128))

    :ok = BenchmarkReporter.stop(pid)
  end

  test "keeps parent and child hierarchy and accepts unknown parents" do
    {pid, io} = reporter(terminal?: true, live?: true)

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :agent_updated,
        agent: %{id: "root", parent_id: nil, state: :starting}
      })

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :agent_updated,
        agent: %{id: "child", parent_id: "root", state: :waiting_ai}
      })

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :agent_updated,
        agent: %{id: "orphan", parent_id: "missing", state: :queued}
      })
    :ok = BenchmarkReporter.event(pid, %{type: :sample, metrics: %{}})

    rendered = output(io)
    assert rendered =~ "|- root [starting]"
    assert rendered =~ "   `- child [waiting_ai]"
    assert rendered =~ "|- orphan [queued]"
    refute rendered =~ "Sessions"

    :ok = BenchmarkReporter.stop(pid)
  end

  test "limits visible agent lines and aggregates overflow by state" do
    {pid, io} = reporter(terminal?: true, live?: true, line_limit: 2)

    for {id, state} <- [{"a", :queued}, {"b", :queued}, {"c", :failed}, {"d", :completed}] do
      :ok =
        BenchmarkReporter.event(pid, %{
          type: :agent_updated,
          agent: %{id: id, parent_id: nil, state: state}
        })
    end
    :ok = BenchmarkReporter.event(pid, %{type: :sample, metrics: %{}})

    rendered = output(io)
    assert rendered =~ "|- a [queued]"
    assert rendered =~ "|- b [queued]"
    assert rendered =~ "... 2 more (1 completed, 1 failed)"
    refute rendered =~ "|- c [failed]"
    refute rendered =~ "|- d [completed]"

    :ok = BenchmarkReporter.stop(pid)
  end

  test "coalesces 10,000 agent updates into a bounded no-live snapshot" do
    {pid, io} = reporter()

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :benchmark_started,
        config: %{scenario: :actor_density, max_agents: 10_000}
      })

    :ok = BenchmarkReporter.event(pid, %{type: :level_started, target: 10_000})
    before_updates = byte_size(output(io))

    for id <- 1..10_000 do
      :ok =
        BenchmarkReporter.event(pid, %{
          type: :agent_updated,
          agent: %{id: id, parent_id: nil, state: :waiting_ai}
        })
    end

    assert byte_size(output(io)) == before_updates

    :ok = BenchmarkReporter.event(pid, %{type: :sample, metrics: %{ready: 10_000}})
    rendered = output(io)
    state = :sys.get_state(pid)

    assert byte_size(rendered) < 4_096
    refute rendered =~ "10000 [waiting_ai]"
    assert map_size(state.agents) == 24
    assert Enum.sum(Map.values(state.overflow)) == 9_976
    :ok = BenchmarkReporter.stop(pid)
  end

  test "clears retained agent details when a new level starts" do
    {pid, _io} = reporter(terminal?: true, live?: true)

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :agent_updated,
        agent: %{id: "old-level", parent_id: nil, state: :starting}
      })

    :ok = BenchmarkReporter.event(pid, %{type: :level_started, target: 2})
    state = :sys.get_state(pid)

    assert state.level == 2
    assert state.agents == %{}
    assert state.overflow == %{}
    :ok = BenchmarkReporter.stop(pid)
  end

  test "renders final and level summaries without retaining snapshot history" do
    {pid, io} = reporter()

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :level_finished,
        summary: %{baseline: 1, peak: 3, max_good: 2, stop_reason: :memory_limit}
      })

    :ok =
      BenchmarkReporter.event(pid, %{
        type: :benchmark_finished,
        summary: %{
          baseline: 1,
          peak: 3,
          max_good: 2,
          stop_reason: :memory_limit,
          agent_executions: 8,
          durable_runs_observed: 0,
          to_be_runs_expected: 12,
          per_agent: %{"agent-1" => %{"slope_bytes" => 12, "estimate_bytes" => 2}}
        }
      })

    rendered = output(io)
    assert rendered =~ "Level summary: baseline=1 peak=3 max_good=2 stop_reason=memory_limit"

    assert rendered =~
             "agent_executions=8 durable_runs_observed=0 to_be_runs_expected=12"

    refute rendered =~ "runs=12"

    assert rendered =~
             "Summary: agent_executions=8 durable_runs_observed=0 to_be_runs_expected=12 baseline=1 peak=3 max_good=2 stop_reason=memory_limit agent-1: slope=12 estimate=2"

    :ok = BenchmarkReporter.stop(pid)
  end
end
