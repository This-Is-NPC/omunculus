defmodule Omunculus.Tools.Steps do
  @moduledoc """
  The steps an agent's tools chain that the agent does not have, groups
  expanded: a call to such a tool would be refused at its first missing
  step. Only a tool that ends its run (a manifest with `then`) chains all
  its `chains` on every call; another's, `reply`'s, are what a call may
  chain. The tools that propose a change check
  it before the person is asked.
  """

  alias Omunculus.Config
  alias Omunculus.Tool.Catalog

  @doc "One line for each step one of `agents` lacks in `config`."
  @spec missing(Config.t(), [String.t()]) :: [String.t()]
  def missing(%Config{} = config, agents) do
    catalog = Catalog.discover(config.tools)
    groups = Catalog.groups(catalog)

    for name <- Enum.sort(agents),
        %{ceiling: ceiling} <- [config.agents[name]],
        has = Enum.flat_map(ceiling.granted, &Map.get(groups, &1, [&1])),
        tool <- Enum.sort(Enum.uniq(has)),
        %{chains: chains, then: [_ | _]} <- [catalog[tool]],
        step <- chains,
        step not in has,
        do: "#{name}: #{tool} runs #{step}, which #{name} lacks"
  end
end
