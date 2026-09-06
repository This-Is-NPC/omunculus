defmodule Omunculus.CLI.ReporterTest do
  use ExUnit.Case, async: true

  alias Omunculus.CLI.Reporter

  test "renders a run tree followed by a summary table" do
    {:ok, io} = StringIO.open("")

    {:ok, reporter} =
      Reporter.start_link(
        io: io,
        terminal?: false,
        model: "test-model",
        tools: ["read"],
        max_rounds: 4
      )

    Reporter.event(reporter, %{type: :round_started, round: 1, max_rounds: 4})

    Reporter.event(reporter, %{
      type: :round_completed,
      round: 1,
      outcome: :tool_calls,
      tool_calls: 1,
      usage: %{"total_tokens" => 10},
      duration_ms: 120
    })

    Reporter.event(reporter, %{
      type: :tool_started,
      round: 1,
      name: "read",
      path: "README.md",
      detail: "read README.md"
    })

    Reporter.event(reporter, %{
      type: :tool_completed,
      round: 1,
      name: "read",
      path: "README.md",
      detail: "read README.md",
      outcome: :completed,
      duration_ms: 2
    })

    Reporter.event(reporter, %{
      type: :run_completed,
      outcome: :completed,
      rounds: 1,
      tool_calls: 1,
      usage: %{"total_tokens" => 10},
      duration_ms: 122
    })

    {_input, output} = StringIO.contents(io)
    lines = String.split(output, "\n")

    assert output =~ "┌── Run started ─"
    assert output =~ "│ Model: test-model · Tools: 1 · Max rounds: 4"
    assert output =~ "├─● Round 1 · Model response · 1 tool call · 120ms"
    assert output =~ "│ └─● Tool · Read · README.md · 2ms"
    assert output =~ "│ Rounds: 1 · Tools: 1 · Tokens: 10 · Duration: 122ms"
    assert output =~ "└── Completed ─"
    assert output =~ "│ Round │ Outcome"
    assert output =~ "│ Run   │ Completed"

    summary_index = Enum.find_index(lines, &String.starts_with?(&1, "│ Rounds:"))
    assert Enum.at(lines, summary_index - 1) == "│"
    assert String.starts_with?(Enum.at(lines, summary_index + 1), "└── Completed ")
  end

  test "keeps a failed round centered between run metadata and summary" do
    {:ok, io} = StringIO.open("")

    {:ok, reporter} =
      Reporter.start_link(
        io: io,
        terminal?: false,
        model: "test-model",
        tools: ["read"],
        max_rounds: 4
      )

    Reporter.event(reporter, %{type: :round_started, round: 1, max_rounds: 4})

    Reporter.event(reporter, %{
      type: :round_failed,
      round: 1,
      reason: :econnrefused,
      duration_ms: 72
    })

    Reporter.event(reporter, %{
      type: :run_failed,
      rounds: 0,
      tool_calls: 0,
      usage: nil,
      reason: :econnrefused,
      duration_ms: 105
    })

    {_input, output} = StringIO.contents(io)

    assert output =~
             "│ Model: test-model · Tools: 1 · Max rounds: 4\n" <>
               "│\n" <>
               "├─× Round 1 · :econnrefused · 72ms\n" <>
               "│\n" <>
               "│ Rounds: 0 · Tools: 0 · Tokens: 0 · Duration: 105ms\n" <>
               "└── Failed "
  end

  test "formats transport failures without exposing implementation structs" do
    {:ok, io} = StringIO.open("")

    {:ok, reporter} =
      Reporter.start_link(
        io: io,
        terminal?: false,
        model: "test-model",
        tools: ["read"],
        max_rounds: 4
      )

    Reporter.event(reporter, %{type: :round_started, round: 1})

    Reporter.event(reporter, %{
      type: :round_failed,
      round: 1,
      reason: %Req.TransportError{reason: :econnrefused},
      duration_ms: 68
    })

    Reporter.event(reporter, %{
      type: :run_failed,
      rounds: 0,
      tool_calls: 0,
      usage: nil,
      reason: %Req.TransportError{reason: :econnrefused},
      duration_ms: 70
    })

    {_input, output} = StringIO.contents(io)
    assert output =~ "├─× Round 1 · Connection refused · 68ms"
    refute output =~ "Req.TransportError"
  end

  test "verbose mode appends timestamped operations with relative paths" do
    {:ok, io} = StringIO.open("")
    timestamp = ~U[2026-08-29 21:53:35.123Z]

    {:ok, reporter} =
      Reporter.start_link(
        io: io,
        terminal?: false,
        verbose?: true,
        root: "/workspace/project",
        timestamp_format: "%d/%m/%Y %H:%M:%S",
        model: "test-model",
        tools: ["read"],
        max_rounds: 4
      )

    Reporter.event(reporter, %{type: :round_started, round: 1, timestamp: timestamp})

    Reporter.event(reporter, %{
      type: :round_completed,
      round: 1,
      outcome: :tool_calls,
      tool_calls: 1,
      usage: %{"total_tokens" => 10},
      duration_ms: 120,
      timestamp: timestamp
    })

    Reporter.event(reporter, %{
      type: :tool_started,
      round: 1,
      name: "read",
      path: "/workspace/project/lib/example.ex",
      timestamp: timestamp
    })

    Reporter.event(reporter, %{
      type: :tool_completed,
      round: 1,
      name: "read",
      path: "/workspace/project/lib/example.ex",
      outcome: :completed,
      duration_ms: 2,
      timestamp: timestamp
    })

    Reporter.event(reporter, %{
      type: :round_finished,
      round: 1,
      tool_calls: 1,
      duration_ms: 122,
      timestamp: timestamp
    })

    Reporter.event(reporter, %{
      type: :run_completed,
      outcome: :completed,
      rounds: 1,
      tool_calls: 1,
      usage: %{"total_tokens" => 10},
      duration_ms: 122,
      timestamp: timestamp
    })

    {_input, output} = StringIO.contents(io)

    assert output =~ "│ 29/08/2026 21:53:35  START  Round"
    assert output =~ "│ 29/08/2026 21:53:35  WAIT   Model response"
    assert output =~ "│ 29/08/2026 21:53:35  START  Reading · lib/example.ex"
    assert output =~ "│ 29/08/2026 21:53:35  OK     Read · lib/example.ex · 2ms"
    refute output =~ "/workspace/project"
  end

  test "json-events writes one JSON object per harness event" do
    {:ok, io} = StringIO.open("")

    {:ok, reporter} =
      Reporter.start_link(
        io: io,
        json_events?: true,
        model: "test-model",
        tools: ["counter"],
        max_rounds: 4
      )

    Reporter.event(reporter, %{type: :round_started, round: 1, max_rounds: 4})

    Reporter.event(reporter, %{
      type: :round_completed,
      round: 1,
      outcome: :tool_calls,
      tool_calls: 1,
      usage: %{"total_tokens" => 10},
      duration_ms: 120
    })

    Reporter.event(reporter, %{
      type: :tool_started,
      round: 1,
      name: "counter",
      from: 0,
      to: 1
    })

    Reporter.event(reporter, %{
      type: :tool_result_waiting,
      round: 1,
      name: "counter",
      delay_ms: 30_000
    })

    Reporter.event(reporter, %{
      type: :tool_completed,
      round: 1,
      name: "counter",
      from: 0,
      to: 1,
      outcome: :completed,
      duration_ms: 30_002
    })

    Reporter.event(reporter, %{
      type: :run_completed,
      outcome: :completed,
      rounds: 1,
      tool_calls: 1,
      usage: %{"total_tokens" => 10},
      duration_ms: 30_122
    })

    {_input, output} = StringIO.contents(io)
    events = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert hd(events)["type"] == "run_started"
    assert hd(events)["model"] == "test-model"
    assert Enum.any?(events, &(&1["type"] == "round_started" and &1["round"] == 1))
    assert Enum.any?(events, &(&1["type"] == "tool_result_waiting" and &1["delay_ms"] == 30_000))
    assert Enum.any?(events, &(&1["type"] == "tool_completed" and &1["duration_ms"] == 30_002))
    assert List.last(events)["type"] == "run_completed"
    refute output =~ "┌──"
  end
end
