defmodule Omunculus.Usage do
  @moduledoc """
  The tokens and cost the providers reported in the model replies a run
  recorded. Each reply carries the `usage` its provider sent, in the
  OpenAI or the Anthropic shape.
  """

  @type totals :: %{
          replies: non_neg_integer,
          input: number,
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

  @doc "The sum of the usage of `replies`."
  @spec sum([map]) :: totals
  def sum(replies) do
    Enum.reduce(replies, %{replies: 0, input: 0, cached: 0, output: 0, cost: 0.0}, fn reply,
                                                                                      acc ->
      usage = reply["usage"] || %{}

      %{
        replies: acc.replies + 1,
        input:
          acc.input + number(usage["input_tokens"] || usage["prompt_tokens"]) +
            number(usage["cache_creation_input_tokens"]) +
            number(usage["cache_read_input_tokens"]),
        cached:
          acc.cached + number(usage["cache_read_input_tokens"]) +
            number(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
        output: acc.output + number(usage["output_tokens"] || usage["completion_tokens"]),
        cost: acc.cost + number(usage["cost"])
      }
    end)
  end

  @doc "The sum of already summed `totals`."
  @spec total([totals]) :: totals
  def total(list) do
    Enum.reduce(list, %{replies: 0, input: 0, cached: 0, output: 0, cost: 0.0}, fn part, acc ->
      Map.merge(acc, part, fn _key, a, b -> a + b end)
    end)
  end

  defp number(value) when is_number(value), do: value
  defp number(_value), do: 0
end
