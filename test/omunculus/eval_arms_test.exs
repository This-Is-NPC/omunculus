Code.require_file("../../eval/lib/arms.ex", __DIR__)

defmodule Omunculus.EvalArmsTest do
  use ExUnit.Case, async: true

  alias EquivalentExchange.Arms

  defp execution(task, passed, cost, seconds, extra \\ %{}) do
    {score, extra} = Map.pop(extra, "score", %{})

    Map.merge(
      %{
        "task" => task,
        "outcome" => "done",
        "duration_ms" => seconds * 1000,
        "usage" => %{"cost" => cost},
        "requests" => [],
        "score" =>
          Map.merge(
            %{
              "passed" => passed,
              "tokens" => 100,
              "repeated_after_handoff" => 0,
              "human_requests" => 0,
              "breaks" => 0,
              "reopened" => 0,
              "checks" => %{}
            },
            score
          )
      },
      extra
    )
  end

  defp folder(executions) do
    dir = Path.join(System.tmp_dir!(), "arms-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    for {execution, index} <- Enum.with_index(executions) do
      path = Path.join([dir, "executions", execution["task"], "cfg", "#{index}"])
      File.mkdir_p!(path)
      File.write!(Path.join(path, "execution.json"), Jason.encode!(execution))
    end

    dir
  end

  test "the exact two-sided sign test" do
    assert Arms.p_value(6, 0) == 0.03125
    assert Arms.p_value(5, 0) == 0.0625
    assert Arms.p_value(3, 3) == 1.0
    assert_in_delta Arms.p_value(1, 5), 0.21875, 1.0e-9
  end

  test "rows pair tasks, average repetitions and count what was recorded" do
    a =
      Arms.load(
        folder([
          execution("t1", true, 1.0, 10, %{
            "score" => %{
              "human_requests" => 1,
              "breaks" => 1,
              "reopened" => 2,
              "checks" => %{"a" => true},
              "checks_held" => 1
            }
          }),
          execution("t1", false, 3.0, 30),
          execution("only-a", true, 1.0, 1)
        ])
      )

    b = Arms.load(folder([execution("t1", true, 0.5, 20), execution("only-b", true, 1.0, 1)]))
    [row] = Arms.rows(a, b)

    assert row.task == "t1"
    assert row.runs == {2, 1}
    assert row.metrics.passed == {0.5, 1.0}
    assert row.metrics.cost == {2.0, 0.5}
    assert row.metrics.seconds == {20.0, 20.0}
    assert row.metrics.human == {0.5, 0.0}
    assert row.metrics.recovery == {1.5, 0.0}
    assert row.metrics.checks == {1.0, nil}
  end

  test "the sign test counts which arm is better by the metric's direction" do
    rows =
      for {x, y} <- [{0.0, 1.0}, {0.0, 1.0}, {1.0, 0.0}, {1.0, 1.0}],
          do: %{metrics: %{passed: {x, y}, cost: {y, x}}}

    assert %{b: 2, a: 1, ties: 1} = Arms.sign(rows, :passed, :higher)
    assert %{b: 2, a: 1, ties: 1} = Arms.sign(rows, :cost, :lower)
  end

  test "a small sample says it cannot conclude" do
    a = folder([execution("t1", false, 2.0, 10), execution("t2", false, 2.0, 10)])
    b = folder([execution("t1", true, 1.0, 5), execution("t2", true, 1.0, 5)])
    report = Arms.report(a, b)

    assert report =~ "Too small to conclude anything"
    assert report =~ "Few repetitions"
    assert report =~ "too few tasks differ (2; 6 are needed"
    assert report =~ "| t1 | 1/1 |"
    assert report =~ "0.0 / 1.0 / +1.0"
  end

  test "enough differing tasks reaches a verdict, and a cap is flagged" do
    tasks = for n <- 1..7, do: "t#{n}"
    a = folder(for(t <- tasks, do: execution(t, false, 2.0, 10, %{"outcome" => "budget"})))
    b = folder(for t <- tasks, do: execution(t, true, 1.0, 5))
    report = Arms.report(a, b)

    refute report =~ "Too small"
    assert report =~ "7 execution(s) stopped at the USD cap"
    assert report =~ "single agent better (p = 0.016)"
  end
end
