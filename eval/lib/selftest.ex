defmodule EquivalentExchange.Selftest do
  @moduledoc """
  Proves the checks and the scoring. Each task's check must pass on its
  starting workspace with its `solution/` applied — files written, paths
  deleted, the outcome it gives — under every configuration it runs in, and
  fail on the starting workspace untouched with a `done` that claims
  success. Each execution of `eval/fixtures/scores` must score as its
  hand-made expectation says.
  """

  alias EquivalentExchange.{Score, Task}

  @fixtures Path.expand("../fixtures/scores", __DIR__)

  @spec run() :: :ok | {:error, [String.t()]}
  def run do
    checks =
      for task <- Task.all(),
          configuration <- task.configurations,
          problem <- problems(task, configuration),
          do: "#{task.id} (#{configuration}): #{problem}"

    problems = checks ++ scoring()
    if problems == [], do: :ok, else: {:error, problems}
  end

  defp scoring do
    Enum.flat_map(Path.wildcard(Path.join(@fixtures, "*.json")), fn path ->
      %{"execution" => execution, "expected" => expected} =
        path |> File.read!() |> Jason.decode!()

      score = Score.score(execution)

      for {key, wanted} <- expected,
          got = scored(score, key),
          got != wanted,
          do: "#{Path.basename(path)}: #{key} is #{inspect(got)}, not #{inspect(wanted)}"
    end)
  end

  defp scored(score, "causes"), do: Enum.map(score.findings, & &1.cause)
  defp scored(score, key), do: Map.fetch!(score, String.to_existing_atom(key))

  defp problems(task, configuration) do
    solution = Jason.decode!(File.read!(Path.join([task.dir, "solution", "outcome.json"])))
    solved = workspace(task, solution)
    untouched = workspace(task, nil)

    passed = Task.check(task, solved, Map.merge(solution, %{"configuration" => configuration}))

    claimed =
      Task.check(task, untouched, %{
        "outcome" => "done",
        "report" => "Done.",
        "configuration" => configuration
      })

    File.rm_rf!(solved)
    File.rm_rf!(untouched)

    case {passed, claimed} do
      {{true, _, _}, {false, _, _}} -> []
      {{false, said, _}, _} -> ["the solution fails: " <> said]
      {_, {true, _, _}} -> ["an untouched workspace claimed done passes"]
    end
  end

  defp workspace(task, solution) do
    dir = Path.join(System.tmp_dir!(), "ee-selftest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(task.dir, "workspace"), dir)

    if solution do
      files = Path.join([task.dir, "solution", "files"])
      if File.dir?(files), do: File.cp_r!(files, dir)
      Enum.each(solution["delete"] || [], &File.rm_rf!(Path.join(dir, &1)))
    end

    dir
  end
end
