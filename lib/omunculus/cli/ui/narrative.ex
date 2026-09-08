defmodule Omunculus.CLI.UI.Narrative do
  @moduledoc "Run-centred chronological UI; recorded identities and individual calls."
  @behaviour Omunculus.CLI.UI
  alias Omunculus.CLI.UI.{Text, RunView}

  @impl true
  def init(ctx) do
    {%{
       width: ctx.width,
       next: 0,
       ids: %{},
       runs: %{},
       starts: %{},
       sources: %{},
       pending: %{},
       active: nil,
       rounds: %{}
     }, Text.lines("#{ctx.mode} · #{ctx.path} · narrative", ctx.width)}
  end

  @impl true
  def event(i, s) do
    e = i.event
    p = e.payload

    source = %{
      e
      | payload:
          Map.take(p, ["comment", "instruction"])
          |> Map.put("args", Map.take(p["args"] || %{}, ["comment"]))
    }

    s = %{s | sources: Map.put(s.sources, e.event_id, source)}

    s =
      if e.run_id && not Map.has_key?(s.ids, e.run_id),
        do: %{s | ids: Map.put(s.ids, e.run_id, pad(map_size(s.ids) + 1))},
        else: s

    s =
      if e.type == "run.started" do
        start = %{e | payload: Map.drop(p, ["checkpoint", "discovery", "flow"])}

        %{
          s
          | starts: Map.put(s.starts, e.run_id, start),
            runs: Map.put(s.runs, e.run_id, RunView.new(start))
        }
      else
        s
      end

    s =
      if s.runs[e.run_id],
        do: %{s | runs: Map.update!(s.runs, e.run_id, &RunView.update(&1, e))},
        else: s

    visible =
      i.detail == "full" or
        e.type not in [
          "session.created",
          "policy.loaded",
          "task.report_handled",
          "task.run_requested"
        ]

    if visible do
      own =
        e.run_id && s.runs[e.run_id] &&
          (String.starts_with?(e.type, "run.") or String.starts_with?(e.type, "model.call.") or
             String.starts_with?(e.type, "tool.call."))

      {s, head} = if own, do: focus(s, e.run_id, e.type == "run.started"), else: pause(s)
      {s, body} = present(e, s)

      detail =
        if i.detail == "full",
          do:
            ["│ Technical event ##{e.sequence} · #{e.type}"] ++ Enum.map(i.lines, &("│   " <> &1)),
          else: []

      {s, tail} =
        cond do
          e.type in ["run.completed", "run.failed"] and own ->
            r = s.runs[e.run_id]
            label = if e.type == "run.failed", do: "FAILED", else: "COMPLETED"

            tail =
              RunView.summary(r) ++
                rule(
                  s,
                  "└── Run #{s.ids[e.run_id]} · #{label} · #{RunView.elapsed(r)} · Outcome: #{p["outcome"] || "failed"} "
                )

            {%{s | active: nil}, tail}

          own ->
            {s, []}

          true ->
            {s, rule(s, "└── Recorded ")}
        end

      lines =
        if own,
          do: head ++ body ++ detail ++ tail,
          else: head ++ rule(s, "┌── Coordination event ") ++ body ++ detail ++ tail

      {s, format(lines, s.width)}
    else
      {s, []}
    end
  end

  defp focus(%{active: id} = s, id, _), do: {s, []}

  defp focus(s, id, started) do
    {s, ending} = pause(s)
    heading = "┌── Run #{s.ids[id]} · #{if started, do: "STARTED", else: "CONTINUED"} "

    {%{s | active: id},
     ending ++ rule(s, heading) ++ RunView.header(s.runs[id], s.starts, s.sources) ++ ["│"]}
  end

  defp pause(%{active: nil} = s), do: {s, []}

  defp pause(s),
    do:
      {%{s | active: nil},
       rule(s, "└── Run #{s.ids[s.active]} · DISPLAY PAUSED (execution unchanged) ")}

  defp present(%{type: "run.started"} = e, s) do
    {s, n} = begin_action(s, {:run, e.run_id}, "Run #{s.ids[e.run_id]}")
    {s, ["├─○ #{n} START · Run #{s.ids[e.run_id]}"]}
  end

  defp present(%{type: type} = e, s) when type in ["run.completed", "run.failed"] do
    {s, n} = end_action(s, {:run, e.run_id})
    marker = if type == "run.failed", do: "×", else: "●"

    {s,
     ["│", "│ Comment · Run #{s.ids[e.run_id]}:"] ++
       RunView.note(e.payload["comment"] || e.payload["reason"]) ++
       [
         "│",
         "├─#{marker} #{n} END · Run #{s.ids[e.run_id]} · #{e.payload["outcome"] || "failed"}"
       ]}
  end

  defp present(%{type: type} = e, s)
       when type in ["model.call.requested", "tool.call.requested"] do
    p = e.payload
    key = {e.run_id, p["round"]}

    {s, round_lines} =
      if type == "model.call.requested" and not Map.has_key?(s.rounds, key) do
        {%{
           s
           | rounds:
               Map.put(s.rounds, key, %{expected: nil, returned: [], closed: false, failed: false})
         }, ["│", "├─○ Round #{p["round"]} · STARTED"]}
      else
        {s, []}
      end

    {s, tool_lines} =
      if type == "model.call.requested" and is_list(p["schemas"]) and s.runs[e.run_id] do
        names =
          Enum.map(p["schemas"], &get_in(&1, ["function", "name"])) |> Enum.reject(&is_nil/1)

        old = s.runs[e.run_id].tools
        s = %{s | runs: Map.update!(s.runs, e.run_id, &%{&1 | tools: names})}

        {s,
         if(old == names,
           do: [],
           else: ["│ Tools exposed in this round:"] ++ Enum.map(names, &("│   ● " <> &1))
         )}
      else
        {s, []}
      end

    label =
      if type == "model.call.requested",
        do: "Model · Round #{p["round"]}",
        else: "Tool #{p["tool"]} · Round #{p["round"]}"

    {s, n} = begin_action(s, e.event_id, label)
    # The event ID, not a provider-reused tool_call_id, identifies an attempt.
    request = %{number: n, label: label, tool_id: p["tool_call_id"], round: key}
    s = %{s | pending: Map.put(s.pending, e.event_id, request)}
    args = if type == "tool.call.requested", do: fields(p["args"] || %{}), else: []

    {s,
     round_lines ++ tool_lines ++ ["├─○ #{n} START · Run #{s.ids[e.run_id]} · #{label}"] ++ args}
  end

  defp present(%{type: type} = e, s)
       when type in ["model.call.completed", "model.call.failed", "tool.call.completed"] do
    p = e.payload
    id = e.causation_id || p["call_id"]
    request = s.pending[id]
    {s, n} = end_action(s, id)
    failed = type == "model.call.failed" or p["outcome"] == "error"
    marker = if failed, do: "×", else: "●"

    label =
      if type == "tool.call.completed",
        do: "Tool #{p["tool"]}",
        else: "Model · Round #{p["round"]}"

    content =
      if type == "tool.call.completed",
        do: p["output"],
        else: p["reason"] || get_in(p, ["response", "content"])

    key =
      if request && Map.has_key?(request, :round), do: request.round, else: {e.run_id, p["round"]}

    {s, round_lines} = finish_round(s, key, e, request)

    {s,
     [
       "├─#{marker} #{n} END · Run #{s.ids[e.run_id]} · #{label} · #{if failed, do: "failed", else: p["outcome"] || "completed"} · #{p["duration_ms"] || "not recorded"} ms"
     ] ++
       if(content, do: RunView.note(content), else: []) ++ round_lines}
  end

  defp present(%{type: "task.assessment_requested"} = e, s) do
    {s, n} = begin_action(s, e.event_id, "Assessment of #{e.work_item_id}")
    {s, ["├─○ #{n} START · Assessment of #{e.work_item_id}"] ++ fields(e.payload)}
  end

  defp present(%{type: "task.assessment_resolved"} = e, s) do
    {s, n} = end_action(s, e.payload["request_id"])
    {s, ["├─● #{n} END · Assessment of #{e.work_item_id}"] ++ RunView.note(e.payload["comment"])}
  end

  defp present(e, s) do
    title =
      case e.type do
        "task.completed" ->
          "Work Item #{e.work_item_id} completed"

        "task.advanced" ->
          "Work Item #{e.work_item_id} · #{e.payload["from"]} → #{e.payload["to"]}"

        "task.delegated" ->
          "Delegated · #{e.work_item_id} → #{e.payload["child_work_item_id"]}"

        "task.break" ->
          "Work Item #{e.work_item_id} · BREAK"

        _ ->
          e.type
      end

    {%{s | next: s.next + 1},
     ["├─● #{s.next + 1} DONE · #{title}"] ++
       fields(Map.drop(e.payload, ["checkpoint", "messages", "schemas", "result"]))}
  end

  defp finish_round(s, key, e, request) do
    case s.rounds[key] do
      nil ->
        {s, []}

      row ->
        row =
          cond do
            e.type == "model.call.failed" ->
              %{row | expected: [], failed: true}

            e.type == "model.call.completed" ->
              %{
                row
                | expected:
                    case get_in(e.payload, ["response", "tool_calls"]) do
                      calls when is_list(calls) -> Enum.map(calls, & &1["id"])
                      _ -> nil
                    end
              }

            request && request[:tool_id] ->
              %{row | returned: [request.tool_id | row.returned]}

            true ->
              row
          end

        done = not row.closed and is_list(row.expected) and row.expected -- row.returned == []
        row = %{row | closed: row.closed || done}

        {%{s | rounds: Map.put(s.rounds, key, row)},
         if(done,
           do: [
             "├─#{if row.failed, do: "×", else: "●"} Round #{elem(key, 1)} · #{if row.failed, do: "FAILED", else: "COMPLETED"}",
             "│"
           ],
           else: []
         )}
    end
  end

  @impl true
  def finish(s) do
    {s, close} = pause(s)

    open =
      for {_id, r} <- Enum.sort(s.runs),
          is_nil(r.finish),
          do:
            rule(s, "┌── Run summary · OPEN ") ++
              RunView.summary(r) ++ rule(s, "└── Snapshot end ")

    pending =
      s.pending
      |> Map.values()
      |> Enum.sort_by(& &1.number)
      |> Enum.map(&"│ #{&1.number} OPEN · #{&1.label} · no result recorded")

    pending =
      if pending == [],
        do: [],
        else: rule(s, "┌── Open actions ") ++ pending ++ rule(s, "└── Snapshot end ")

    {s, format(close ++ List.flatten(open) ++ pending, s.width)}
  end

  defp begin_action(s, key, label) do
    n = s.next + 1
    {%{s | next: n, pending: Map.put(s.pending, key, %{number: n, label: label})}, n}
  end

  defp end_action(s, key) do
    case Map.pop(s.pending, key) do
      {nil, _} -> {s, "? (start not recorded)"}
      {%{number: n}, pending} -> {%{s | pending: pending}, n}
    end
  end

  defp fields(map),
    do:
      map
      |> Enum.sort()
      |> Enum.flat_map(fn {k, v} ->
        ["│ #{k}:"] ++ RunView.note(if(is_binary(v), do: v, else: Jason.encode!(v)))
      end)

  defp rule(s, prefix) do
    # Keep both the indicator and closing rule when long IDs force wrapping.
    [edge, text] = String.split(prefix, " ", parts: 2)

    chunks = Text.lines(text, max(s.width - 8, 1))

    border = fn line ->
      edge <> " " <> line <> String.duplicate("─", max(s.width - Text.cells(line) - 4, 1))
    end

    if edge == "┌──" do
      [border.(hd(chunks)) | Enum.map(tl(chunks), &("│  " <> &1))]
    else
      Enum.map(Enum.drop(chunks, -1), &("│  " <> &1)) ++ [border.(List.last(chunks))]
    end
  end

  defp format(lines, width) do
    lines =
      lines
      |> Enum.chunk_by(& &1)
      |> Enum.flat_map(fn xs -> if hd(xs) == "│", do: ["│"], else: xs end)

    Enum.flat_map(lines, fn line ->
      line =
        String.replace(line, ~r/[\x00-\x08\x0B-\x1F\x7F]/, fn c ->
          "\\u" <> (c |> :binary.first() |> Integer.to_string(16) |> String.pad_leading(4, "0"))
        end)

      cond do
        String.starts_with?(line, ["┌──", "└──"]) ->
          [line]

        String.starts_with?(line, "├─") ->
          Text.lines(String.slice(line, 3..-1//1), width, String.slice(line, 0, 3), "│  ")

        String.starts_with?(line, "│") ->
          [_, prefix, content] = Regex.run(~r/^(│ *)(.*)$/u, line)
          Text.lines(content, width, prefix)

        true ->
          Text.lines(line, width)
      end
    end)
  end

  defp pad(n), do: n |> to_string() |> String.pad_leading(2, "0")
end
