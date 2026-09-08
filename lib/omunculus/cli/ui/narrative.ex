defmodule Omunculus.CLI.UI.Narrative do
  @moduledoc "Chronological actions with paired starts/results and short stable identities."
  @behaviour Omunculus.CLI.UI
  alias Omunculus.CLI.UI.Text

  @impl true
  def init(ctx) do
    {%{width: ctx.width, next: 0, runs: %{}, work: %{}, pending: %{}},
     Text.lines("#{ctx.mode} · #{ctx.path} · narrative", ctx.width) ++
       Text.lines(
         "Action numbers link START to END; DONE marks an atomic recorded event.",
         ctx.width
       )}
  end

  @impl true
  def event(item, state) do
    e = item.event
    p = e.payload
    {state, work} = identity(state, :work, e.work_item_id)
    {state, child} = identity(state, :work, p["child_work_item_id"])
    {state, run} = identity(state, :runs, e.run_id)
    actor = if run, do: "Run #{run}", else: "Harness"
    {state, lines} = present(e.type, item, state, actor, work, child)

    detail =
      if item.detail == "full",
        do:
          ["│ Technical event ##{e.sequence} · #{e.type}"] ++
            Enum.map(item.lines, &("│   " <> &1)),
        else: []

    # All strings are wrapped before printing, including identifiers and comments.
    {state,
     Enum.flat_map(lines ++ detail, fn line ->
       case Regex.run(~r/^(│ *)(.*)$/u, line) do
         [_, prefix, content] -> Text.lines(clean(content), state.width, prefix)
         _ -> Text.lines(clean(line), state.width, "", "│  ")
       end
     end)}
  end

  defp present("run.started", i, s, actor, work, _child) do
    p = i.event.payload

    {s, n} =
      begin_action(
        s,
        {:run, i.event.run_id},
        "#{actor} · #{p["agent_id"] || "agent not recorded"}"
      )

    {s,
     [
       "",
       "┌── #{n} START · #{actor} · #{p["agent_id"] || "agent not recorded"}",
       "│ Stage: #{p["stage"] || "not recorded"} · Reason: #{p["reason"] || "not recorded"} · Work Item #{work}",
       "│ Objective: #{i.instruction || "not recorded"}"
     ]}
  end

  defp present(type, i, s, actor, _work, _) when type in ["run.completed", "run.failed"] do
    {s, n} = end_action(s, {:run, i.event.run_id})
    p = i.event.payload

    {s,
     if(p["comment"], do: ["│ Comment · #{actor}:"] ++ note(p["comment"]), else: []) ++
       note(p["reason"]) ++
       ["└── #{n} END · #{actor} · #{p["outcome"] || "failed"}"]}
  end

  defp present(type, i, s, actor, _work, _)
       when type in ["model.call.requested", "tool.call.requested"] do
    p = i.event.payload

    action =
      if type == "model.call.requested",
        do: "Model · Round #{p["round"]}",
        else: "Tool #{p["tool"]} · Round #{p["round"]}"

    {s, n} = begin_action(s, i.event.event_id, "#{actor} · #{action}")
    args = if type == "tool.call.requested", do: arguments(p["args"]), else: []
    {s, ["├─○ #{n} START · #{actor} · #{action}"] ++ args}
  end

  defp present(type, i, s, actor, _work, _)
       when type in ["model.call.completed", "model.call.failed", "tool.call.completed"] do
    p = i.event.payload
    {s, n} = end_action(s, i.event.causation_id || p["call_id"])
    failed = type == "model.call.failed" or p["outcome"] == "error"
    marker = if failed, do: "×", else: "●"

    action =
      if type == "tool.call.completed",
        do: "Tool #{p["tool"]}",
        else: "Model · Round #{p["round"]}"

    outcome = if failed, do: "failed", else: p["outcome"] || "response received"

    content =
      cond do
        type == "tool.call.completed" -> note(p["output"])
        failed -> note(p["reason"])
        true -> note(get_in(p, ["response", "content"]))
      end

    {s,
     ["├─#{marker} #{n} END · #{actor} · #{action} · #{outcome} · #{p["duration_ms"] || "?"} ms"] ++
       content}
  end

  defp present("task.requested", i, s, _actor, work, _) do
    instant(s, "User requested Work Item #{work}", note(i.event.payload["instruction"]))
  end

  defp present("task.delegated", i, s, actor, work, child) do
    instant(
      s,
      "#{actor} delegated · Work Item #{work} → #{child}",
      []
    )
  end

  defp present("task.assessment_requested", i, s, _, work, _) do
    {s, reviewer} = identity(s, :work, i.event.payload["reviewer"])
    {s, n} = begin_action(s, i.event.event_id, "Assessment of Work Item #{work}")
    {s, ["├─○ #{n} START · Assessment of Work Item #{work} · Responsible: Work Item #{reviewer}"]}
  end

  defp present("task.assessment_resolved", i, s, _, work, _) do
    {s, n} = end_action(s, i.event.payload["request_id"])
    {s, ["├─● #{n} END · Assessment of Work Item #{work}"] ++ note(i.event.payload["comment"])}
  end

  defp present("task.advanced", i, s, _, work, _) do
    instant(
      s,
      "Harness advanced Work Item #{work} · #{i.event.payload["from"]} → #{i.event.payload["to"]}",
      []
    )
  end

  defp present("task.completed", i, s, _, work, _) do
    instant(
      s,
      "Work Item #{work} completed",
      note(i.event.payload["comment"] || i.event.payload["result"])
    )
  end

  defp present("task.break", i, s, _, work, _) do
    instant(
      s,
      "Work Item #{work} · BREAK · escalation requested",
      note(i.event.payload["comment"])
    )
  end

  defp present(type, _i, s, _, _, _)
       when type in [
              "session.created",
              "policy.loaded",
              "task.report_handled",
              "task.run_requested"
            ],
       do: {s, []}

  defp present(type, i, s, actor, _, _) do
    # Unknown events and rejections remain visible; never invent a semantic result.
    instant(
      s,
      "#{actor} · #{type}",
      if(i.detail == "full", do: [], else: Enum.map(i.lines, &("│  " <> &1)))
    )
  end

  @impl true
  def finish(s) do
    lines =
      s.pending
      |> Map.values()
      |> Enum.sort()
      |> Enum.flat_map(fn {n, label} ->
        Text.lines("#{n} OPEN · #{label} · no result recorded in this history", s.width, "│  ")
      end)

    {s, lines}
  end

  defp identity(s, _, nil), do: {s, nil}

  defp identity(s, field, id) do
    values = Map.fetch!(s, field)
    label = Map.get(values, id, map_size(values) + 1) |> to_string() |> String.pad_leading(2, "0")
    {Map.put(s, field, Map.put(values, id, label)), label}
  end

  defp begin_action(s, key, label) do
    n = s.next + 1
    label = clean(label)
    {%{s | next: n, pending: Map.put(s.pending, key, {n, label})}, n}
  end

  defp end_action(s, key) do
    case Map.pop(s.pending, key) do
      {nil, _} -> {s, "? (start not recorded)"}
      {{n, _}, pending} -> {%{s | pending: pending}, n}
    end
  end

  defp instant(s, title, content),
    do: {%{s | next: s.next + 1}, ["├─● #{s.next + 1} DONE · #{title}"] ++ content}

  defp arguments(args) when is_map(args),
    do: args |> Enum.sort() |> Enum.flat_map(fn {k, v} -> note("#{k}: #{value(v)}") end)

  defp arguments(_), do: []
  defp note(nil), do: []
  defp note(""), do: []
  defp note(v), do: value(v) |> String.split("\n") |> Enum.map(&("│  " <> &1))
  defp value(v) when is_binary(v), do: v
  defp value(v), do: Jason.encode!(v)

  defp clean(text),
    do:
      String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F]/, fn c ->
        "\\u" <> (c |> :binary.first() |> Integer.to_string(16) |> String.pad_leading(4, "0"))
      end)
end
