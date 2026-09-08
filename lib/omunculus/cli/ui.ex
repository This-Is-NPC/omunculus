defmodule Omunculus.CLI.UI do
  @moduledoc """
  Presentation only. Add a module implementing init/1, event/2 and finish/1,
  then register its CLI name in layouts/0. Callbacks return {state, lines};
  lines are plain strings, with no IO or runtime access. Every layout receives
  the same prepared event (identity, depth, kind, title and content lines).
  """
  @callback init(map()) :: {term(), [String.t()]}
  @callback event(map(), term()) :: {term(), [String.t()]}
  @callback finish(term()) :: {term(), [String.t()]}

  def layouts,
    do: %{
      "blocks" => __MODULE__.Blocks,
      "timeline" => __MODULE__.Timeline,
      "tree" => __MODULE__.Tree
    }

  def validate(flags) do
    cond do
      not Map.has_key?(layouts(), flags["ui"] || "blocks") ->
        {:error, "--ui must be blocks, timeline or tree"}

      (flags["detail"] || "normal") not in ["normal", "full"] ->
        {:error, "--detail must be normal or full"}

      true ->
        :ok
    end
  end

  def init(opts) do
    module = Map.fetch!(layouts(), opts[:ui] || "blocks")
    width = opts[:width] || __MODULE__.Text.columns(opts[:io] || :stderr)

    {layout, lines} =
      module.init(%{mode: opts[:mode] || "Live", path: opts[:path] || "session", width: width})

    {%{
       summary: __MODULE__.Summary.new(),
       width: width,
       module: module,
       layout: layout,
       runs: %{},
       work_items: %{},
       detail: opts[:detail] || "normal"
     }, lines}
  end

  def event(env, state) do
    state = %{state | summary: __MODULE__.Summary.event(state.summary, env)}
    p = env.payload

    work_items =
      case env.type do
        "task.requested" ->
          Map.put(state.work_items, env.work_item_id, %{
            instruction: p["instruction"],
            parent: nil
          })

        "task.delegated" ->
          Map.put(state.work_items, p["child_work_item_id"], %{
            instruction: p["instruction"],
            parent: env.work_item_id
          })

        _ ->
          state.work_items
      end

    work = Map.get(work_items, env.work_item_id, %{instruction: nil, parent: nil})
    prior = Map.get(state.runs, env.run_id, %{depth: 0, closed?: false})

    run = %{
      depth: p["depth"] || prior.depth,
      closed?: prior.closed? || env.type in ["run.completed", "run.failed"]
    }

    runs = if env.run_id, do: Map.put(state.runs, env.run_id, run), else: state.runs

    kind =
      case env.type do
        "run.started" -> :start
        type when type in ["run.completed", "run.failed"] -> :end
        _ -> :event
      end

    title =
      case kind do
        :start ->
          "RUN #{env.run_id} START · #{p["agent_id"]} · #{p["agent_kind"]} · depth #{run.depth} · stage #{encode(p["stage"])} · #{p["reason"]}"

        :end ->
          "RUN #{env.run_id} END · #{p["outcome"] || "failed"}"

        _ ->
          env.type <>
            if(p["round"], do: " · Round #{p["round"]}", else: "") <>
            if(p["tool"], do: " · #{p["tool"]}", else: "")
      end

    content =
      if state.detail == "full" do
        [Jason.encode!(Omunculus.Event.Envelope.to_map(env), pretty: true)]
      else
        normal(env) ++
          if(kind == :start,
            do: [
              "Parent Work Item: #{work.parent || "none recorded"}",
              "Instruction: #{work.instruction || "not recorded"}"
            ],
            else: []
          )
      end

    item = %{
      kind: kind,
      title: title,
      run_id: if(env.run_id, do: safe(env.run_id)),
      work_item_id: env.work_item_id,
      depth: run.depth,
      sequence: env.sequence,
      timestamp: safe(env.occurred_at),
      lines: Enum.flat_map(content, &String.split(&1, "\n")) |> Enum.map(&safe/1)
    }

    {layout, lines} = state.module.event(%{item | title: safe(title)}, state.layout)
    {%{state | layout: layout, runs: runs, work_items: work_items}, lines}
  end

  def finish(state) do
    {layout, lines} = state.module.finish(state.layout)

    open =
      for {id, run} <- Enum.sort(state.runs),
          not run.closed?,
          do: "Run #{safe(id)}: no closure recorded in this history"

    {%{state | layout: layout},
     lines ++
       Enum.flat_map(open, &__MODULE__.Text.lines(&1, state.width)) ++
       __MODULE__.Summary.render(state.summary, state.runs, state.width)}
  end

  defp normal(%{type: "run.started"} = e) do
    p = e.payload

    [
      "Work Item: #{e.work_item_id || "not recorded"} · Parent Run: #{p["parent_run_id"] || "none"} · Originating Run: #{p["originating_run_id"] || "none"}",
      "Model: #{p["model"] || "not recorded"} · Attempt: #{p["attempt"]}"
    ]
  end

  defp normal(%{type: "model.call.requested"}), do: ["Waiting for model response"]

  defp normal(%{type: "model.call.completed", payload: p}) do
    response = p["response"]

    content =
      case response do
        %{} ->
          text =
            if response["content"], do: fields("Response", response["content"]), else: []

          calls =
            for call <- response["tool_calls"] || [],
                do: "Requested tool: #{get_in(call, ["function", "name"])} · #{call["id"]}"

          text ++ calls

        _ ->
          ["Response: not recorded"]
      end

    content ++
      [
        "Tokens: #{get_in(p, ["usage", "total_tokens"]) || "not recorded"} · Duration: #{p["duration_ms"] || "not recorded"} ms"
      ]
  end

  defp normal(%{type: "policy.loaded", payload: p}),
    do: ["Policy: #{p["hash"]} (table available with --detail full)"]

  defp normal(e) do
    e.payload
    |> Map.drop([
      "checkpoint",
      "schemas",
      "messages",
      "discovery",
      "flow",
      "assessment",
      "round",
      "tool"
    ])
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> fields(k, v) end)
  end

  defp fields(key, value) when is_map(value) and map_size(value) > 0 do
    [key <> ":"] ++
      (value
       |> Enum.sort()
       |> Enum.flat_map(fn {k, v} -> fields(k, v) end)
       |> Enum.map(&("  " <> &1)))
  end

  defp fields(key, value) do
    [first | rest] = String.split(encode(value), "\n")
    ["#{key}: #{first}" | Enum.map(rest, &(String.duplicate(" ", String.length(key) + 2) <> &1))]
  end

  defp encode(v) when is_binary(v), do: v
  defp encode(v), do: Jason.encode!(v)

  defp safe(text),
    do:
      String.replace(text, ~r/[\x00-\x08\x0B-\x1F\x7F]/, fn c ->
        "\\u" <> (c |> :binary.first() |> Integer.to_string(16) |> String.pad_leading(4, "0"))
      end)
end
