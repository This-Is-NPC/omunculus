Code.require_file("../../eval/lib/score.ex", __DIR__)

defmodule Omunculus.EvalScoreTest do
  use ExUnit.Case, async: true
  alias EquivalentExchange.Score

  @fixture Path.expand("../../eval/fixtures/scores/passed-unexercised.json", __DIR__)

  # A recorded execution of a negotiated configuration that needs `bash`.
  defp execution(overrides) do
    @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("execution") |> Map.merge(overrides)
  end

  defp request(depth),
    do: %{
      "names" => ["bash"],
      "arbiter" => "father",
      "status" => "closed",
      "asks" => ["bash"],
      "depth" => depth
    }

  test "a negotiating configuration that passed with no request is not exercised" do
    score = Score.score(execution(%{"requests" => []}))

    assert score.passed
    assert score.exercised == false
    assert Enum.any?(score.findings, &(&1.reason =~ "negotiation was not exercised"))
  end

  test "a request from depth 0 alone does not exercise the negotiation" do
    assert Score.score(execution(%{"requests" => [request("0")]})).exercised == false
  end

  test "a request from below depth 0 exercises it" do
    assert Score.score(execution(%{"requests" => [request("0"), request("1")]})).exercised
  end

  test "a configuration that does not negotiate, or a task that needs nothing, has none" do
    assert Score.score(execution(%{"configuration" => "delegation"})).exercised == nil
    assert Score.score(execution(%{"scenario" => "unneeded"})).exercised == nil
    assert Score.score(execution(%{"needs" => []})).exercised == nil
  end

  describe "repeated_after_handoff" do
    defp call(run, name, args, via \\ nil),
      do: %{"name" => name, "ok" => true, "run" => run, "via" => via, "args" => args}

    defp handoff(runs, tools) do
      Score.score(execution(%{"runs" => runs, "tool_calls" => tools})).repeated_after_handoff
    end

    test "counts the calls of a run that the run before it on the work made" do
      runs = [
        %{"id" => "r1", "work" => "w1", "depth" => "0", "via" => "send"},
        %{"id" => "r2", "work" => "w1", "depth" => "0", "via" => "retry"}
      ]

      tools = [
        call("r1", "read", "a"),
        call("r1", "bash", "b"),
        call("r2", "read", "a"),
        call("r2", "bash", "c"),
        call("r2", "comment", "a", "done")
      ]

      assert handoff(runs, tools) == 1
    end

    test "ignores runs of other works and a call of two runs apart" do
      runs = [
        %{"id" => "r1", "work" => "w1", "depth" => "0", "via" => "send"},
        %{"id" => "r2", "work" => "w2", "depth" => "0", "via" => "send"},
        %{"id" => "r3", "work" => "w1", "depth" => "0", "via" => "retry"},
        %{"id" => "r4", "work" => "w1", "depth" => "0", "via" => "retry"}
      ]

      tools = [call("r1", "read", "a"), call("r2", "read", "a"), call("r4", "read", "a")]
      assert handoff(runs, tools) == 0
      assert handoff(runs, [call("r3", "read", "a"), call("r4", "read", "a")]) == 1
    end

    test "is not known for an execution recorded without call args" do
      refute Score.score(execution(%{})).repeated_after_handoff
    end
  end
end
