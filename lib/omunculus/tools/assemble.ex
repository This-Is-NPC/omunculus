defmodule Omunculus.Tools.Assemble do
  @moduledoc """
  Builtin `assemble` tool: builds the assembled prompt of a run from
  the hydrated views: the work's title and goal, its last comment, and
  its last closed run (`runs.last.work`), or, without a work, the run
  that opened the run's request (`runs.request`): the message that
  opened that run and every event it recorded but the calls of this tool
  and its start and end, that is the model's messages as recorded but
  their `usage`, each tool call with its args, status and output, and each
  store action it emitted. Then the
  agents the `agents` view says a new work may name when the run has the
  `work` card, and the cards, which follow `pinned` on the catalog view.
  A run with a request gets the request's requester, its options with
  their tool calls, and its comments. Inbox is included only when the
  opening carried `inbox_id`.
  """

  alias Omunculus.Tool.Manifest
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{name: name, args: args, view: view}) do
    text = Map.get(args, "text", "")

    sections =
      [String.trim(text)] ++
        message_section(view["prompt"]) ++
        work_section(view["work"]) ++
        comment_section(view["comments.work"]) ++
        last_run_section(view["runs.last.work"] || view["runs.request"], name) ++
        request_section(view["request"], view["comments.request"]) ++
        inbox_section(view, args) ++
        agents_section(view["agents"] || [], view["catalog"] || []) ++
        [tools_section(view["catalog"] || [])]

    Out.ok(Enum.join(sections, "\n\n"))
  end

  defp comment_section(nil), do: []
  defp comment_section([]), do: []
  defp comment_section(comments), do: ["## Last comment\n#{List.last(comments).body}"]

  defp last_run_section(nil, _name), do: []

  defp last_run_section(run, name) do
    message = if run.message, do: ["- message #{run.message.body}"], else: []
    entries = message ++ Enum.flat_map(run.events, &entry(&1, name))
    ["## Last run\n" <> Enum.join(entries, "\n")]
  end

  # A call of this tool holds a whole earlier prompt, and the lifecycle
  # events say nothing of what the run did.
  defp entry(%{type: type}, _name) when type in ["start-run", "end-run"], do: []

  defp entry(%{type: "tool", body: body}, name) do
    case Jason.decode!(body) do
      %{"name" => ^name} -> []
      call -> [call_entry(call)]
    end
  end

  defp entry(%{type: type, body: body}, _name), do: ["- #{type} #{shown(type, body)}"]

  # The usage a server reports on a reply is for measuring the run, not
  # something the next run acts on.
  defp shown("model", body) do
    case Jason.decode(body) do
      {:ok, %{"usage" => _usage} = reply} -> Jason.encode!(Map.delete(reply, "usage"))
      _other -> body
    end
  end

  defp shown(_type, body), do: body

  defp call_entry(call) do
    via = if call["via"], do: " via #{call["via"]}", else: ""
    status = if call["ok"], do: "ok", else: "failed"
    head = "- tool #{call["name"]}#{via} #{Jason.encode!(call["args"])} #{status}"

    case call["output"] do
      output when output in [nil, ""] -> head
      output when is_binary(output) -> head <> "\n" <> output
      output -> head <> "\n" <> Jason.encode!(output)
    end
  end

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
