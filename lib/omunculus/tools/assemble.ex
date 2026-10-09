defmodule Omunculus.Tools.Assemble do
  @moduledoc """
  Builtin `assemble` tool: builds the assembled prompt of a run from
  the hydrated views. Its `instructions` are what stays the same across
  an agent's runs: the agent's text, the agents the
  `agents` view says a new work may name when the run has the `work`
  card, each with the tools it has that this run has not, the cards,
  which follow `pinned` on the catalog view, and, under `## Skills`, the
  name and description of each skill the run has. Its `output`, the
  context, is the rest: the work's title and
  goal, its last comment, and its last closed run (`last_run`), or,
  without a work, the run that opened the run's request (`opener`), as
  `Omunculus.Tools.Record` lines without this tool's calls, each call's
  output cut to `last_run_output_bytes` in the args when set. Then, under
  `## Results`, what the works handed down from the run's work came back
  with since its last closed run: each child closed or cancelled since,
  with its last comment, and, when the run was opened by a child's
  `break`, that child's report. A run with a request gets the request's
  requester, its options with their tool calls, and its comments. Inbox is
  included only when the opening carried `inbox_id`. The message of the
  opening comes last.
  """

  alias Omunculus.Tool.Manifest
  alias Omunculus.Tools.{Out, Record}

  @spec run(map) :: map
  def run(%{name: name, args: args, view: view}) do
    text = Map.get(args, "text", "")

    instructions =
      [String.trim(text)] ++
        agents_section(view["agents"] || [], view["catalog"] || []) ++
        [tools_section(view["catalog"] || [])] ++
        skills_section(view["skills"] || [])

    context =
      work_section(view["work"]) ++
        comment_section(view["comments"]) ++
        last_run_section(view["last_run"] || view["opener"], name, args) ++
        results_section(view["results"] || [], view["cause"]) ++
        request_section(view["request"], view["request_comments"]) ++
        inbox_section(view, args) ++
        message_section(view["message"])

    context
    |> Enum.join("\n\n")
    |> Out.ok()
    |> Map.put("instructions", Enum.join(instructions, "\n\n"))
  end

  defp comment_section(nil), do: []
  defp comment_section([]), do: []
  defp comment_section(comments), do: ["## Last comment\n#{List.last(comments).body}"]

  defp last_run_section(nil, _name, _args), do: []

  defp last_run_section(run, name, args) do
    ["## Last run\n" <> Enum.join(Record.lines(run, name, args["last_run_output_bytes"]), "\n")]
  end

  # What the works handed down from this one came back with since its last
  # run: each closed child's last comment, its report, and the report of
  # the child whose break woke it.
  defp results_section(children, cause) do
    lines =
      Enum.map(children, fn child ->
        report = if child.last_comment, do: ": " <> child.last_comment.body, else: ""
        "- #{child.title} (#{child.assignee}, #{child.state}, work #{child.id})#{report}"
      end) ++ broken(cause)

    if lines == [], do: [], else: ["## Results\n" <> Enum.join(lines, "\n")]
  end

  defp broken(%{type: "break", actor_id: agent, body: body}),
    do: ["- #{agent} broke its work: #{Jason.decode!(body)["body"]}"]

  defp broken(_cause), do: []

  defp message_section(nil), do: []
  defp message_section(message), do: ["## Message\n#{message.body}"]

  defp work_section(nil), do: []
  defp work_section(work), do: ["## Work\n#{work.title}", "## Goal\n#{work.goal}"]

  defp inbox_section(view, args) do
    case Map.get(args, "inbox_id") do
      id when is_binary(id) and id != "" ->
        comments = view["inbox_comments"] || []
        ["## Inbox\n#{id}\n" <> Enum.map_join(comments, "\n", & &1.body)]

      _other ->
        []
    end
  end

  # Only a skill's name and description: its text comes through the skill tool.
  defp skills_section([]), do: []

  defp skills_section(skills) do
    lines = Enum.map(skills, &"- #{&1.name}: #{&1.description}")
    ["## Skills
" <> Enum.join([Out.skills_preamble() | lines], "
")]
  end

  defp agents_section([], _cards), do: []

  defp agents_section(agents, cards) do
    if Enum.any?(cards, &(&1.name == "work")) do
      own = MapSet.new(cards, & &1.name)
      ["## Agents\n" <> Enum.map_join(agents, "\n", &agent_line(&1, own))]
    else
      []
    end
  end

  # What an agent can do that this run cannot is why to hand it a work.
  defp agent_line(%{name: name, tools: tools}, own) do
    case Enum.reject(tools, &MapSet.member?(own, &1)) do
      [] -> "- #{name}"
      beyond -> "- #{name}: also #{Enum.join(beyond, ", ")}"
    end
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
