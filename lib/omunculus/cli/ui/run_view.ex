defmodule Omunculus.CLI.UI.RunView do
  @moduledoc "Recorded metadata and per-round accounting for narrative Runs."

  def new(e), do: %{start: e, finish: nil, rounds: %{}, tools: e.payload["available_tools"]}

  def update(r, e) do
    p = e.payload

    cond do
      e.type in ["run.completed", "run.failed"] ->
        %{r | finish: e}

      e.type in [
        "model.call.requested",
        "model.call.completed",
        "model.call.failed",
        "tool.call.requested",
        "tool.call.completed"
      ] ->
        row =
          Map.get(r.rounds, p["round"], %{
            models: 0,
            tools: 0,
            tokens: 0,
            usage: 0,
            ms: 0,
            timings: 0,
            results: 0
          })

        model = e.type in ["model.call.completed", "model.call.failed"]
        tool = e.type == "tool.call.completed"
        tokens = get_in(p, ["usage", "total_tokens"])

        row = %{
          row
          | models: row.models + if(model, do: 1, else: 0),
            tools: row.tools + if(tool, do: 1, else: 0),
            tokens: row.tokens + if(model and is_number(tokens), do: tokens, else: 0),
            usage: row.usage + if(model and is_number(tokens), do: 1, else: 0),
            ms:
              row.ms +
                if((model or tool) and is_number(p["duration_ms"]), do: p["duration_ms"], else: 0),
            timings:
              row.timings + if((model or tool) and is_number(p["duration_ms"]), do: 1, else: 0),
            results: row.results + if(model or tool, do: 1, else: 0)
        }

        %{r | rounds: Map.put(r.rounds, p["round"], row)}

      true ->
        r
    end
  end

  def header(r, starts, sources) do
    e = r.start
    p = e.payload
    parent = Map.get(starts, p["parent_run_id"])
    pp = if parent, do: parent.payload, else: %{}

    none =
      if Map.has_key?(p, "parent_run_id") and is_nil(p["parent_run_id"]), do: "none", else: nil

    {comment, origin, kind} = input(e.causation_id, sources, MapSet.new())

    section("Identity", [
      {"Session ID", e.session_id},
      {"Run ID", e.run_id},
      {"Work Item ID", e.work_item_id}
    ]) ++
      section("Agent", [
        {"Name", p["agent_id"]},
        {"Kind", p["agent_kind"]},
        {"Depth", p["depth"]},
        {"Model", p["model"]}
      ]) ++
      section("Parent", [
        {"Run ID", p["parent_run_id"] || none},
        {"Work Item ID", (parent && parent.work_item_id) || none},
        {"Agent", pp["agent_id"] || none},
        {"Model", pp["model"] || none}
      ]) ++
      section("Activation", [
        {"Started", date(e.occurred_at)},
        {"Stage", p["stage"]},
        {"Reason", p["reason"]},
        {"Attempt", p["attempt"]},
        {"Trigger event ID", e.causation_id},
        {"Originating Run ID", p["originating_run_id"]},
        {"Max rounds", p["max_turns"]}
      ]) ++
      ["│", "│ #{if kind == "task.requested", do: "Initial instruction", else: "Input comment"}"] ++
      note(comment) ++ fields([{"Source event ID", origin}]) ++ tools(r.tools)
  end

  def tools(nil),
    do: [
      "│",
      "│ Available tools",
      "│   not recorded (schemas will identify tools when a call is recorded)"
    ]

  def tools(names),
    do:
      ["│", "│ Available tools"] ++
        if(names == [], do: ["│   none"], else: Enum.map(names, &("│   ● " <> &1)))

  def summary(r) do
    rows = r.rounds |> Enum.sort_by(fn {n, _} -> n || 0 end)

    total =
      Enum.reduce(
        rows,
        %{models: 0, tools: 0, tokens: 0, usage: 0, ms: 0, timings: 0, results: 0},
        fn {_, row}, acc -> Map.merge(acc, row, fn _, a, b -> a + b end) end
      )

    finish = r.finish

    section("Run summary", [
      {"Run ID", r.start.run_id},
      {"Started", date(r.start.occurred_at)},
      {"Finished", if(finish, do: date(finish.occurred_at))},
      {"Duration", elapsed(r)},
      {"Outcome", if(finish, do: finish.payload["outcome"] || "failed", else: "OPEN")},
      {"Rounds", length(rows)},
      {"Tool calls", total.tools},
      {"Tokens", usage(total)}
    ]) ++
      ["│", table_row("Round", "Models", "Tools", "Tokens", "Time sum")] ++
      Enum.map(rows ++ [{"Total", total}], fn {n, row} ->
        table_row(n || "?", row.models, row.tools, usage(row), timing(row))
      end)
  end

  defp table_row(round, models, tools, tokens, time) do
    "│ " <>
      Enum.map_join([{round, 7}, {models, 8}, {tools, 7}, {tokens, 24}, {time, 0}], fn {v, width} ->
        String.pad_trailing(to_string(v), width)
      end)
  end

  def elapsed(%{finish: nil}), do: "not recorded"

  def elapsed(r) do
    with {:ok, a, _} <- DateTime.from_iso8601(r.start.occurred_at || ""),
         {:ok, b, _} <- DateTime.from_iso8601(r.finish.occurred_at || "") do
      duration(DateTime.diff(b, a, :millisecond))
    else
      _ -> "not recorded"
    end
  end

  def duration(ms) when ms < 0, do: "invalid recorded interval"
  def duration(ms) when ms < 1000, do: "#{ms}ms"

  def duration(ms) do
    s = div(ms, 1000)

    if(s >= 3600, do: "#{div(s, 3600)}h ", else: "") <>
      if(s >= 60, do: "#{div(rem(s, 3600), 60)}m ", else: "") <> "#{rem(s, 60)}s"
  end

  defp usage(%{usage: 0}), do: "not recorded"
  defp usage(r), do: "#{r.tokens}" <> if(r.usage == r.models, do: "", else: " (partial)")
  defp timing(%{timings: 0}), do: "not recorded"
  defp timing(r), do: duration(r.ms) <> if(r.timings == r.results, do: "", else: " (partial)")
  defp date(nil), do: nil

  defp date(s) do
    case DateTime.from_iso8601(s) do
      {:ok, date, offset} ->
        local = DateTime.add(date, offset, :second)
        sign = if offset < 0, do: "-", else: "+"

        Calendar.strftime(local, "%d/%m/%Y %H:%M:%S") <>
          " #{sign}#{pad(div(abs(offset), 3600))}:#{pad(div(rem(abs(offset), 3600), 60))}"

      _ ->
        s
    end
  end

  defp pad(n), do: n |> to_string() |> String.pad_leading(2, "0")
  defp section(name, values), do: ["│", "│ #{name}"] ++ fields(values)

  defp fields(values),
    do: Enum.map(values, fn {k, v} -> "│   " <> String.pad_trailing(k, 20) <> text(v) end)

  def note(v), do: text(v) |> String.split("\n") |> Enum.map(&("│   " <> &1))
  defp text(nil), do: "not recorded"
  defp text(v) when is_binary(v), do: v
  defp text(v), do: to_string(v)

  defp input(nil, _, _), do: {nil, nil, nil}

  defp input(id, sources, seen) do
    if MapSet.member?(seen, id) do
      {nil, nil, nil}
    else
      case sources[id] do
        nil ->
          {nil, nil, nil}

        e ->
          value =
            e.payload["comment"] || get_in(e.payload, ["args", "comment"]) ||
              if(e.type == "task.requested" and MapSet.size(seen) == 0,
                do: e.payload["instruction"]
              )

          if is_binary(value) and String.trim(value) != "",
            do: {value, id, e.type},
            else: input(e.causation_id, sources, MapSet.put(seen, id))
      end
    end
  end
end
