defmodule EquivalentExchange.Selftest do
  @moduledoc """
  Proves the checks: each task's check must pass on its starting workspace
  with its `solution/` applied — files written, paths deleted, the outcome
  it gives — under every configuration it runs in, and fail on the starting
  workspace untouched with a `done` that claims success.
  """

  alias EquivalentExchange.Task

  @spec run() :: :ok | {:error, [String.t()]}
  def run do
    problems =
      for task <- Task.all(),
          configuration <- task.configurations,
          problem <- problems(task, configuration),
          do: "#{task.id} (#{configuration}): #{problem}"

    if problems == [], do: :ok, else: {:error, problems}
  end

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
      {{true, _}, {false, _}} -> []
      {{false, said}, _} -> ["the solution fails: " <> said]
      {_, {true, _}} -> ["an untouched workspace claimed done passes"]
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
