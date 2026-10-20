defmodule Omunculus.Tools.Steps do
  @moduledoc """
  The steps an agent's tools chain that the agent does not have, groups
  expanded: a call to such a tool would be refused at its first missing
  step. Only a tool that ends its run (a manifest with `then`) chains all
  its `chains` on every call; another's, `reply`'s, are what a call may
  chain. An agent that never holds a work — on no stage of the workflows
  its depth requires — runs only such a tool's `then`: the other steps act
  on the run's work, as `work`'s `comment` and `delegate`. The tools that
  propose a change check it before the person is asked.
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
        step <- if(holds_works?(config, name, agent.depth), do: chains, else: then),
        step not in has,
        do: "#{name}: #{tool} runs #{step}, which #{name} lacks"
  end

  defp holds_works?(config, name, depth) do
    case Config.workflows_for(config, depth) do
      [] ->
        true

      required ->
        Enum.any?(required, fn workflow ->
          Enum.any?(config.workflows[workflow], &(&1.agent == name))
        end)
    end
  end
end
