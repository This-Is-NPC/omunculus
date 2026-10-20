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
  from one workspace to another; the work's title, its id and, in a
  workflow, the workflow and its stage, its goal, its last comment, and its last closed run (`last_run`), or,
  without a work, the run that opened the run's request (`opener`), as
  `Omunculus.Tools.Record` lines without this tool's calls, each call's
  output cut to `last_run_output_bytes` in the args when set. Then, under
  `## Children`, every work handed down from the run's work as it stands:
  its title, agent, id, workflow stage and state, a child that broke
  marked as waiting on this run to reopen it, retire it or break the work, with its
  last comment, and a child that is done, unless it is under `## Results`,
  with its last comment, its report. Under `## Results`, what the works handed down from the run's work came back
  with since its last closed run: each child closed or cancelled since,
  with its last comment, and, when the run was opened by a child's
  `break`, that child's report. A run with a request gets the request's
  requester, while it waits the options an agent may pick with their tool
  calls — not those granting with a `scope`, which only a person may —
  and its comments, the reply among them once it is answered. Under
  `## Inbox`, a depth-0 run sees all pending requests addressed to its
  agent in its conversation, with original questions and work/stage context.
  A request already in that inbox is not repeated in `## Request`.
  The opening's notification comments join that section when it carried
  `inbox_id`. Under `## Attachments`, the files attached in the run's
  conversation, each with its name, media type, size, who attached it and
  its sha256. The message of the opening comes last.

  With `session_ttl_ms` and `session_max_bytes` in the args, and the
  `session` view (the work with its closed runs) or, for a run without a
  work, the `chat` view (its conversation's closed runs that had none),
  the run may continue its
  `agent`'s paused session (`Omunculus.Tools.Session`): the output's
  `session` then carries the history and `since`, what happened since the
  pause — the children, the results, the request, the inbox and the message, or that
  the work goes on — and the run keeps the instructions the session started
  with; when its own differ, `since` adds its `## Tools`.
  """

  alias Omunculus.Tool.Manifest
  alias Omunculus.Tools.{Out, Record, Session}

  # The sections that begin the context of an assembled prompt.
  @context_start ~r/\n\n(?=## (Environment|Work|Works|Conversation|Last comment|Last run|Children|Results|Request|Inbox|Attachments|Message)\n)/

  @spec run(map) :: map
  def run(%{name: name, args: args, view: view} = input) do
    text = Map.get(args, "text", "")
    cards = view["catalog"] || []

    instructions =
      [String.trim(text)] ++
        agents_section(view["agents"] || [], cards) ++
        [tools_section(cards)] ++
        skills_section(view["skills"] || [])

    limit = args["conversation_bytes"]

    # What happened since a pause, which a continued session is told.
    news =
      works_section(view["conversation_works"], limit) ++
        children_section(view["children"], view["results"] || []) ++
        results_section(view["results"] || [], view["cause"]) ++
        request_section(
          outside_inbox(view["request"], view["inbox"] || []),
          view["request_comments"]
        ) ++
        inbox_section(view, args) ++
        attachments_section(view["attachments"]) ++
        message_section(view["message"])

    session = session(session_runs(view), args, news)

    context =
      environment_section(Map.get(input, :roots, [])) ++
        work_section(view["work"]) ++
        comment_section(view["comments"]) ++
        last_run_section(view["last_run"] || view["opener"], name, args) ++
        conversation_section(session, view["chat"], limit) ++
        news

    context
    |> Enum.join("\n\n")
    |> Out.ok()
    |> put_session(session, Enum.join(instructions, "\n\n"), cards)
  end

  # A run with a work goes on with the work's runs; one without, with its
  # conversation's.
  defp session_runs(%{"session" => %{runs: runs}}), do: runs
  defp session_runs(%{"chat" => runs}), do: runs
  defp session_runs(_view), do: nil

  defp session(
         runs,
         %{"session_ttl_ms" => ttl_ms, "session_max_bytes" => max_bytes} = args,
         news
       )
       when is_list(runs) do
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

  defp session(_runs, _args, _news), do: nil

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

  # Every work handed down from this one as it stands, so a run finds the
  # id of a child to reopen however it was opened, and what a child that
  # is done came back with after the run that saw it under ## Results.
  defp children_section(nil, _results), do: []
  defp children_section([], _results), do: []

  defp children_section(children, results) do
    reported = MapSet.new(results, & &1.id)

    lines =
      Enum.map(children, fn child ->
        "- #{child.title} (#{child.assignee}, work #{child.id}#{stage_of(child)}): " <>
          child_state(child, MapSet.member?(reported, child.id))
      end)

    ["## Children\n" <> Enum.join(lines, "\n")]
  end

  defp stage_of(%{workflow: workflow, stage: stage}) when is_binary(workflow),
    do: ", workflow #{workflow}, stage #{stage}"

  defp stage_of(_child), do: ""

  # A waiting child with nothing to wait on broke and waits on its parent.
  defp child_state(%{state: "waiting", waiting: nil} = child, _reported) do
    "broke, waiting on you to reopen it, retire it or break this work" <> report(child)
  end

  defp child_state(%{state: "waiting", waiting: "child"}, _reported),
    do: "waiting on its own works"

  defp child_state(%{state: "waiting", waiting: "request"}, _reported),
    do: "waiting on a request"

  defp child_state(%{state: "done"} = child, false), do: "done" <> report(child)
  defp child_state(%{state: state}, _reported), do: state

  defp report(%{last_comment: %{body: body}}), do: ": " <> body
  defp report(_child), do: ""

  # What the works handed down from this one came back with since its last
  # run: each closed child's last comment, its report, and the report of
  # the child whose break woke it.
  defp results_section(children, cause) do
    lines =
      Enum.map(children, fn child ->
        "- #{child.title} (#{child.assignee}, #{child.state}, work #{child.id})#{report(child)}"
      end) ++ broken(cause)

    if lines == [], do: [], else: ["## Results\n" <> Enum.join(lines, "\n")]
  end

  defp broken(%{type: "break", actor_id: agent, work_id: work_id, body: body}),
    do: ["- #{agent} broke its work #{work_id}: #{Jason.decode!(body)["body"]}"]

  defp broken(_cause), do: []

  # The root works of the conversation of a run without a work, so a
  # message about one finds it.
  defp works_section(nil, _limit), do: []
  defp works_section([], _limit), do: []

  defp works_section(works, limit) do
    lines =
      Enum.map(works, fn work ->
        comment = if work.last_comment, do: ": " <> work.last_comment.body, else: ""
        "- #{work.title} (work #{work.id}, #{root_state(work)})#{comment}"
      end)

    ["## Works\n" <> Enum.join(newest(lines, limit), "\n")]
  end

  defp root_state(%{state: "waiting", waiting: "message"}),
    do: "waiting on the person's next message"

  defp root_state(%{state: state}), do: state

  # What the person and the agent said in the conversation, for a run
  # without a work whose session starts over: the agent's last reply that
  # called no tool, not the notes it wrote beside its calls.
  defp conversation_section(nil, [_ | _] = runs, limit) do
    exchanges =
      for run <- runs, run.message do
        answer =
          run.events
          |> Enum.filter(&(&1.type == "model"))
          |> Enum.map(&Record.answer(&1.body))
          |> Enum.reject(&(String.trim(&1) == ""))
          |> List.last()

        "- person: #{run.message.body}" <> if(answer, do: "\n- you: #{answer}", else: "")
      end

    case newest(exchanges, limit) do
      [] -> []
      kept -> ["## Conversation\n" <> Enum.join(kept, "\n")]
    end
  end

  defp conversation_section(_session, _runs, _limit), do: []

  # The last of `lines` that fit in `limit` bytes together; a nil limit keeps all.
  defp newest(lines, nil), do: lines

  defp newest(lines, limit) do
    lines
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn line, {kept, bytes} ->
      bytes = bytes + byte_size(line) + 1
      if bytes <= limit, do: {:cont, {[line | kept], bytes}}, else: {:halt, {kept, bytes}}
    end)
    |> elem(0)
  end

  defp attachments_section([_ | _] = attachments) do
    lines =
      Enum.map(attachments, fn file ->
        "- #{file["name"]} (#{file["media_type"]}, #{file["bytes"]} bytes) from #{file["by"]}, sha256 #{file["sha256"]}"
      end)

    ["## Attachments\n" <> Enum.join(lines, "\n")]
  end

  defp attachments_section(_attachments), do: []

  defp message_section(nil), do: []
  defp message_section(message), do: ["## Message\n#{message.body}"]

  defp work_section(nil), do: []

  defp work_section(work),
    do: [
      "## Work\n" <> Enum.join([work.title, "id: #{work.id}" | stage_line(work)], "\n"),
      "## Goal\n#{work.goal}"
    ]

  # Where the work is in the workflow it goes through.
  defp stage_line(%{workflow: workflow, stage: stage}) when is_binary(workflow),
    do: ["workflow: #{workflow}, stage: #{stage}"]

  defp stage_line(_work), do: []

  defp outside_inbox(nil, _groups), do: nil

  defp outside_inbox(request, groups) do
    if Enum.any?(groups, fn group -> Enum.any?(group.requests, &(&1.id == request.id)) end),
      do: nil,
      else: request
  end

  defp inbox_section(view, args) do
    received =
      Enum.map(view["inbox"] || [], fn group ->
        questions =
          Enum.map_join(group.requests, "\n\n", fn request ->
            comments =
              if view["request"] && view["request"].id == request.id,
                do: view["request_comments"] || [%{body: request.reason || ""}],
                else: [%{body: request.reason || ""}]

            Enum.join(request_lines(request, comments, false), "\n")
          end)

        "### Conversation #{group.conversation_id}\n#{Out.received_requests()}\n#{questions}"
      end)

    notice =
      case Map.get(args, "inbox_id") do
        id when is_binary(id) and id != "" ->
          ["#{id}\n" <> Enum.map_join(view["inbox_comments"] || [], "\n", & &1.body)]

        _other ->
          []
      end

    case received ++ notice do
      [] -> []
      parts -> ["## Inbox\n" <> Enum.join(parts, "\n\n")]
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
      required = Enum.count(agents, &match?(%{required: true}, &1))
      ["## Agents\n" <> Enum.map_join(agents, "\n", &agent_line(&1, own, required))]
    else
      []
    end
  end

  defp agent_line(%{workflow: workflow, stages: stages}, _own, required) do
    path = Enum.map_join(stages, " → ", &"#{&1.name} (#{&1.agent})")

    case required do
      1 -> "- workflow #{workflow}: #{path}; every work goes through it"
      0 -> "- workflow #{workflow}: #{path}; a work naming it goes through it"
      _several -> "- workflow #{workflow}: #{path}; a work names one of these workflows"
    end
  end

  # What an agent can do that this run cannot is why to hand it a work.
  defp agent_line(%{name: name, tools: tools}, own, _required) do
    case Enum.reject(tools, &MapSet.member?(own, &1)) do
      [] -> "- #{name}"
      beyond -> "- #{name}: also #{Enum.join(beyond, ", ")}"
    end
  end

  defp request_section(nil, _comments), do: []

  defp request_section(request, comments),
    do: ["## Request\n" <> Enum.join(request_lines(request, comments, true), "\n")]

  defp request_lines(request, comments, answer_instruction?) do
    header = "#{request.id} #{Out.requested_by(Omunculus.Participant.label(request.requester))}"
    comments = Enum.map(comments || [], & &1.body)

    if request.status == "closed" do
      [header <> ", " <> Out.answered(request.answer)] ++
        origin_context(request) ++
        comments ++
        origin_lines(Map.get(request, :origins, %{}))
    else
      [header] ++
        origin_context(request) ++
        if(answer_instruction?, do: [Out.answer_request()], else: []) ++
        waiting_options(request) ++ origin_lines(Map.get(request, :origins, %{})) ++ comments
    end
  end

  defp origin_context(request) do
    fields =
      for key <- [:work_id, :workflow, :stage],
          value = Map.get(request, key),
          is_binary(value),
          do: "#{if key == :work_id, do: "work", else: key} #{value}"

    if fields == [], do: [], else: ["origin: " <> Enum.join(fields, ", ")]
  end

  defp origin_lines(origins) do
    Enum.flat_map(Enum.sort(origins), fn {part, origin} ->
      [
        "part #{part}: request #{origin.id} (#{origin.status}), #{Out.requested_by(Omunculus.Participant.label(origin.requester))}"
      ] ++
        origin_context(origin) ++
        [origin.reason || "" | waiting_options(origin)] ++
        origin_lines(origin.origins)
    end)
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
