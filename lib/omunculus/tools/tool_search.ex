defmodule Omunculus.Tools.ToolSearch do
  @moduledoc """
  Builtin `tool_search` tool: searches this run's already
  authorized catalog by name, description or tag, without reaching past the
  ceiling. A tool the run was not declared the schema of (not `pinned`) comes
  back with its schema on the line after its card, `schema <name>: <json>`;
  `found/1` reads those names from the output, and the run may call them from
  then on.
  """

  alias Omunculus.Tool.Manifest
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

  # Every word of `q` must match the name, description or a tag, so a
  # multi-word query narrows the result instead of matching nothing.
  defp filter_query(cards, q) do
    words = q |> String.downcase() |> String.split()
    Enum.filter(cards, &matches_query?(&1, words))
  end

  defp matches_query?(%{name: name, description: description, tags: tags}, words) do
    fields = Enum.map([name, description | tags], &String.downcase/1)
    Enum.all?(words, fn word -> Enum.any?(fields, &String.contains?(&1, word)) end)
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

  @doc "The tools whose schema an `output` of this tool carries."
  @spec found(String.t()) :: [String.t()]
  def found(output) do
    for [_, name] <- Regex.scan(~r/^schema (\S+): /m, output), do: name
  end

  defp format([]), do: Out.no_tools_found()
  defp format(cards), do: cards |> Enum.map_join("\n", &entry/1)

  defp entry(%{pinned: false, name: name, parameters: parameters} = card),
    do: Manifest.card(card) <> "\nschema #{name}: " <> Jason.encode!(parameters)

  defp entry(card), do: Manifest.card(card)
end
