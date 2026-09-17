defmodule Omunculus.Tools.Assemble do
  @moduledoc """
  Builtin `assemble` tool: builds the assembled prompt of a run from
  the hydrated views. Cards follow `pinned` on the catalog view.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    text = Map.get(args, "text", "")

    sections =
      [String.trim(text)] ++
        message_section(view["prompt"]) ++
        work_section(view["work"]) ++
        comment_section(last_comment(view["comments.work"])) ++
        inbox_section(view, args) ++
        request_section(view["request"], view["comments.request"]) ++
        [tools_section(view["catalog"] || [])]

    Out.ok(Enum.join(sections, "\n\n"))
  end

  defp last_comment(nil), do: nil
  defp last_comment(comments), do: List.last(comments)

  defp message_section(nil), do: []
  defp message_section(message), do: ["## Message\n#{message.body}"]

  defp work_section(nil), do: []
  defp work_section(work), do: ["## Work\n#{work.title}"]

  defp comment_section(nil), do: []
  defp comment_section(comment), do: ["## Last comment\n#{comment.body}"]

  defp inbox_section(view, args) do
    cond do
      Map.has_key?(view, "comments.inbox") ->
        comments = view["comments.inbox"] || []
        id = Map.get(args, "inbox_id") || inbox_id(comments)
        ["## Inbox\n#{id}\n" <> Enum.map_join(comments, "\n", & &1.body)]

      notifications = view["inbox.work"] ->
        inbox_work_section(notifications)

      true ->
        []
    end
  end

  defp inbox_work_section(nil), do: []
  defp inbox_work_section([]), do: []

  defp inbox_work_section(notifications),
    do: ["## Inbox\n" <> Enum.map_join(notifications, "\n", & &1.body)]

  defp inbox_id([comment | _]), do: comment.inbox_id
  defp inbox_id(_), do: nil

  defp request_section(nil, _comments), do: []

  defp request_section(request, comments) do
    ask = Jason.decode!(request.ask)
    header = "#{request.id}: #{ask["kind"]} #{ask["name"]} #{Out.requested_by(request.agent)}"
    comments = comments || []
    ["## Request\n" <> Enum.join([header | Enum.map(comments, & &1.body)], "\n")]
  end

  defp tools_section(cards) do
    names = Enum.map(cards, & &1.name)

    lines =
      if "tool_search" in names and pinned_subset?(cards) do
        shown = Enum.filter(cards, &pinned?/1)
        omitted = length(cards) - length(shown)
        Enum.map(shown, &card/1) ++ more_tools_line(omitted)
      else
        Enum.map(cards, &card/1)
      end

    "## Tools\n#{Out.tools_preamble()}\n" <> Enum.join(lines, "\n")
  end

  defp pinned_subset?(cards), do: Enum.any?(cards, &(not pinned?(&1)))

  defp pinned?(%{pinned: false}), do: false
  defp pinned?(%{"pinned" => false}), do: false
  defp pinned?(_card), do: true

  defp more_tools_line(n) when n > 0, do: [Out.more_tools(n)]
  defp more_tools_line(_n), do: []

  defp card(%{name: name, description: description}) do
    lines =
      description
      |> String.split("\n")
      |> Enum.take(3)
      |> Enum.join("\n")

    "- #{name}: #{lines}"
  end
end
