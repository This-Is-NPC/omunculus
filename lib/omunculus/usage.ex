defmodule Omunculus.Usage do
  @moduledoc """
  The tokens and cost the providers reported in the model replies a run
  recorded. Each reply carries the `usage` its provider sent, in the
  OpenAI or the Anthropic shape.
  """

  @type totals :: %{
          replies: non_neg_integer,
          input: number,
          fresh: number,
          cache_write: number,
          cached: number,
          output: number,
          cost: number
        }

  @doc """
  A model event's body as a reply map: the JSON the model sent, or plain
  text as the harness records a run whose process stopped.
  """
  @spec reply(String.t()) :: map
  def reply(body) do
    case Jason.decode(body) do
      {:ok, reply} when is_map(reply) -> reply
      _text -> %{"content" => body}
    end
  end

  @doc """
  The sum of the usage of `replies`. `input` counts every token read; of
  them `fresh` were not cached, `cache_write` entered the cache and `cached`
  came from it.
  """
  @spec sum([map]) :: totals
  def sum(replies) do
    Enum.reduce(replies, empty(), fn reply, acc ->
      usage = reply["usage"] || %{}
      write = number(usage["cache_creation_input_tokens"])

      cached =
        number(usage["cache_read_input_tokens"]) +
          number(get_in(usage, ["prompt_tokens_details", "cached_tokens"]))

      # Anthropic's `input_tokens` leaves the cached ones out; OpenAI's
      # `prompt_tokens` holds them.
      fresh =
        if is_number(usage["input_tokens"]),
          do: usage["input_tokens"],
          else: max(number(usage["prompt_tokens"]) - cached, 0)

      %{
        replies: acc.replies + 1,
        input:
          acc.input + number(usage["input_tokens"] || usage["prompt_tokens"]) + write +
            number(usage["cache_read_input_tokens"]),
        fresh: acc.fresh + fresh,
        cache_write: acc.cache_write + write,
        cached: acc.cached + cached,
        output: acc.output + number(usage["output_tokens"] || usage["completion_tokens"]),
        cost: acc.cost + number(usage["cost"])
      }
    end)
  end

  @doc """
  The dollars `totals` cost at `price`, per million tokens: input, output,
  cache write and cache read.
  """
  @spec spend(totals, Omunculus.Config.price()) :: float
  def spend(totals, price) do
    (totals.fresh * price.input + totals.output * price.output +
       totals.cache_write * price.cache_write + totals.cached * price.cache_read) / 1.0e6
  end

  @doc "The sum of already summed `totals`."
  @spec total([totals]) :: totals
  def total(list) do
    Enum.reduce(list, empty(), fn part, acc ->
      Map.merge(acc, part, fn _key, a, b -> a + b end)
    end)
  end

  defp empty,
    do: %{replies: 0, input: 0, fresh: 0, cache_write: 0, cached: 0, output: 0, cost: 0.0}

  defp number(value) when is_number(value), do: value
  defp number(_value), do: 0
end
