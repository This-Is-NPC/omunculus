defmodule Omunculus.Tools.ToolSearch do
  @moduledoc """
  Builtin `tool_search` tool, per spec §8.4: searches this run's already
  authorized catalog by name, description or tag, without exposing schemas
  or reaching past the ceiling.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{view: view, args: args}) do
    output =
      view
      |> Map.get("catalog", [])
      |> filter_query(Args.present(args, "q"))
      |> filter_tags(wanted_tags(args))
      |> Enum.sort_by(& &1.name)
      |> format()

    Out.ok(output)
  end

  defp filter_query(cards, nil), do: cards

  defp filter_query(cards, q) do
    q = String.downcase(q)
    Enum.filter(cards, &matches_query?(&1, q))
  end

  defp matches_query?(%{name: name, description: description, tags: tags}, q) do
    String.contains?(String.downcase(name), q) or
      String.contains?(String.downcase(description), q) or
      Enum.any?(tags, &String.contains?(String.downcase(&1), q))
  end

  defp filter_tags(cards, []), do: cards

  defp filter_tags(cards, wanted) do
    Enum.filter(cards, fn %{tags: tags} -> Enum.all?(wanted, &(&1 in tags)) end)
  end

  defp wanted_tags(args) do
    case Map.get(args, "tags") do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _other -> []
    end
  end

  defp format([]), do: "nenhuma tool encontrada"
  defp format(cards), do: cards |> Enum.map(&line/1) |> Enum.join("\n")

  defp line(%{name: name, description: description, tags: []}),
    do: "- #{name}: #{description}"

  defp line(%{name: name, description: description, tags: tags}),
    do: "- #{name}: #{description} [#{Enum.join(tags, ", ")}]"
end
