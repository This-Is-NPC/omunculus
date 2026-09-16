defmodule Omunculus.Model.Battery do
  @moduledoc """
  The bench model of spec §6, the "conte até 5" scenario: decides only
  from what it can see in the assembled prompt — the cards under
  `## Tools`, the presence of `## Work`, the text under `## Last
  comment` and the agent's own first line — opening the work when there
  is none, delegating when it can, counting to 5 with `counter`
  otherwise, reviewing a finished count on the next opening, and reacting
  as an observer when addressed as one.
  """

  @spec complete(String.t(), (String.t(), map -> {:ok, String.t()} | {:error, term})) ::
          {:ok, String.t()}
  def complete(assembled, call) do
    assembled |> parse() |> decide(call)
  end

  defp decide(%{work: false, cards: cards} = parsed, call) do
    if MapSet.member?(cards, "work"), do: open_work(parsed, call), else: count(parsed, call)
  end

  defp decide(parsed, call), do: count(parsed, call)

  defp open_work(%{cards: cards} = parsed, call) do
    call.("work", %{"title" => "Contar até 5"})

    if MapSet.member?(cards, "delegate") do
      call.("delegate", %{"title" => "Conte até 5", "body" => "conte com counter até 5"})
      {:ok, "delegado"}
    else
      count(%{parsed | work: true}, call)
    end
  end

  defp count(%{cards: cards} = parsed, call) do
    if MapSet.member?(cards, "counter") do
      count_to_five(call, 5)
      if MapSet.member?(cards, "comment"), do: call.("comment", %{"body" => "contei até 5"})
      if MapSet.member?(cards, "notify"), do: call.("notify", %{"body" => "cheguei a 5"})
      if MapSet.member?(cards, "continue"), do: call.("continue", %{})
      {:ok, "contei até 5"}
    else
      review(parsed, call)
    end
  end

  defp count_to_five(_call, 0), do: :ok

  defp count_to_five(call, remaining) do
    case call.("counter", %{}) do
      {:ok, "5"} -> :ok
      _other -> count_to_five(call, remaining - 1)
    end
  end

  defp review(%{last_comment: comment, cards: cards} = parsed, call) do
    if reviewable?(comment, cards) do
      call.("continue", %{})
      {:ok, "revisado"}
    else
      observe(parsed, call)
    end
  end

  defp reviewable?(comment, cards),
    do:
      is_binary(comment) and String.contains?(comment, "contei até 5") and
        MapSet.member?(cards, "continue")

  defp observe(%{agent_line: line, cards: cards, work: work?}, call) do
    if String.contains?(line, "observer") and MapSet.member?(cards, "comment") and work? do
      call.("comment", %{"body" => "observado"})
      {:ok, "observado"}
    else
      {:ok, "nada a fazer"}
    end
  end

  defp parse(assembled) do
    %{
      cards: card_names(assembled),
      work: String.contains?(assembled, "## Work"),
      last_comment: last_comment(assembled),
      agent_line: assembled |> String.split("\n", parts: 2) |> List.first() || ""
    }
  end

  defp card_names(assembled) do
    ~r/^- ([^\s:]+):/m
    |> Regex.scan(assembled)
    |> MapSet.new(fn [_line, name] -> name end)
  end

  defp last_comment(assembled) do
    case String.split(assembled, "## Last comment\n", parts: 2) do
      [_before, rest] -> rest |> String.split("\n\n", parts: 2) |> List.first()
      _no_last_comment -> nil
    end
  end
end
