defmodule Omunculus.Tools.Assemble do
  @moduledoc """
  Builtin `assemble` tool: builds the assembled prompt of a run from
  the hydrated views. After the agent's text come the agents the
  `agents` view says a new work may name when the run has the `work`
  card, and the cards, which follow `pinned` on the catalog view. Then
  the work's title and goal, its last comment, and its last closed run
  (`runs.last.work`), or, without a work, the run that opened the run's
  request (`runs.request`): the message that opened that run and every
  event it recorded but the calls of this tool and its start and end,
  that is the model's messages as recorded but their `usage`, each tool
  call with its args, status and output, and each store action it
  emitted. With `last_run_output_bytes` in the args, each call's output
  keeps that many bytes, cut on a character boundary, and a line says how
  many bytes were cut. A run with a request gets the request's requester,
  its options with their tool calls, and its comments. Inbox is included
  only when the opening carried `inbox_id`. The message of the opening
  comes last.
  """

  alias Omunculus.Tool.Manifest
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{name: name, args: args, view: view}) do
    text = Map.get(args, "text", "")

    # What stays the same across an agent's runs comes first, so a server
    # that caches the prefix of a prompt reuses it from one run to the next.
    sections =
      [String.trim(text)] ++
        agents_section(view["agents"] || [], view["catalog"] || []) ++
        [tools_section(view["catalog"] || [])] ++
        work_section(view["work"]) ++
        comment_section(view["comments.work"]) ++
        last_run_section(view["runs.last.work"] || view["runs.request"], name, args) ++
        request_section(view["request"], view["comments.request"]) ++
        inbox_section(view, args) ++
        message_section(view["prompt"])

    Out.ok(Enum.join(sections, "\n\n"))
  end

  defp comment_section(nil), do: []
  defp comment_section([]), do: []
  defp comment_section(comments), do: ["## Last comment\n#{List.last(comments).body}"]

  defp last_run_section(nil, _name, _args), do: []

  defp last_run_section(run, name, args) do
    limit = args["last_run_output_bytes"]
    message = if run.message, do: ["- message #{run.message.body}"], else: []
    entries = message ++ Enum.flat_map(run.events, &entry(&1, name, limit))
    ["## Last run\n" <> Enum.join(entries, "\n")]
  end

  # A call of this tool holds a whole earlier prompt, and the lifecycle
  # events say nothing of what the run did.
  defp entry(%{type: type}, _name, _limit) when type in ["start-run", "end-run"], do: []

  defp entry(%{type: "tool", body: body}, name, limit) do
    case Jason.decode!(body) do
      %{"name" => ^name} -> []
      call -> [call_entry(call, limit)]
    end
  end

  defp entry(%{type: type, body: body}, _name, _limit), do: ["- #{type} #{shown(type, body)}"]

  # The usage a server reports on a reply is for measuring the run, not
  # something the next run acts on.
  defp shown("model", body) do
    case Jason.decode(body) do
      {:ok, %{"usage" => _usage} = reply} -> Jason.encode!(Map.delete(reply, "usage"))
      _other -> body
    end
  end

  defp shown(_type, body), do: body

  defp call_entry(call, limit) do
    via = if call["via"], do: " via #{call["via"]}", else: ""
    status = if call["ok"], do: "ok", else: "failed"
    head = "- tool #{call["name"]}#{via} #{Jason.encode!(call["args"])} #{status}"

    case call["output"] do
      output when output in [nil, ""] -> head
      output when is_binary(output) -> head <> "\n" <> cut(output, limit)
      output -> head <> "\n" <> cut(Jason.encode!(output), limit)
    end
  end

  defp cut(output, limit) when is_nil(limit) or byte_size(output) <= limit, do: output

  defp cut(output, limit) do
    kept =
      case :unicode.characters_to_binary(binary_part(output, 0, limit)) do
        {_incomplete_or_error, valid, _rest} -> valid
        valid -> valid
      end

    kept <> "\n" <> Out.bytes_cut(byte_size(output) - byte_size(kept))
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

    Enum.join(["## Tools", Out.tools_preamble() | lines], "\n")
  end

  defp pinned_subset?(cards), do: Enum.any?(cards, &(not pinned?(&1)))

  defp pinned?(%{pinned: false}), do: false
  defp pinned?(%{"pinned" => false}), do: false
  defp pinned?(_card), do: true

  defp more_tools_line(n) when n > 0, do: [Out.more_tools(n)]
  defp more_tools_line(_n), do: []

  defp card(card), do: Manifest.card(card)
end
