defmodule Omunculus.Tools.Steps do
  @moduledoc """
  The steps an agent's tools chain that the agent does not have, groups
  expanded: a call to such a tool would be refused at its first missing
  step. Only a tool that ends its run (a manifest with `then`) chains all
  its `chains` on every call; another's, `reply`'s, are what a call may
  chain. An agent that never holds a work — on no stage of the workflows
  its depth requires, or at a free depth whose depth below requires a
  workflow it does not delegate — runs only such a tool's `then`: the
  other steps act on the run's work, as `work`'s `comment` and `delegate`.
  The tools that propose a change check it before the person is asked.
  """

  alias Omunculus.Config
  alias Omunculus.Tool.Catalog

  @doc "One line for each step one of `agents` lacks in `config`."
  @spec missing(Config.t(), [String.t()]) :: [String.t()]
  def missing(%Config{} = config, agents) do
    catalog = Catalog.discover(config.tools)
    groups = Catalog.groups(catalog)

    for name <- Enum.sort(agents),
        %{ceiling: ceiling} = agent <- [config.agents[name]],
        has = Enum.flat_map(ceiling.granted, &Map.get(groups, &1, [&1])),
        tool <- Enum.sort(Enum.uniq(has)),
        %{chains: chains, then: [_ | _] = then} <- [catalog[tool]],
        step <- if(holds_works?(config, name, agent.depth, groups), do: chains, else: then),
        step not in has,
        do: "#{name}: #{tool} runs #{step}, which #{name} lacks"
  end

  defp holds_works?(config, name, depth, groups) do
    case Config.workflows_for(config, depth) do
      [] ->
        not captured_below?(config, name, depth, groups)

      required ->
        Enum.any?(required, fn workflow ->
          Enum.any?(config.workflows[workflow], &(&1.agent == name))
        end)
    end
  end

  # The depth below requires a workflow and this agent cannot hand a root
  # down, so that workflow takes the work. A granted group counts as the
  # tools it expands to.
  defp captured_below?(config, name, depth, groups) do
    granted =
      Enum.flat_map(config.agents[name].ceiling.granted, &Map.get(groups, &1, [&1]))

    Config.workflows_for(config, depth + 1) != [] and "delegate" not in granted
  end
end
