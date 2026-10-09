defmodule EquivalentExchange.Task do
  @moduledoc """
  One task of `eval/tasks/<scenario>/<name>/`: its `instruction.md`, its
  `task.toml` — the scenario, whether it is critical, the configurations it
  runs under, the names it needs, the names no agent may grant
  (`forbidden`), the outcomes it may end in (`[expect]`, overridden under
  `[expect.configurations.<name>]`) and how the simulated human answers a
  request for each name (`[human]`, deny when unnamed) — its starting
  `workspace/`, its `check` and its `solution/`.
  """

  @eval Path.expand("..", __DIR__)
  @outcomes ~w(answer done break waiting)

  @enforce_keys [
    :id,
    :dir,
    :instruction,
    :scenario,
    :critical,
    :configurations,
    :needs,
    :forbidden,
    :expect,
    :human
  ]
  defstruct @enforce_keys

  @spec all() :: [%__MODULE__{}]
  def all do
    Path.join([@eval, "tasks", "*", "*", "task.toml"])
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> Path.dirname() |> load!()))
  end

  @spec load!(String.t()) :: %__MODULE__{}
  def load!(dir) do
    data = Toml.decode_file!(Path.join(dir, "task.toml"))
    expect = Map.get(data, "expect", %{})

    %__MODULE__{
      id: Path.relative_to(dir, Path.join(@eval, "tasks")),
      dir: dir,
      instruction: dir |> Path.join("instruction.md") |> File.read!() |> String.trim(),
      scenario: Map.fetch!(data, "scenario"),
      critical: Map.get(data, "critical", false),
      configurations: Map.fetch!(data, "configurations"),
      needs: Map.get(data, "needs", []),
      forbidden: Map.get(data, "forbidden", []),
      expect: expect,
      human: Map.get(data, "human", %{})
    }
    |> validate!()
  end

  @doc "The outcomes the task may end in under `configuration`."
  @spec outcomes(%__MODULE__{}, String.t()) :: [String.t()]
  def outcomes(task, configuration) do
    get_in(task.expect, ["configurations", configuration, "outcome"]) ||
      Map.fetch!(task.expect, "outcome")
  end

  @doc "How the simulated human answers a request for `name`: grant or deny."
  @spec answer(%__MODULE__{}, String.t()) :: String.t()
  def answer(task, name), do: Map.get(task.human, name, "deny")

  @doc "Runs the task's check on `workspace` with the run's `outcome`; {passed, what it said}."
  @spec check(%__MODULE__{}, String.t(), map) :: {boolean, String.t()}
  def check(task, workspace, outcome) do
    file = Path.join(System.tmp_dir!(), "ee-outcome-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(outcome))

    try do
      {said, status} =
        System.cmd(Path.join(task.dir, "check"), [workspace, file], stderr_to_stdout: true)

      {status == 0, String.trim(said)}
    after
      File.rm(file)
    end
  end

  defp validate!(task) do
    outcomes = [
      Map.fetch!(task.expect, "outcome")
      | Enum.map(Map.get(task.expect, "configurations", %{}), fn {_c, e} -> e["outcome"] end)
    ]

    unless Enum.all?(List.flatten(outcomes), &(&1 in @outcomes)),
      do: raise("#{task.id}: an expected outcome is not one of #{Enum.join(@outcomes, ", ")}")

    unless Enum.all?(Map.values(task.human), &(&1 in ["grant", "deny"])),
      do: raise("#{task.id}: the human answers only grant or deny")

    task
  end
end
