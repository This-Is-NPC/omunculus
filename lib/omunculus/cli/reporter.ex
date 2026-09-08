defmodule Omunculus.CLI.Reporter do
  @moduledoc false

  use GenServer

  @width 64

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def event(pid, event), do: GenServer.call(pid, {:event, event}, :infinity)
  def finish(pid), do: GenServer.call(pid, :finish, :infinity)

  @impl true
  def init(opts) do
    if opts[:core] || opts[:mode] || opts[:path] do
      session_init(opts)
    else
      run_init(opts)
    end
  end

  defp run_init(opts) do
    io = Keyword.get(opts, :io, :stderr)
    json_events? = Keyword.get(opts, :json_events?, false)

    state = %{
      io: io,
      json_events?: json_events?,
      terminal?: if(json_events?, do: false, else: Keyword.get(opts, :terminal?, terminal?(io))),
      model: Keyword.fetch!(opts, :model),
      tools: Keyword.fetch!(opts, :tools),
      max_rounds: Keyword.fetch!(opts, :max_rounds),
      root: Keyword.get(opts, :root, File.cwd!()),
      verbose?: Keyword.get(opts, :verbose?, false),
      timestamp_format: Keyword.get(opts, :timestamp_format, "%H:%M:%S"),
      pending?: false,
      pending_text: nil,
      pending_started_at: nil,
      spinner_index: 0,
      gap?: true,
      rounds: []
    }

    if json_events? do
      emit_json(state, %{
        type: :run_started,
        model: state.model,
        tools: state.tools,
        max_rounds: state.max_rounds
      })

      {:ok, state}
    else
      line(state, divider("┌── Run started "))

      line(
        state,
        "│ Model: #{state.model} · Tools: #{length(state.tools)} · Max rounds: #{state.max_rounds}"
      )

      line(state, "│")
      {:ok, state}
    end
  end

  defp session_init(opts) do
    {ui, header} = Omunculus.CLI.UI.init(opts)

    state = %{
      ui: ui,
      session?: true,
      session_id: opts[:session_id],
      io: opts[:io] || :stderr,
      json_events?: opts[:json_events?] || false,
      core: opts[:core],
      sequence: 0,
      timestamp_format: opts[:timestamp_format] || "%Y-%m-%dT%H:%M:%S.%fZ"
    }

    if state.core, do: Omunculus.EventCore.subscribe(state.core, session_filter(state))

    unless state.json_events?, do: Enum.each(header, &line(state, &1))

    {:ok, state}
  end

  @impl true
  def handle_info({:event_core, envelope}, %{session?: true} = state) do
    # Delivery notifications omit rejected commands. Read the committed prefix
    # so the live view includes the same evidence as a passive replay.
    state =
      if envelope.sequence > state.sequence do
        Enum.reduce(
          Omunculus.EventCore.stream(state.core, state.sequence, session_filter(state)),
          state,
          &session_event(&2, &1)
        )
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:tick, %{pending?: true} = state) do
    glyphs = ["○", "◔", "◑", "◕"]
    glyph = Enum.at(glyphs, rem(state.spinner_index, length(glyphs)))
    text = String.replace(state.pending_text, "○", glyph, global: false)
    elapsed = max(System.monotonic_time(:millisecond) - state.pending_started_at, 0)
    IO.write(state.io, "\r\e[2K#{text} · #{format_duration(elapsed)}")
    Process.send_after(self(), :tick, 120)
    {:noreply, %{state | spinner_index: state.spinner_index + 1}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  @impl true
  def handle_call(:finish, _from, %{session?: true} = state) do
    state =
      if state.core do
        Omunculus.EventCore.unsubscribe(state.core)

        Enum.reduce(
          Omunculus.EventCore.stream(state.core, state.sequence, session_filter(state)),
          state,
          &session_event(&2, &1)
        )
      else
        state
      end

    unless state.json_events? do
      {_ui, lines} = Omunculus.CLI.UI.finish(state.ui)
      Enum.each(lines, &line(state, &1))

      line(state, "└── End of history · sequence #{state.sequence}")
    end

    {:stop, :normal, :ok, state}
  end

  def handle_call(
        {:event, %Omunculus.Event.Envelope{} = envelope},
        _from,
        %{session?: true} = state
      ),
      do: {:reply, :ok, session_event(state, envelope)}

  def handle_call({:event, event}, _from, %{json_events?: true} = state) do
    emit_json(state, event)

    state =
      case event do
        %{type: :round_completed} ->
          %{
            state
            | rounds:
                state.rounds ++
                  [Map.take(event, [:round, :outcome, :tool_calls, :usage, :duration_ms])]
          }

        %{type: :round_failed} ->
          %{
            state
            | rounds:
                state.rounds ++
                  [
                    Map.merge(Map.take(event, [:round, :duration_ms]), %{
                      outcome: :failed,
                      tool_calls: 0
                    })
                  ]
          }

        _ ->
          state
      end

    case event do
      %{type: type} when type in [:run_completed, :run_failed] ->
        {:stop, :normal, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:event, %{type: :round_started} = event}, _from, state) do
    state = ensure_gap(state)

    state =
      if state.verbose? do
        line(state, "├── Round #{event.round}")
        verbose_line(state, event, "START", "Round")
        verbose_line(state, event, "WAIT", "Model response")
        %{state | gap?: false}
      else
        pending(state, "├─○ Round #{event.round} · Waiting for model...")
      end

    {:reply, :ok, state}
  end

  def handle_call({:event, %{type: :round_completed} = event}, _from, state) do
    detail = round_detail(event)

    state =
      if state.verbose? do
        verbose_line(state, event, "OK", "#{detail} · #{duration(event)}")
        state
      else
        complete_pending(state, "├─● Round #{event.round} · #{detail} · #{duration(event)}")
      end

    round = Map.take(event, [:round, :outcome, :tool_calls, :usage, :duration_ms])
    {:reply, :ok, %{state | rounds: state.rounds ++ [round]}}
  end

  def handle_call({:event, %{type: :round_failed} = event}, _from, state) do
    detail = format_reason(event.reason)

    state =
      if state.verbose? do
        verbose_line(state, event, "FAIL", "Model response · #{detail} · #{duration(event)}")
        verbose_line(state, event, "END", "Round · Failed")
        state
      else
        complete_pending(
          state,
          "├─× Round #{event.round} · #{truncate(detail, 36)} · #{duration(event)}"
        )
      end

    round = Map.merge(Map.take(event, [:round, :duration_ms]), %{outcome: :failed, tool_calls: 0})
    {:reply, :ok, %{state | rounds: state.rounds ++ [round]}}
  end

  def handle_call({:event, %{type: :tool_started} = event}, _from, state) do
    detail = tool_started_detail(state, event)

    state =
      if state.verbose? do
        verbose_line(state, event, "START", detail)
        state
      else
        pending(state, "│ └─○ Tool · #{detail}")
      end

    {:reply, :ok, state}
  end

  def handle_call({:event, %{type: :tool_completed} = event}, _from, state) do
    marker = if event.outcome == :completed, do: "●", else: "×"
    detail = tool_completed_detail(state, event)
    {status, suffix} = tool_result(event.outcome)

    state =
      if state.verbose? do
        verbose_line(
          state,
          event,
          status,
          "#{detail}#{suffix} · #{duration(event)}"
        )

        state
      else
        complete_pending(
          state,
          "│ └─#{marker} Tool · #{detail}#{suffix} · #{duration(event)}"
        )
      end

    {:reply, :ok, state}
  end

  def handle_call({:event, %{type: :tool_result_waiting} = event}, _from, state) do
    if state.verbose? do
      verbose_line(state, event, "WAIT", "Tool result delay · #{format_duration(event.delay_ms)}")
    end

    {:reply, :ok, state}
  end

  def handle_call({:event, %{type: :round_finished} = event}, _from, state) do
    if state.verbose? do
      count = event.tool_calls || 0
      tools = if count == 1, do: "1 tool", else: "#{count} tools"
      verbose_line(state, event, "END", "Round · #{tools} · #{duration(event)}")
    end

    {:reply, :ok, state}
  end

  def handle_call({:event, %{type: :run_completed} = event}, _from, state) do
    state = state |> close_pending() |> ensure_gap()
    line(state, summary(event))

    label =
      case event.outcome do
        :max_turns -> "Max rounds reached"
        value when value in [:waiting, "waiting"] -> "Waiting"
        "reported" -> "Reported"
        _ -> "Completed"
      end

    line(state, divider("└── #{label} "))
    line(state, "")
    table(state, event)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:event, %{type: :run_failed} = event}, _from, state) do
    state = state |> close_pending() |> ensure_gap()
    line(state, summary(event))
    line(state, divider("└── Failed "))
    line(state, "")
    table(state, Map.put(event, :outcome, :failed))
    {:stop, :normal, :ok, state}
  end

  defp session_filter(%{session_id: nil}), do: []
  defp session_filter(%{session_id: id}), do: [session_id: id]

  defp session_event(state, %{sequence: seq}) when seq <= state.sequence, do: state

  defp session_event(state, env) do
    if state.json_events? do
      line(state, Jason.encode!(Omunculus.Event.Envelope.to_map(env)))
      %{state | sequence: env.sequence}
    else
      {ui, lines} = Omunculus.CLI.UI.event(env, state.ui)
      Enum.each(lines, &line(state, &1))
      %{state | sequence: env.sequence, ui: ui}
    end
  end

  defp pending(state, text) do
    state = close_pending(state)

    if state.terminal? do
      IO.write(state.io, text)
      Process.send_after(self(), :tick, 120)

      %{
        state
        | pending?: true,
          pending_text: text,
          pending_started_at: System.monotonic_time(:millisecond),
          spinner_index: 0,
          gap?: false
      }
    else
      state
    end
  end

  defp complete_pending(%{terminal?: true, pending?: true} = state, text) do
    IO.write(state.io, "\r\e[2K#{text}\n")
    %{state | pending?: false, pending_text: nil, pending_started_at: nil, gap?: false}
  end

  defp complete_pending(state, text) do
    line(state, text)
    %{state | gap?: false}
  end

  defp close_pending(%{terminal?: true, pending?: true} = state) do
    IO.write(state.io, "\n")
    %{state | pending?: false, pending_text: nil, pending_started_at: nil}
  end

  defp close_pending(state), do: state

  defp ensure_gap(%{gap?: true} = state), do: state

  defp ensure_gap(state) do
    line(state, "│")
    %{state | gap?: true}
  end

  defp table(state, event) do
    line(state, "┌───────┬─────────────────┬───────┬────────┬──────────┐")
    line(state, row("Round", "Outcome", "Tools", "Tokens", "Duration"))
    line(state, "├───────┼─────────────────┼───────┼────────┼──────────┤")

    Enum.each(state.rounds, fn round ->
      line(
        state,
        row(
          round.round,
          outcome(round.outcome),
          round.tool_calls || 0,
          tokens(round[:usage]),
          format_duration(round.duration_ms)
        )
      )
    end)

    line(state, "├───────┼─────────────────┼───────┼────────┼──────────┤")

    line(
      state,
      row(
        "Run",
        outcome(event.outcome),
        event.tool_calls || 0,
        tokens(event[:usage]),
        format_duration(event.duration_ms)
      )
    )

    line(state, "└───────┴─────────────────┴───────┴────────┴──────────┘")
  end

  defp row(round, outcome, tools, tokens, duration) do
    "│ #{cell(round, 5)} │ #{cell(outcome, 15)} │ #{cell(tools, 5)} │ #{cell(tokens, 6)} │ #{cell(duration, 8)} │"
  end

  defp cell(value, width) do
    value
    |> to_string()
    |> truncate(width)
    |> String.pad_trailing(width)
  end

  defp summary(event) do
    "│ Rounds: #{event.rounds} · Tools: #{event.tool_calls || 0} · Tokens: #{tokens(event[:usage])} · Duration: #{format_duration(event.duration_ms)}"
  end

  defp round_detail(%{outcome: :tool_calls, tool_calls: 1}), do: "Model response · 1 tool call"

  defp round_detail(%{outcome: :tool_calls, tool_calls: count}),
    do: "Model response · #{count} tool calls"

  defp round_detail(%{outcome: :final_response}), do: "Final response"
  defp round_detail(_), do: "Model response"

  defp outcome(:tool_calls), do: "Tool requested"
  defp outcome(:final_response), do: "Final response"
  defp outcome(:completed), do: "Completed"
  defp outcome(:max_turns), do: "Max rounds"
  defp outcome(:failed), do: "Failed"
  defp outcome(value), do: to_string(value)

  defp duration(event), do: format_duration(event.duration_ms)

  defp verbose_line(state, event, status, detail) do
    timestamp = Calendar.strftime(event[:timestamp] || DateTime.utc_now(), state.timestamp_format)
    line(state, "│ #{timestamp}  #{String.pad_trailing(status, 5)}  #{detail}")
  end

  defp tool_action("read", :running), do: "Reading"
  defp tool_action("read", :completed), do: "Read"
  defp tool_action("write", :running), do: "Writing"
  defp tool_action("write", :completed), do: "Wrote"
  defp tool_action("edit", :running), do: "Editing"
  defp tool_action("edit", :completed), do: "Edited"
  defp tool_action("grep", :running), do: "Searching"
  defp tool_action("grep", :completed), do: "Searched"
  defp tool_action("find", :running), do: "Finding"
  defp tool_action("find", :completed), do: "Found"
  defp tool_action("ls", :running), do: "Listing"
  defp tool_action("ls", :completed), do: "Listed"
  defp tool_action(name, _state), do: to_string(name)

  defp tool_started_detail(_state, %{name: "counter", from: from, to: to}),
    do: "Counter · #{from} -> #{to}"

  defp tool_started_detail(state, event) do
    target = relative_path(state.root, event[:path])
    "#{tool_action(event.name, :running)} · #{target}"
  end

  defp tool_completed_detail(_state, %{name: "counter", from: from, to: to}),
    do: "Counter · #{from} -> #{to}"

  defp tool_completed_detail(state, event) do
    target = relative_path(state.root, event[:path])
    "#{tool_action(event.name, :completed)} · #{target}"
  end

  defp tool_result(:waiting), do: {"WAIT", " · Handoff accepted"}

  defp tool_result(:completed), do: {"OK", ""}
  defp tool_result({:error, :denied}), do: {"DENY", " · Denied"}
  defp tool_result({:error, reason}), do: {"FAIL", " · #{format_reason(reason)}"}

  defp relative_path(_root, nil), do: "."

  defp relative_path(root, path) do
    path
    |> Path.expand(root)
    |> Path.relative_to(root)
    |> truncate(40)
  end

  defp format_reason(%Req.TransportError{reason: :econnrefused}), do: "Connection refused"
  defp format_reason(%Req.TransportError{reason: :timeout}), do: "Request timed out"
  defp format_reason(%Req.TransportError{reason: :nxdomain}), do: "Host not found"
  defp format_reason({:http, 401, _}), do: "Authentication failed"
  defp format_reason({:http, 403, _}), do: "Access forbidden"
  defp format_reason({:http, 429, _}), do: "Rate limited"
  defp format_reason({:http, status, _}), do: "HTTP #{status}"
  defp format_reason(:path_escape), do: "Path escapes worktree"
  defp format_reason(:denied), do: "Denied"
  defp format_reason(:enoent), do: "File not found"
  defp format_reason(reason), do: reason |> inspect() |> truncate(36)

  defp format_duration(nil), do: "not recorded"

  defp format_duration(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"

  defp format_duration(milliseconds) do
    :erlang.float_to_binary(milliseconds / 1_000, decimals: 2) <> "s"
  end

  defp tokens(nil), do: 0
  defp tokens(usage), do: usage["total_tokens"] || usage[:total_tokens] || 0

  defp truncate(value, width) when byte_size(value) <= width, do: value
  defp truncate(value, width), do: String.slice(value, 0, width - 1) <> "…"

  defp divider(prefix),
    do: prefix <> String.duplicate("─", max(@width - String.length(prefix), 1))

  defp line(state, text), do: IO.puts(state.io, text)

  defp emit_json(%{io: :stderr}, event) do
    :ok = :file.write(:standard_error, Jason.encode!(jsonable(event)) <> "\n")
  end

  defp emit_json(state, event) do
    IO.puts(state.io, Jason.encode!(jsonable(event)))
  end

  defp jsonable(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp jsonable(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp jsonable(%_{} = value) do
    jsonable(%{
      "error" => value.__struct__ |> Module.split() |> List.last(),
      "reason" => Map.get(value, :reason) || inspect(value)
    })
  end

  defp jsonable(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), jsonable(nested)} end)
  end

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  defp jsonable(value) when is_tuple(value) do
    case value do
      {:http, status, _} -> "HTTP #{status}"
      other -> other |> Tuple.to_list() |> jsonable()
    end
  end

  defp jsonable(value), do: inspect(value)

  defp terminal?(:stderr), do: match?({:ok, _}, :io.columns(:standard_error))
  defp terminal?(_), do: false
end
