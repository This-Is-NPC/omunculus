defmodule Omunculus.CLI.UITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Omunculus.CLI
  alias Omunculus.CLI.{Reporter, Replay, UI}
  alias Omunculus.Event.Envelope
  alias Omunculus.{EventCore, Runtime}

  test "all layouts preserve interleaved boundaries, failures and full evidence" do
    events = [
      event(1, "run.started", "parent", %{"depth" => 0}),
      event(2, "run.started", "child", %{"depth" => 1, "parent_run_id" => "parent"}),
      event(3, "model.call.requested", "parent", %{
        "round" => 1,
        "messages" => [%{"content" => "secret-prompt-evidence"}]
      }),
      event(4, "run.completed", "child", %{"outcome" => "reported", "comment" => "child evidence"}),
      event(5, "run.failed", "parent", %{"reason" => "provider_offline"}),
      event(6, "run.started", "open", %{}),
      event(7, "unknown.observation", nil, %{"note" => "unrecognized-event-evidence\e[2J"})
    ]

    for ui <- Map.keys(UI.layouts()), detail <- ["normal", "full"] do
      output = render(events, ui, detail)

      if ui == "narrative" do
        assert output =~ "1 START · Run 01"
        assert output =~ "2 END · Run 02 · reported"
        assert output =~ "1 END · Run 01 · failed"
      else
        assert output =~ "RUN parent START"
        assert output =~ "RUN child END · reported"
        assert output =~ "RUN parent END · failed"
      end

      assert output =~ "child evidence"
      assert output =~ "provider_offline"
      assert output =~ "unrecognized-event-evidence"
      assert output =~ "Run open: no closure recorded"
      refute output =~ "Run child: no closure recorded"
      refute output =~ "\e"
      assert output =~ "secret-prompt-evidence" == (detail == "full")
      pattern = if ui == "narrative", do: ~r/2 END · Run 02/, else: ~r/RUN child END/
      assert length(Regex.scan(pattern, output)) == 1
    end

    assert render(events, "blocks", "normal") =~ "↳ RUN parent · continuing display"
    assert render(events, "tree", "normal") =~ "│  ├─ RUN child START"
    assert render(events, "timeline", "normal") =~ "#3 [parent] model.call.requested"
  end

  test "all layouts match live and read-only replay for the same recorded execution" do
    db = Path.join(System.tmp_dir!(), "ui-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(db) end)
    core = start_supervised!({EventCore, path: db})

    EventCore.append!(
      core,
      Envelope.command("session.created", session_id: "ui", payload: %{session_id: "ui"})
    )

    reporters =
      for ui <- Map.keys(UI.layouts()), detail <- ["normal", "full"] do
        {:ok, io} = StringIO.open("")

        {:ok, pid} =
          Reporter.start_link(core: core, session_id: "ui", io: io, ui: ui, detail: detail)

        {ui, detail, io, pid}
      end

    runtime =
      start_supervised!(
        {Runtime,
         core: core, session_id: "ui", max_depth: 1, agents: Omunculus.Runtime.Agents.resolver()}
      )

    assert {:ok, %{result: "3"}} = Runtime.request(core, "count to 3", session_id: "ui")
    GenServer.stop(runtime)
    history = EventCore.stream(core, 0)

    for {ui, detail, io, pid} <- reporters do
      Reporter.finish(pid)
      {:ok, replay_io} = StringIO.open("")
      {:ok, replay} = Reporter.start_link(io: replay_io, mode: "Replay", ui: ui, detail: detail)
      assert :ok = Replay.read(db, "ui", &Reporter.event(replay, &1))
      Reporter.finish(replay)

      assert tl(String.split(elem(StringIO.contents(io), 1), "\n")) ==
               tl(String.split(elem(StringIO.contents(replay_io), 1), "\n"))

      StringIO.close(io)
      StringIO.close(replay_io)
    end

    assert EventCore.stream(core, 0) == history
  end

  test "invalid layout and detail fail before creating a run database" do
    db = Path.join(System.tmp_dir!(), "invalid-ui-#{System.unique_integer([:positive])}.sqlite3")

    for {flag, value} <- [{"--ui", "invented"}, {"--detail", "invented"}],
        args <- [["run", ".", "do work"], ["session", "replay", "id"]] do
      output =
        capture_io(:stderr, fn ->
          assert CLI.dispatch(args ++ ["--db", db, flag, value], %{}) == 2
        end)

      assert output =~ flag
      refute File.exists?(db)
    end
  end

  test "wrapped text preserves content and indentation including wide characters" do
    alias Omunculus.CLI.UI.Text
    content = "ação " <> String.duplicate("界🙂é", 20) <> " final"
    lines = Text.lines("    " <> content, 32, "│  ")
    assert Enum.all?(lines, &(Text.cells(&1) <= 32))
    assert Enum.all?(lines, &String.starts_with?(&1, "│      "))
    assert Enum.map_join(lines, &String.replace_prefix(&1, "│      ", "")) == content

    assert Text.lines("  first\n    second\n", 32, "│  ") == [
             "│    first",
             "│      second",
             "│  "
           ]
  end

  test "narrow layouts retain their left edge and blocks have only horizontal separators" do
    item = %{
      event: event(1, "custom.observation", "child", %{}),
      detail: "normal",
      instruction: nil,
      kind: :event,
      title: String.duplicate("long title ", 12),
      run_id: "child",
      depth: 1,
      timestamp: "2026-09-08T12:00:00Z",
      sequence: 1,
      lines: ["    " <> String.duplicate("nested content ", 20), "    second line"]
    }

    for {name, module} <- UI.layouts() do
      {state, _} = module.init(%{mode: "Replay", path: "session", width: 40})
      {_, lines} = module.event(item, state)
      assert Enum.all?(lines, &(Omunculus.CLI.UI.Text.cells(&1) <= 40))

      if name == "blocks" do
        refute Enum.join(lines) =~ ~r/[│├└┌]/u
        assert String.duplicate("─", 40) in lines
        assert Enum.any?(lines, &String.starts_with?(&1, "      nested"))
      else
        assert Enum.all?(lines, &String.starts_with?(&1, if(name == "tree", do: "│  ", else: "")))

        assert Enum.all?(
                 tl(lines),
                 &(&1 == "" or String.contains?(&1, "│") or String.starts_with?(&1, "┌──") or
                     String.starts_with?(&1, "└──"))
               )

        assert Enum.any?(
                 lines,
                 &String.contains?(
                   &1,
                   "│      nested"
                 )
               )
      end
    end
  end

  test "session analytics count recorded effects once and flag incomplete usage" do
    alias Omunculus.CLI.UI.Summary

    events = [
      event(1, "run.started", "r", %{"depth" => 2, "model" => "test-model"}),
      event(2, "model.call.requested", "r", %{}),
      event(3, "model.call.completed", "r", %{
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3, "total_tokens" => 10},
        "duration_ms" => 50
      }),
      event(4, "model.call.requested", "r", %{}),
      event(5, "model.call.failed", "r", %{"duration_ms" => 20}),
      event(6, "tool.call.requested", "r", %{}),
      event(7, "tool.call.completed", "r", %{"outcome" => "waiting", "duration_ms" => 4}),
      event(8, "run.completed", "r", %{
        "outcome" => "waiting",
        "usage" => %{"total_tokens" => 999},
        "checkpoint" => %{"usage" => %{"total_tokens" => 999}}
      })
    ]

    summary = Enum.reduce(events, Summary.new(), fn e, s -> Summary.event(s, e) end)
    rows = Map.new(Summary.rows(summary, %{"r" => %{closed?: true}}))
    assert rows["Total tokens"] == "10 (partial: 1/2)"
    assert rows["Model time sum (ms)"] == "70"
    assert rows["Reported cost (provider units)"] == "not recorded"
    assert rows["Work Items created / completed"] == "0 / 0"
    assert rows["Tools completed / waiting / error"] == "0 / 1 / 0"
    assert rows["Model calls completed / failed"] == "1 / 1"
    assert rows["Maximum depth"] == 2
    assert rows["Events"] == 8
    assert Enum.all?(Summary.render(summary, %{}, 40), &(Omunculus.CLI.UI.Text.cells(&1) <= 40))

    outputs =
      for ui <- Map.keys(UI.layouts()), detail <- ["normal", "full"] do
        output = render(events, ui, detail)
        assert length(String.split(output, "Session summary")) == 2
        {ui, List.last(String.split(output, "Session summary"))}
      end

    for {_ui, variants} <- Enum.group_by(outputs, &elem(&1, 0), &elem(&1, 1)),
        do: assert(length(Enum.uniq(variants)) == 1)
  end

  test "narrative pairs concurrent actions by recorded causation, preserving order" do
    events = [
      event(1, "run.started", "a", %{"agent_id" => "concierge"}),
      event(2, "tool.call.requested", "a", %{
        "tool" => "counter",
        "tool_call_id" => "reused",
        "round" => 1
      }),
      event(3, "run.started", "b", %{"agent_id" => "worker"}),
      event(4, "tool.call.requested", "b", %{
        "tool" => "counter",
        "tool_call_id" => "reused",
        "round" => 1
      }),
      %{
        event(5, "tool.call.completed", "b", %{
          "tool" => "counter",
          "outcome" => "error",
          "output" => "denied"
        })
        | causation_id: "event-4"
      },
      %{
        event(6, "tool.call.completed", "a", %{
          "tool" => "counter",
          "outcome" => "completed",
          "output" => "value: 1"
        })
        | causation_id: "event-2"
      },
      event(7, "run.completed", "a", %{"outcome" => "waiting", "comment" => "delegated work"})
    ]

    output = render(events, "narrative", "normal")
    assert output =~ "2 START · Run 01 · Tool counter"
    assert output =~ "4 END · Run 02 · Tool counter · failed"
    assert output =~ "2 END · Run 01 · Tool counter · completed"
    assert output =~ "1 END · Run 01 · waiting"
    assert output =~ "3 OPEN · Run 02"
    refute output =~ "start not recorded"
    {b, _} = :binary.match(output, "4 END")
    {a, _} = :binary.match(output, "2 END")
    assert b < a
    refute output =~ "Work Item 01 completed"
  end

  test "narrative restores the original run dividers and spacing" do
    events = [
      event(1, "run.started", "a", %{"agent_id" => "worker"}),
      event(2, "run.completed", "a", %{"outcome" => "waiting", "comment" => "handoff"}),
      event(3, "run.started", "b", %{"agent_id" => "worker"}),
      event(4, "run.failed", "b", %{"reason" => "provider_offline"}),
      event(5, "run.started", "open", %{})
    ]

    for detail <- ["normal", "full"] do
      output = render(events, "narrative", detail)

      markers =
        output
        |> String.split("\n")
        |> Enum.filter(&(String.starts_with?(&1, "┌──") or String.starts_with?(&1, "└──")))

      assert Enum.count(markers, &String.starts_with?(&1, "┌── Run started")) == 3

      assert Enum.count(
               markers,
               &(String.starts_with?(&1, "└──") and not String.starts_with?(&1, "└── Summary") and
                   not String.starts_with?(&1, "└── Awaiting") and
                   not String.starts_with?(&1, "└── Snapshot"))
             ) == 2

      assert Enum.all?(markers, &(String.ends_with?(&1, "─────") and String.length(&1) == 100))
      {comment, _} = :binary.match(output, "handoff")
      {closing, _} = :binary.match(output, "└── Waiting")
      assert comment < closing
      assert output =~ "│\n│ 1 END · Run 01 · waiting\n└── Waiting"
      assert output =~ "└── Failed ─"

      if detail == "full" do
        {technical, _} = :binary.match(output, "Technical event #2")
        assert technical < closing
      end
    end
  end

  test "narrative frames task completion and assessment comments before their footers" do
    events = [
      event(1, "task.assessment_requested", nil, %{"reviewer" => "parent"}),
      event(2, "task.completed", nil, %{"comment" => "completion evidence"}),
      event(3, "task.assessment_resolved", nil, %{
        "request_id" => "event-1",
        "comment" => "assessment evidence"
      })
    ]

    for detail <- ["normal", "full"] do
      output = render(events, "narrative", detail)
      assert output =~ "┌── Assessment started ─"
      assert output =~ "┌── Recorded event ─"
      assert output =~ "└── Recorded ─"
      assert output =~ "└── Assessment resolved ─"
      assert output =~ "┌── Session summary ─"
      assert output =~ "└── Summary end ─"
      refute output =~ "├─●"
      {completion, _} = :binary.match(output, "completion evidence")
      {done, _} = :binary.match(output, "└── Recorded")
      {assessment, _} = :binary.match(output, "assessment evidence")
      {resolved, _} = :binary.match(output, "└── Assessment resolved")
      assert completion < done and done < assessment and assessment < resolved
    end
  end

  test "narrative never nests frames or prints orphaned result bodies" do
    events = [
      event(1, "run.started", "r", %{}),
      event(2, "model.call.requested", "r", %{"round" => 1}),
      %{event(3, "model.call.completed", "r", %{"round" => 1}) | causation_id: "event-2"},
      event(4, "run.completed", "r", %{"outcome" => "reported", "comment" => "run evidence"}),
      event(5, "task.completed", nil, %{"comment" => "task evidence"}),
      event(6, "task.assessment_resolved", nil, %{"comment" => "assessment evidence"})
    ]

    for detail <- ["normal", "full"] do
      output = render(events, "narrative", detail)
      assert output =~ "┌── Run result"
      assert output =~ "┌── Assessment result"
      refute output =~ "│\n│\n"
      refute output =~ "\n\n\n"

      open =
        Enum.reduce(String.split(output, "\n"), false, fn line, open ->
          cond do
            String.starts_with?(line, "┌──") ->
              refute open, "nested frame: #{line}"
              true

            String.starts_with?(line, "└──") ->
              assert open, "orphan footer: #{line}"
              false

            String.starts_with?(line, "│") ->
              assert open, "orphan content: #{line}"
              open

            true ->
              open
          end
        end)

      refute open
    end
  end

  defp event(seq, type, run, payload),
    do: %Envelope{
      event_id: "event-#{seq}",
      kind: :event,
      schema_version: "1",
      correlation_id: "correlation",
      sequence: seq,
      type: type,
      run_id: run,
      occurred_at: "2026-09-08T12:00:00Z",
      payload: payload
    }

  defp render(events, ui, detail) do
    {:ok, io} = StringIO.open("")
    {:ok, pid} = Reporter.start_link(io: io, mode: "Replay", ui: ui, detail: detail)
    for event <- events ++ [List.last(events)], do: Reporter.event(pid, event)
    Reporter.finish(pid)
    output = elem(StringIO.contents(io), 1)
    StringIO.close(io)
    output
  end
end
