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
      assert output =~ "RUN parent START"
      assert output =~ "RUN child END · reported"
      assert output =~ "RUN parent END · failed"
      assert output =~ "child evidence"
      assert output =~ "provider_offline"
      assert output =~ "unrecognized-event-evidence"
      assert output =~ "Run open: no closure recorded"
      refute output =~ "Run child: no closure recorded"
      refute output =~ "\e"
      assert output =~ "secret-prompt-evidence" == (detail == "full")
      assert length(Regex.scan(~r/RUN child END/, output)) == 1
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
        assert Enum.all?(tl(lines), &String.contains?(&1, "│"))
        assert Enum.any?(lines, &String.contains?(&1, "│      nested"))
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
        List.last(String.split(output, "Session summary"))
      end

    assert length(Enum.uniq(outputs)) == 1
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
