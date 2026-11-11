defmodule Omunculus.RequestRoutes do
  @moduledoc "Validates TOML request routes; the first matching rule selects its ordered destinations."
  alias Omunculus.Participant

  @doc """
  Validates `[policy] harness_route`: optional, and the name of a configured
  rule. It is the route of the harness's own requests (a work stopped past
  `[policy] max_retries`, a reopen past `max_reopens`, `propose_config` and
  `propose_pack`); absent, they take the default route.
  """
  @spec fetch_harness_route(map, [map]) :: {:ok, String.t() | nil} | {:error, term}
  def fetch_harness_route(data, routes) do
    case get_in(data, ["policy", "harness_route"]) do
      nil ->
        {:ok, nil}

      name when is_binary(name) ->
        if Enum.any?(routes, &(&1["name"] == name)),
          do: {:ok, name},
          else: {:error, {:policy, {:invalid, :harness_route}}}

      _invalid ->
        {:error, {:policy, {:invalid, :harness_route}}}
    end
  end

  @doc "Sends a harness request along the project's `harness_route`, when it declares one."
  @spec put_harness_route(map, Omunculus.Config.t()) :: map
  def put_harness_route(body, %{harness_route: nil}), do: body
  def put_harness_route(body, %{harness_route: name}), do: Map.put(body, "to", name)

  def parse(nil, _agents, _workflows), do: {:error, {:policy, {:required, :request_routes}}}

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
      Enum.all?(via, &(&1 in ["parent", "origin", "owners"] or identity?(&1, agents)))
  end

  defp valid_rule?(_rule, _agents, _workflows), do: false

  defp identity?(identity, agents),
    do:
      Participant.valid?(identity) and
        (identity["kind"] == "human" or Map.has_key?(agents, identity["agent"]))
end
