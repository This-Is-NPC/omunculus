defmodule Omunculus.Model.Battery do
  @moduledoc """
  The bench model of spec §6, the "count to 5" scenario: decides only
  from what it can see in the assembled prompt — the cards under
  `## Tools`, the presence of `## Work`, the text under `## Last
  comment` and the agent's own first line — opening the work with `work`
  when there is none, counting to 5 with `counter` when it can,
  delegating one floor down with `work` when it still cannot count and
  has not already (marked by its own "delegated" report, so a later
  reopening of the same work does not delegate again), reviewing a
  finished count on the next opening, and reacting as an observer when
  addressed as one. It concludes a count or a review with `done` when it
  has the card; without it, it comments a count with `comment`.
  """

  @counted "counted to 5"
  @delegated "delegated"
  @opened "opened"
  @count_work %{"title" => "Count to 5", "goal" => "count with counter to 5"}

  @spec new(map) ::
          (String.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           term ->
             {:ok, String.t()})
  def new(_spec) do
    fn assembled, tools, call, record, _execution ->
      with {:ok, text} <- assembled |> parse(tools) |> decide(call) do
        :ok = record.(text)
        {:ok, text}
      end
    end
  end

  defp decide(%{work: false, cards: cards} = parsed, call) do
    if MapSet.member?(cards, "work"),
      do: create_work(call, @opened),
      else: count(parsed, call)
  end

  defp decide(parsed, call), do: count(parsed, call)

  defp create_work(call, report) do
    call.("work", %{"report" => report, "works" => [@count_work]})
    {:ok, report}
  end

  defp count(%{cards: cards} = parsed, call) do
    if MapSet.member?(cards, "counter") do
      count_to_five(call, 5)

      if MapSet.member?(cards, "comment") and not MapSet.member?(cards, "done"),
        do: call.("comment", %{"body" => @counted})

      if MapSet.member?(cards, "notify"), do: call.("notify", %{"body" => "reached 5"})
      if MapSet.member?(cards, "done"), do: call.("done", %{"report" => @counted})
      {:ok, @counted}
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
    cond do
      reviewable?(comment, cards) ->
        call.("done", %{"report" => "reviewed"})
        {:ok, "reviewed"}

      MapSet.member?(cards, "work") and not delegated?(comment) ->
        create_work(call, @delegated)

      true ->
        observe(parsed, call)
    end
  end

  defp reviewable?(comment, cards),
    do:
      is_binary(comment) and String.contains?(comment, @counted) and
        MapSet.member?(cards, "done")

  defp delegated?(comment), do: is_binary(comment) and String.contains?(comment, @delegated)

  defp observe(%{agent_line: line, cards: cards, work: work?}, call) do
    if String.contains?(line, "observer") and MapSet.member?(cards, "comment") and work? do
      call.("comment", %{"body" => "observed"})
      {:ok, "observed"}
    else
      {:ok, "nothing to do"}
    end
  end

  defp parse(assembled, tools) do
    %{
      cards: MapSet.new(tools, & &1.name),
      work: String.contains?(assembled, "## Work"),
      last_comment: last_comment(assembled),
      agent_line: assembled |> String.split("\n", parts: 2) |> List.first() || ""
    }
  end

  defp last_comment(assembled) do
    case String.split(assembled, "## Last comment\n", parts: 2) do
      [_before, rest] -> rest |> String.split("\n\n", parts: 2) |> List.first()
      _no_last_comment -> nil
    end
  end
end
