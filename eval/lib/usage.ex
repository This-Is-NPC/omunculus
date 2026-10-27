defmodule EquivalentExchange.Usage do
  @moduledoc "Aggregates provider usage with the price of each agent's configured model."

  # What the provider reported of each model call, and of the prompt it
  # served from its cache: overall, on the first call of each run, and by
  # agent.
  @spec summarize(map, map, map) :: map
  def summarize(facts, config, prices) do
    agents = Map.new(facts.runs, &{&1.id, &1.agent})

    calls =
      for event <- facts.events, response?(event) do
        usage = event.body["usage"]
        agent = agents[event.run_id]
        model = config.agents |> Map.fetch!(agent) |> Map.fetch!(:model)
        id = config.models |> Map.fetch!(model) |> get_in([:input, "model"])
        %{run: event.run_id, agent: agent, usage: tokens(usage, prices[id])}
      end

    firsts = calls |> Enum.uniq_by(& &1.run) |> Enum.map(& &1.usage)
    usages = Enum.map(calls, & &1.usage)

    %{
      calls: Enum.count(facts.events, &(&1.type == "model")),
      input_tokens: sum(usages, :prompt),
      output_tokens: sum(usages, :output),
      cost: sum(usages, :cost),
      cache: cache(usages),
      first_call_cache: cache(firsts),
      cache_by_agent:
        calls |> Enum.group_by(& &1.agent, & &1.usage) |> Map.new(fn {a, u} -> {a, cache(u)} end)
    }
  end

  @doc "Whether `event` is a model call the provider reported usage for."
  @spec response?(map) :: boolean
  def response?(%{type: "model", body: %{"usage" => usage}}), do: is_map(usage)
  def response?(_event), do: false

  # One call's tokens in one shape. OpenRouter sends the OpenAI fields and
  # the cost; Anthropic sends its own, with the cache apart from the
  # input, and no cost, which its price per million tokens gives.
  defp tokens(%{"input_tokens" => input} = usage, price) do
    write = usage["cache_creation_input_tokens"] || 0
    read = usage["cache_read_input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      prompt: input + write + read,
      cached: read,
      write: write,
      output: output,
      cost:
        (input * price["input"] + write * price["cache_write"] + read * price["cache_read"] +
           output * price["output"]) / 1_000_000
    }
  end

  defp tokens(usage, _price) do
    details = usage["prompt_tokens_details"] || %{}

    %{
      prompt: usage["prompt_tokens"] || 0,
      cached: details["cached_tokens"] || 0,
      write: details["cache_write_tokens"] || 0,
      output: usage["completion_tokens"] || 0,
      cost: usage["cost"] || 0
    }
  end

  defp cache(usages) do
    %{
      prompt_tokens: sum(usages, :prompt),
      cached_tokens: sum(usages, :cached),
      cache_write_tokens: sum(usages, :write)
    }
  end

  defp sum(maps, key), do: maps |> Enum.map(&(&1[key] || 0)) |> Enum.sum()
end
