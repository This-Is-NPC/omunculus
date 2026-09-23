defmodule Omunculus.Tools.Assemble do
  @moduledoc """
  Builtin `assemble` tool: builds the assembled prompt of a run from
  the hydrated views: the work's title and goal, its last comment, or the
  final model text of its last run when that run commented nothing on it
  (`runs.last.work`), the
  agents the `agents` view says a new work may name when the run has the
  `work` card, and the cards, which follow `pinned` on the catalog view.
  A run with a request gets the request's requester, its options with
  their tool calls, and its comments. Inbox is included only when the
  opening carried `inbox_id`.
  """

  alias Omunculus.Tool.Manifest
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    text = Map.get(args, "text", "")

    sections =
      [String.trim(text)] ++
        message_section(view["prompt"]) ++
        work_section(view["work"]) ++
        last_section(view["runs.last.work"], view["comments.work"]) ++
        request_section(view["request"], view["comments.request"]) ++
        inbox_section(view, args) ++
        agents_section(view["agents"] || [], view["catalog"] || []) ++
        [tools_section(view["catalog"] || [])]

    Out.ok(Enum.join(sections, "\n\n"))
  end

  defp last_section(%{commented: false, text: text}, _comments) when is_binary(text),
    do: ["## Last run\n#{text}"]

  defp last_section(_run, nil), do: []
  defp last_section(_run, []), do: []
  defp last_section(_run, comments), do: ["## Last comment\n#{List.last(comments).body}"]

  defp message_section(nil), do: []
  defp message_section(message), do: ["## Message\n#{message.body}"]

  defp work_section(nil), do: []
  defp work_section(work), do: ["## Work\n#{work.title}", "## Goal\n#{work.goal}"]

  defp inbox_section(view, args) do
    case Map.get(args, "inbox_id") do
      id when is_binary(id) and id != "" ->
        comments = view["comments.inbox"] || []
        ["## Inbox\n#{id}\n" <> Enum.map_join(comments, "\n", & &1.body)]

      _other ->
        []
    end
  end

  defp agents_section([], _cards), do: []

  defp agents_section(agents, cards) do
    if Enum.any?(cards, &(&1.name == "work")),
      do: ["## Agents\n" <> Enum.map_join(agents, "\n", &"- #{&1}")],
      else: []
  end

  defp request_section(nil, _comments), do: []

  defp request_section(request, comments) do
    header = "#{request.id} #{Out.requested_by(request.agent)}"
    options = request.options |> Jason.decode!() |> Enum.sort() |> Enum.map(&option_line/1)
    comments = Enum.map(comments || [], & &1.body)
    ["## Request\n" <> Enum.join([header | options] ++ comments, "\n")]
  end

  defp option_line({name, []}), do: "- #{name}"

  defp option_line({name, calls}),
    do: "- #{name}: " <> Enum.map_join(calls, ", ", &"#{&1["name"]} #{Jason.encode!(&1["args"])}")

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

  defp card(card), do: Manifest.card(card)
end
