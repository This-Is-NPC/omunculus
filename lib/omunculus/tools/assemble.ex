defmodule Omunculus.Tools.Assemble do
  @moduledoc """
  Builtin `assemble` tool: builds the assembled prompt of a run from
  the hydrated views. Its `instructions` are what stays the same across
  an agent's runs: the agent's text, the agents the
  `agents` view says a new work may name when the run has the `work`
  card, each with the tools it has that this run has not, the cards,
  which follow `pinned` on the catalog view, and, under `## Skills`, the
  name and description of each skill the run has. Its `output`, the
  context, is the rest: under `## Environment`, the workspace every
  command starts in, the person's home and the platform, which differ
  from one workspace to another; the work's title and
  goal, its last comment, and its last closed run (`last_run`), or,
  without a work, the run that opened the run's request (`opener`), as
  `Omunculus.Tools.Record` lines without this tool's calls, each call's
  output cut to `last_run_output_bytes` in the args when set. Then, under
  `## Results`, what the works handed down from the run's work came back
  with since its last closed run: each child closed or cancelled since,
  with its last comment, and, when the run was opened by a child's
  `break`, that child's report. A run with a request gets the request's
  requester, while it waits the options an agent may pick with their tool
  calls — not those granting with a `scope`, which only a person may —
  and its comments, the reply among them once it is answered. Inbox is
  included only when the opening carried `inbox_id`. The message of the
  opening comes last.

  With `session_ttl_ms` and `session_max_bytes` in the args, and the
  `session` view (the work with its closed runs), the run may continue its
  `agent`'s paused session (`Omunculus.Tools.Session`): the output's
  `session` then carries the history and `since`, what happened since the
  pause — the results, the request, the inbox and the message, or that
  the work goes on — and the run keeps the instructions the session started
  with; when its own differ, `since` adds its `## Tools`.
  """

  alias Omunculus.Tool.Manifest
  alias Omunculus.Tools.{Out, Record, Session}

  # The sections that begin the context of an assembled prompt.
  @context_start ~r/\n\n(?=## (Environment|Work|Last comment|Last run|Results|Request|Inbox|Message)\n)/

  @spec run(map) :: map
  def run(%{name: name, args: args, view: view} = input) do
    text = Map.get(args, "text", "")
    cards = view["catalog"] || []

    instructions =
      [String.trim(text)] ++
        agents_section(view["agents"] || [], cards) ++
        [tools_section(cards)] ++
        skills_section(view["skills"] || [])

    # What happened since a pause, which a continued session is told.
    news =
      results_section(view["results"] || [], view["cause"]) ++
        request_section(view["request"], view["request_comments"]) ++
        inbox_section(view, args) ++
        message_section(view["message"])

    context =
      environment_section(Map.get(input, :roots, [])) ++
        work_section(view["work"]) ++
        comment_section(view["comments"]) ++
        last_run_section(view["last_run"] || view["opener"], name, args) ++
        news

    context
    |> Enum.join("\n\n")
    |> Out.ok()
    |> put_session(session(view["session"], args, news), Enum.join(instructions, "\n\n"), cards)
  end

  defp session(
         %{runs: runs},
         %{"session_ttl_ms" => ttl_ms, "session_max_bytes" => max_bytes} = args,
         news
       ) do
    Session.history(runs, %{
      agent: args["agent"],
      now: DateTime.utc_now(),
      ttl_ms: ttl_ms,
      max_bytes: max_bytes,
      split: &split/1,
      tool_output_bytes: args["tool_output_bytes"],
      since: if(news == [], do: Out.resume(), else: Enum.join(news, "\n\n"))
    })
  end

  defp session(_work, _args, _news), do: nil

  # An assembled prompt parted into its instructions and its context.
  defp split(assembled) when is_binary(assembled) do
    case Regex.split(@context_start, assembled, parts: 2) do
      [instructions, context] -> {:ok, instructions, context}
      [_no_context] -> :error
    end
  end

  defp split(_assembled), do: :error

  defp put_session(out, nil, instructions, _cards), do: Map.put(out, "instructions", instructions)

  # The session goes on under the instructions it started with; tools gained
  # since are in what the run is told.
  defp put_session(out, session, instructions, cards) do
    {history, [%{"user" => since}]} = Enum.split(session["history"], -1)

    since =
      if session["instructions"] == instructions,
        do: since,
        else: since <> "\n\n" <> tools_section(cards)

    out
    |> Map.put("instructions", session["instructions"])
    |> Map.put("session", %{
      "continues" => session["continues"],
      "since" => since,
      "history" => history ++ [%{"user" => since}]
    })
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

  defp broken(%{type: "break", actor_id: agent, work_id: work_id, body: body}),
    do: ["- #{agent} broke its work #{work_id}: #{Jason.decode!(body)["body"]}"]

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

  # Where the run is: its workspace, which every command starts in, and
  # the person's home, which is not the workspace.
  defp environment_section([]), do: []

  defp environment_section([root | _]) do
    {_family, os} = :os.type()

    [
      "## Environment\nworkspace: #{root}\nhome: #{System.user_home!()}\nplatform: #{os}\n" <>
        "Every command starts in the workspace; look for the work's files there, not across the machine."
    ]
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

  defp agent_line(%{workflow: workflow, stages: stages}, _own) do
    path = Enum.map_join(stages, " → ", &"#{&1.name} (#{&1.agent})")
    "- workflow #{workflow}: #{path}; a work without an agent goes through it"
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
    comments = Enum.map(comments || [], & &1.body)

    if request.status == "closed" do
      ["## Request\n" <> Enum.join([header <> ", " <> Out.answered() | comments], "\n")]
    else
      lines = [header, Out.answer_request() | waiting_options(request)] ++ comments
      ["## Request\n" <> Enum.join(lines, "\n")]
    end
  end

  # The options of a waiting request an agent may pick.
  defp waiting_options(request) do
    request.options
    |> Jason.decode!()
    |> Enum.reject(fn {_name, calls} -> Enum.any?(calls, &Map.has_key?(&1["args"], "scope")) end)
    |> Enum.sort()
    |> Enum.map(&option_line/1)
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
