defmodule Omunculus.Tools.SessionTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.{Out, Session}

  @instructions "You are the worker.\n\n## Tools\n- read"
  @now ~U[2026-10-09 12:00:10Z]

  defp event(type, body), do: %{type: type, body: Jason.encode!(body)}

  defp reply(calls),
    do: %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" =>
        Enum.map(calls, fn {id, name} ->
          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => name, "arguments" => "{}"}
          }
        end),
      "usage" => %{"prompt_tokens" => 10}
    }

  defp call(name, output, extra \\ %{}),
    do:
      event(
        "tool",
        Map.merge(%{"name" => name, "args" => %{}, "ok" => true, "output" => output}, extra)
      )

  # A run that read a file, then asked for access and paused.
  defp paused(id, events, fields \\ %{}) do
    Map.merge(
      %{
        id: id,
        agent: "worker",
        finished_at: "2026-10-09T12:00:00Z",
        assembled: @instructions <> "\n\n## Work\nFix it",
        events:
          [event("start-run", %{})] ++
            events ++
            [
              event("model", reply([{"c2", "request_access"}])),
              call("request_access", ""),
              call("end", "", %{"via" => "request_access"}),
              call("on-request", ""),
              event("end-run", %{})
            ]
      },
      fields
    )
  end

  defp split(assembled) do
    case String.split(assembled, "\n\n## Work", parts: 2) do
      [instructions, rest] -> {:ok, instructions, "## Work" <> rest}
      _no_context -> :error
    end
  end

  defp read_turn,
    do: [event("model", reply([{"c1", "read"}])), call("read", "file body")]

  defp given(fields \\ %{}),
    do:
      Map.merge(
        %{
          agent: "worker",
          now: @now,
          ttl_ms: 60_000,
          max_bytes: 100_000,
          split: &split/1,
          tool_output_bytes: nil,
          since: "## Request\ngranted"
        },
        fields
      )

  test "a paused run of the agent continues: its prompt, each reply with its outputs, then since" do
    assert %{"continues" => "r1", "instructions" => @instructions, "history" => history} =
             Session.history([paused("r1", read_turn())], given())

    assert [
             %{"user" => "## Work\nFix it"},
             %{"model" => first, "outputs" => ["file body"]},
             %{"model" => second, "outputs" => [""]},
             %{"user" => "## Request\ngranted"}
           ] = history

    refute Map.has_key?(first, "usage")
    assert get_in(second, ["tool_calls", Access.at(0), "id"]) == "c2"
  end

  test "outputs are cut as the model got them" do
    %{"history" => [_, %{"outputs" => [output]} | _]} =
      Session.history([paused("r1", read_turn())], given(%{tool_output_bytes: 4}))

    assert output == Out.cut("file body", 4)
  end

  test "a run that continued another goes back to the session's first run" do
    second =
      paused("r2", [event("session", %{"continues" => "r1", "since" => "## Results\nback"})])

    assert %{"continues" => "r2", "history" => history} =
             Session.history([paused("r1", read_turn()), second], given())

    assert [
             %{"user" => "## Work\nFix it"},
             %{"outputs" => ["file body"]},
             %{"outputs" => [""]},
             %{"user" => "## Results\nback"},
             %{"outputs" => [""]},
             %{"user" => "## Request\ngranted"}
           ] = history
  end

  test "the session starts over when it cannot continue exactly" do
    runs = fn fields -> [paused("r1", read_turn(), fields)] end

    for {why, runs, given} <- [
          {"another agent", runs.(%{agent: "other"}), given()},
          {"too old", runs.(%{}), given(%{ttl_ms: 5_000})},
          {"too large", runs.(%{}), given(%{max_bytes: 10})},
          {"a prompt without a context", runs.(%{assembled: @instructions}), given()},
          {"handed on", [paused("r1", [event("continue", %{})])], given()},
          {"opened a root of its own", [paused("r1", [event("work", %{"start" => true})])],
           given()},
          {"a call without its result", [paused("r1", [event("model", reply([{"c1", "read"}]))])],
           given()},
          {"a call through the sandbox bridge",
           [paused("r1", [event("model", reply([{"c1", "__omunculus_execute"}]))])], given()},
          {"a reply that is not a provider's", [paused("r1", [event("model", "plain text")])],
           given()}
        ] do
      assert Session.history(runs, given) == nil, why
    end

    assert Session.history([], given()) == nil
  end
end
