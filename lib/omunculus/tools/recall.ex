defmodule Omunculus.Tools.Recall do
  @moduledoc """
  Builtin `recall` tool: searches the `memories` view, the entries the run
  sees. The words of `query` are matched in an entry's text; the entries
  matching more of them come first, the newer first among equals. Without
  a query, the newest entries. `scope` and `kind` narrow the search.
  """

  alias Omunculus.Tools.{Args, Out}

  @limit 10

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    with {:ok, limit} <- Args.count(args, "limit") do
      terms = words(Args.present(args, "query") || "")

      entries =
        (view["memories"] || [])
        |> Enum.filter(&(narrow?(&1, args, "scope") and narrow?(&1, args, "kind")))
        |> Enum.map(&{score(&1, terms), &1})
        |> Enum.filter(fn {score, _entry} -> terms == [] or score > 0 end)
        |> Enum.sort_by(fn {score, entry} -> {score, entry["at"]} end, :desc)
        |> Enum.take(limit || @limit)
        |> Enum.map(fn {_score, entry} -> line(entry) end)

      if entries == [], do: Out.ok("nothing remembered"), else: Out.ok(Enum.join(entries, "\n"))
    else
      {:error, message} -> Out.fail(message)
    end
  end

  defp narrow?(entry, args, field),
    do: is_nil(Args.present(args, field)) or entry[field] == args[field]

  defp score(entry, terms) do
    text = String.downcase(entry["text"])
    Enum.count(terms, &String.contains?(text, &1))
  end

  defp words(text) do
    ~r/[\p{L}\p{N}]+/u |> Regex.scan(String.downcase(text)) |> List.flatten() |> Enum.uniq()
  end

  defp line(entry) do
    "- #{entry["id"]} [#{entry["scope"]}, #{entry["kind"]}] #{entry["text"]} " <>
      "(by #{entry["by"]}, #{entry["at"]}, conversation #{entry["conversation_id"]})"
  end
end
