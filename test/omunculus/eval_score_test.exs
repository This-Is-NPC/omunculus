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
end
