defmodule EquivalentExchange.Selftest do
  @moduledoc """
  Proves the checks and the scoring. Each task's check must pass on its
  starting workspace with its `solution/` applied — files written, paths
  deleted, `solution/solve` run, the outcome it gives — under every configuration it runs in, and
  fail on the starting workspace untouched with a `done` that claims
  success; a long-horizon case has no script, its checks are proved in
  `test/omunculus/eval_suite_test.exs`. Each execution of `eval/fixtures/scores` must score as its
  hand-made expectation says.
  """

  alias EquivalentExchange.{Score, Task}

  @fixtures Path.expand("../fixtures/scores", __DIR__)

  @spec run() :: :ok | {:error, [String.t()]}
  def run do
    checks =
      for task <- Task.all(),
          is_nil(task.suite),
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

  @doc "What fails in the proof of `task` under `configuration`: empty when its check holds."
  @spec problems(%EquivalentExchange.Task{}, String.t()) :: [String.t()]
  def problems(task, configuration) do
    solution = Jason.decode!(File.read!(Path.join([task.dir, "solution", "outcome.json"])))

    [solved, untouched] =
      for _ <- 1..2,
          do: Path.join(System.tmp_dir!(), "ee-selftest-#{System.unique_integer([:positive])}")

    {passed, claimed} =
      try do
        workspace(task, solution, solved)
        workspace(task, nil, untouched)

        {Task.check(task, solved, Map.merge(solution, %{"configuration" => configuration})),
         Task.check(task, untouched, %{
           "outcome" => "done",
           "report" => "Done.",
           "configuration" => configuration
         })}
      after
        File.rm_rf!(solved)
        File.rm_rf!(untouched)
      end

    case {passed, claimed} do
      {{true, _, _}, {false, _, _}} -> []
      {{false, said, _}, _} -> ["the solution fails: " <> said]
      {_, {true, _, _}} -> ["an untouched workspace claimed done passes"]
    end
  end

  defp workspace(task, solution, dir) do
    File.mkdir_p!(dir)
    start = Path.join(task.dir, "workspace")
    if File.dir?(start), do: File.cp_r!(start, dir)

    if solution do
      files = Path.join([task.dir, "solution", "files"])
      if File.dir?(files), do: File.cp_r!(files, dir)
      Enum.each(solution["delete"] || [], &File.rm_rf!(Path.join(dir, &1)))
      solve(task, dir)
    end
  end

  # An executable `solution/solve` is run in the workspace, as imported tasks
  # carry their solution; `SOLUTION_DIR` names its folder.
  defp solve(task, dir) do
    script = Path.join([task.dir, "solution", "solve"])

    if File.regular?(script) do
      {said, status} =
        System.cmd("bash", [script],
          cd: dir,
          env: [{"SOLUTION_DIR", Path.dirname(script)}],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("#{task.id}: solution/solve exited #{status}: #{said}")
    end
  end
end
