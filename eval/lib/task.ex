defmodule EquivalentExchange.Task do
  @moduledoc """
  One task of `eval/tasks/<scenario>/<name>/`, or of a pack's
  `packs/<pack>/tasks/<scenario>/<name>/`, its id then led by the pack's
  name: its `instruction.md`, its
  `task.toml` — the scenario, whether it is critical, the configurations it
  runs under, the names it needs, the names no agent may grant
  (`forbidden`), the outcomes it may end in (`[expect]`, overridden under
  `[expect.configurations.<name>]`) and how the simulated human answers a
  request for each name (`[human]`, deny when unnamed) and what the decider
  rates of its files (`[[judge]]`, each an `id`, a `question` and the
  `files` it reads), and the tools it is about (`uses`: a tool's name, or
  `bash:<text>` for a command holding it), the person it simulates in
  conversation (`[person]`: the `facts` they answer the agent's questions
  with, and the `follow_ups` they send, in order, once the agent asks
  nothing more), and whether it publishes to the deploy environment
  (`deploy`) — its
  starting `workspace/`, its `check` and its `solution/`.
  """

  @eval Path.expand("..", __DIR__)
  @packs Path.expand("../../packs", __DIR__)
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
    :human,
    :judge,
    :uses,
    :person,
    :deploy
  ]
  defstruct @enforce_keys

  @spec all() :: [%__MODULE__{}]
  def all do
    own =
      for file <- Path.wildcard(Path.join([@eval, "tasks", "*", "*", "task.toml"])),
          do: {file, ""}

    packs =
      for file <- Path.wildcard(Path.join([@packs, "*", "tasks", "*", "*", "task.toml"])),
          do: {file, Path.relative_to(file, @packs) |> Path.split() |> hd() |> Kernel.<>("/")}

    (own ++ packs)
    |> Enum.sort()
    |> Enum.map(fn {file, lead} -> file |> Path.dirname() |> load!(lead) end)
  end

  defp load!(dir, lead) do
    data = Toml.decode_file!(Path.join(dir, "task.toml"))
    expect = Map.get(data, "expect", %{})

    %__MODULE__{
      id: lead <> (dir |> Path.split() |> Enum.take(-2) |> Path.join()),
      dir: dir,
      instruction: dir |> Path.join("instruction.md") |> File.read!() |> String.trim(),
      scenario: Map.fetch!(data, "scenario"),
      critical: Map.get(data, "critical", false),
      configurations: Map.fetch!(data, "configurations"),
      needs: Map.get(data, "needs", []),
      forbidden: Map.get(data, "forbidden", []),
      expect: expect,
      human: Map.get(data, "human", %{}),
      judge: Map.get(data, "judge", []),
      uses: Map.get(data, "uses", []),
      person: Map.get(data, "person"),
      deploy: Map.get(data, "deploy", false)
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

  @doc """
  Runs the task's check on `workspace` with the run's `outcome`: {passed,
  what it said, whether the workspace holds, whatever the run's ending}.
  """
  @spec check(%__MODULE__{}, String.t(), map) :: {boolean, String.t(), boolean}
  def check(task, workspace, outcome) do
    file = Path.join(System.tmp_dir!(), "ee-outcome-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(outcome))

    try do
      {said, status} =
        System.cmd(Path.join(task.dir, "check"), [workspace, file],
          env: [{"PYTHONPATH", Path.join([@eval, "tasks", "_lib"])}],
          stderr_to_stdout: true
        )

      {status == 0, String.trim(said), status in [0, 2]}
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

    unless Map.get(task.expect, "report") in [nil, "asks"],
      do: raise("#{task.id}: [expect] report is \"asks\" or left out")

    unless Enum.all?(Map.values(task.human), &(&1 in ["grant", "deny"])),
      do: raise("#{task.id}: the human answers only grant or deny")

    unless Enum.all?(task.judge, &(Map.keys(&1) |> Enum.sort() == ~w(files id question))),
      do: raise("#{task.id}: a [[judge]] has an id, a question and the files it reads")

    unless is_nil(task.person) or
             (is_binary(task.person["facts"]) and
                Map.keys(task.person) -- ~w(facts follow_ups) == []),
           do: raise("#{task.id}: [person] has facts and, optionally, follow_ups")

    task
  end
end
