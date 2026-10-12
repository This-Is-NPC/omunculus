defmodule Omunculus.RequestRoutes do
  @moduledoc "Validates TOML request routes; the first matching rule selects its ordered destinations."
  alias Omunculus.Participant

  def parse(routes, agents, workflows) when is_list(routes) and routes != [] do
    if Enum.all?(routes, &valid_rule?(&1, agents, workflows)),
      do: {:ok, routes},
      else: {:error, {:policy, {:invalid, :request_routes}}}
  end

  def parse(_routes, _agents, _workflows), do: {:error, {:policy, {:invalid, :request_routes}}}

  defp valid_rule?(%{"via" => via} = rule, agents, workflows) when is_list(via) and via != [] do
    Map.keys(rule) -- ~w(name from workflow stage via) == [] and
      Enum.all?(
        ~w(name workflow stage),
        &(not Map.has_key?(rule, &1) or (is_binary(rule[&1]) and rule[&1] != ""))
      ) and
      (not Map.has_key?(rule, "from") or identity?(rule["from"], agents)) and
      (not Map.has_key?(rule, "workflow") or Map.has_key?(workflows, rule["workflow"])) and
      (not Map.has_key?(rule, "stage") or
         (Map.has_key?(rule, "workflow") and
            Enum.any?(workflows[rule["workflow"]] || [], &(&1.name == rule["stage"])))) and
      Enum.all?(via, &(&1 in ["parent", "origin"] or identity?(&1, agents)))
  end

  defp valid_rule?(_rule, _agents, _workflows), do: false

  defp identity?(identity, agents),
    do:
      Participant.valid?(identity) and
        (identity["kind"] == "human" or Map.has_key?(agents, identity["agent"]))
end
