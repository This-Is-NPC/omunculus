defmodule Omunculus.Tools.RunsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Runs

  defp event(type, body), do: %{type: type, body: Jason.encode!(body)}

  defp run(id, agent, events, extra) do
    Map.merge(
      %{
        id: id,
        agent: agent,
        depth: "1",
        via: nil,
        started_at: "2026-01-01T00:00:00Z",
        finished_at: "2026-01-01T00:00:07Z",
        work_title: nil,
        events: events
      },
      extra
    )
  end

  defp call(args, runs) do
    assert %{"ok" => ok, "output" => output} = Runs.run(%{args: args, view: %{"recent" => runs}})
    {ok, output}
  end

  defp ended,
    do:
      run(
        "aaa111",
        "surgeon",
        [
          event("tool", %{
            "name" => "assemble",
            "args" => %{},
            "ok" => true,
            "output" => "prompt"
          }),
          event("model", %{
            "content" => [%{"type" => "text", "text" => "Reading the plan."}],
            "usage" => %{
              "input_tokens" => 100,
              "cache_read_input_tokens" => 40,
              "output_tokens" => 20,
              "cost" => 0.01
            }
          }),
          event("tool", %{
            "name" => "read",
            "args" => %{"path" => "plan.md"},
            "ok" => true,
            "output" => "# plan"
          }),
          event("tool", %{
            "name" => "read",
            "args" => %{"path" => "gone.md"},
            "ok" => false,
            "output" => "no such file: gone.md"
          }),
          event("tool", %{
            "name" => "done",
            "args" => %{"report" => "built"},
            "ok" => true,
            "output" => ""
          }),
          event("tool", %{
            "name" => "end",
            "args" => %{},
            "ok" => true,
            "output" => "",
            "via" => "done"
          }),
          event("end", %{}),
          event("tool", %{"name" => "on-continue", "args" => %{}, "ok" => true, "output" => ""})
        ],
        %{
          work_title: "page: menu",
          work_state: "done",
          work_workflow: "page",
          work_stage: "build"
        }
      )

  defp stopped,
    do:
      run(
        "bbb222",
        "clerk",
        [
          event("model", %{
            "content" => "thinking",
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2}
          })
        ],
        %{via: "retry"}
      )

  test "sums up each run: its work, how it ended, its calls, what failed and what the model used" do
    {true, output} = call(%{}, [ended(), stopped()])

    assert output =~ "2 runs, newest first."

    assert output =~
             ~s(run aaa111 · surgeon · depth 1 · 2026-01-01T00:00:00Z · 7 s · work "page: menu" [done] · page, stage build)

    assert output =~ "ended: done\n  calls: 3 — read×2, done"
    assert output =~ "failed: read — no such file: gone.md"
    assert output =~ "model: 1 replies · 140 tokens in (40 cached) · 20 out · $0.0100"

    assert output =~
             "run bbb222 · clerk · depth 1 · 2026-01-01T00:00:00Z · 7 s · no work · via retry\n  ended: stopped without end"

    assert output =~ "model: 1 replies · 10 tokens in (0 cached) · 2 out"
  end

  test "keeps one agent's runs, and fewer of them" do
    {true, output} = call(%{"agent" => "clerk"}, [ended(), stopped()])
    assert output =~ "1 runs" and output =~ "bbb222" and not (output =~ "aaa111")

    {true, output} = call(%{"limit" => "1"}, [ended(), stopped()])
    assert output =~ "aaa111" and not (output =~ "bbb222")

    assert {true, "No closed run."} = call(%{"agent" => "nobody"}, [ended()])
  end

  test "gives one run call by call, by its id or the start of it" do
    {true, output} = call(%{"run" => "aaa"}, [ended(), stopped()])

    assert output =~ "2. model: Reading the plan."
    assert output =~ ~s(3. read {"path":"plan.md"} → ok: # plan)
    assert output =~ ~s(4. read {"path":"gone.md"} → failed: no such file: gone.md)

    assert {false, "no run zzz among the last 2 closed runs"} =
             call(%{"run" => "zzz"}, [ended(), stopped()])
  end

  test "reads a model event recorded as plain text, as recovery records an interrupted run" do
    interrupted =
      run(
        "ccc333",
        "clerk",
        [%{type: "model", body: "Run interrupted: the process running it stopped."}],
        %{}
      )

    {true, output} = call(%{}, [interrupted])
    assert output =~ "ended: stopped without end"
    assert output =~ "model: 1 replies · 0 tokens in (0 cached) · 0 out"

    {true, output} = call(%{"run" => "ccc"}, [interrupted])
    assert output =~ "1. model: Run interrupted: the process running it stopped."
  end
end
