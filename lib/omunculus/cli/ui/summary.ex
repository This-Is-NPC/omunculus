defmodule Omunculus.CLI.UI.Summary do
  @moduledoc "Session analytics from recorded events, shared by every layout."
  alias Omunculus.CLI.UI.Text

  def new do
    %{
      counts: %{},
      metrics: %{},
      work: MapSet.new(),
      completed: MapSet.new(),
      models: MapSet.new(),
      first: nil,
      last: nil,
      depth: nil,
      session: nil
    }
  end

  def event(s, e) do
    p = e.payload

    s = %{
      s
      | counts: Map.update(s.counts, e.type, 1, &(&1 + 1)),
        first: s.first || e.occurred_at,
        last: e.occurred_at,
        session: s.session || e.session_id
    }

    case e.type do
      "task.requested" ->
        %{s | work: put(s.work, e.work_item_id)}

      "task.delegated" ->
        %{s | work: put(s.work, p["child_work_item_id"])}

      "task.completed" ->
        %{s | completed: put(s.completed, e.work_item_id)}

      "run.started" ->
        %{s | models: put(s.models, p["model"]), depth: max_depth(s.depth, p["depth"])}

      type when type in ["model.call.completed", "model.call.failed"] ->
        Enum.reduce(["prompt_tokens", "completion_tokens", "total_tokens", "cost"], s, fn key,
                                                                                          acc ->
          metric(acc, key, get_in(p, ["usage", key]))
        end)
        |> metric("model_ms", p["duration_ms"])

      "tool.call.completed" ->
        s = %{
          s
          | counts: Map.update(s.counts, "tool:" <> (p["outcome"] || "unknown"), 1, &(&1 + 1))
        }

        metric(s, "tool_ms", p["duration_ms"])

      _ ->
        s
    end
  end

  def rows(s, runs) do
    count = &Map.get(s.counts, &1, 0)
    calls = count.("model.call.completed") + count.("model.call.failed")
    tools = count.("tool.call.completed")

    [
      {"Session", s.session || "not recorded"},
      {"Models",
       if(MapSet.size(s.models) == 0,
         do: "not recorded",
         else: s.models |> Enum.sort() |> Enum.join(", ")
       )},
      {"Events",
       s.counts
       |> Enum.reject(fn {k, _} -> String.starts_with?(k, "tool:") end)
       |> Enum.map(&elem(&1, 1))
       |> Enum.sum()},
      {"Recorded span (ms)", span(s.first, s.last)},
      {"Runs started", count.("run.started")},
      {"Runs closed / failed / open",
       "#{count.("run.completed")} / #{count.("run.failed")} / #{Enum.count(runs, fn {_, r} -> not r.closed? end)}"},
      {"Maximum depth", s.depth || "not recorded"},
      {"Work Items created / completed", "#{MapSet.size(s.work)} / #{MapSet.size(s.completed)}"},
      {"Delegations", count.("task.delegated")},
      {"Assessments resolved", count.("task.assessment_resolved")},
      {"Stage advances / breaks", "#{count.("task.advanced")} / #{count.("task.break")}"},
      {"Model calls requested", count.("model.call.requested")},
      {"Model calls completed / failed",
       "#{count.("model.call.completed")} / #{count.("model.call.failed")}"},
      {"Input tokens", measured(s, "prompt_tokens", calls)},
      {"Output tokens", measured(s, "completion_tokens", calls)},
      {"Total tokens", measured(s, "total_tokens", calls)},
      {"Reported cost (provider units)", measured(s, "cost", calls)},
      {"Model time sum (ms)", measured(s, "model_ms", calls)},
      {"Tool calls requested", count.("tool.call.requested")},
      {"Tools completed / waiting / error",
       "#{count.("tool:completed")} / #{count.("tool:waiting")} / #{count.("tool:error")}"},
      {"Tool time sum (ms)", measured(s, "tool_ms", tools)}
    ]
  end

  def render(s, runs, width, framed \\ false)

  def render(s, runs, width, true) do
    body = render(s, runs, width - 2, false) |> Enum.drop(2)

    [
      "┌── Session summary " <>
        String.duplicate("─", max(width - Text.cells("┌── Session summary "), 1))
    ] ++
      Enum.map(body, &("│ " <> &1)) ++
      [
        "└── Summary end " <>
          String.duplicate("─", max(width - Text.cells("└── Summary end "), 1))
      ]
  end

  def render(s, runs, width, false) do
    # An open table uses horizontal rules only, including in blocks.
    left = min(34, max(div(width - 3, 2), 1))
    right = max(width - left - 3, 1)
    rule = String.duplicate("─", width)

    ["", "Session summary", rule] ++
      Enum.flat_map([{"Metric", "Value"} | rows(s, runs)], fn {key, value} ->
        a = Text.lines(key, left)
        b = Text.lines(to_string(value), right)

        for i <- 0..(max(length(a), length(b)) - 1) do
          label = Enum.at(a, i, "")
          label <> String.duplicate(" ", left - Text.cells(label)) <> "   " <> Enum.at(b, i, "")
        end
      end) ++ [rule]
  end

  defp put(set, nil), do: set
  defp put(set, value), do: MapSet.put(set, value)
  defp max_depth(a, b) when is_integer(b), do: max(a || 0, b)
  defp max_depth(a, _), do: a

  defp metric(s, key, value) when is_number(value) do
    %{
      s
      | metrics:
          Map.update(s.metrics, key, {value, 1}, fn {total, n} -> {total + value, n + 1} end)
    }
  end

  defp metric(s, _, _), do: s

  defp measured(s, key, calls) do
    case s.metrics[key] do
      nil -> "not recorded"
      {value, n} -> "#{value}" <> if(n == calls, do: "", else: " (partial: #{n}/#{calls})")
    end
  end

  defp span(first, last) do
    with {:ok, a, _} <- DateTime.from_iso8601(first || ""),
         {:ok, b, _} <- DateTime.from_iso8601(last || "") do
      DateTime.diff(b, a, :millisecond)
    else
      _ -> "not recorded"
    end
  end
end
