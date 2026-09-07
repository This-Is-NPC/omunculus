defmodule Omunculus.Agent do
  @moduledoc false

  alias Omunculus.{Chat, Tools}

  def run(opts) when is_list(opts) do
    instruction = Keyword.fetch!(opts, :instruction)
    chat = Keyword.fetch!(opts, :chat)
    fs = Keyword.fetch!(opts, :fs)
    context = Omunculus.Tool.Context.new(fs, Keyword.get(opts, :tool_options, %{}))
    context = %{context | state: Keyword.get(opts, :tool_state, %{})}
    tool_executor = Keyword.get(opts, :tool_executor, &Tools.call_context/4)
    tools = Keyword.get(opts, :tools, Tools.default_names())
    request_permission = request_permission?(opts)
    max_turns = Keyword.get(opts, :max_turns, 32)
    extra = Keyword.get(opts, :instructions)
    reporter = Keyword.get(opts, :reporter, fn _event -> :ok end)
    nudge = Keyword.get(opts, :nudge)
    started_at = now()

    messages =
      case Keyword.get(opts, :messages) do
        msgs when is_list(msgs) and msgs != [] ->
          msgs

        _ ->
          [
            %{
              "role" => "system",
              "content" => Keyword.get(opts, :system_prompt) || system_prompt(extra, fs)
            },
            %{"role" => "user", "content" => instruction}
          ]
      end

    loop(%{
      chat: chat,
      context: context,
      tools: tools,
      tool_executor: tool_executor,
      schemas: schemas_for(tools, request_permission),
      messages: messages,
      turn: 0,
      max_turns: max_turns,
      usage: nil,
      assistant_text: nil,
      reporter: reporter,
      started_at: started_at,
      tool_calls: 0,
      nudge: nudge,
      counter_target: counter_target(tools, instruction)
    })
  end

  defp loop(%{turn: turn, max_turns: max} = state) when turn >= max do
    emit(state, %{
      type: :run_completed,
      outcome: :max_turns,
      rounds: turn,
      tool_calls: state.tool_calls,
      usage: state.usage,
      duration_ms: elapsed(state.started_at)
    })

    {:ok, result(state)}
  end

  defp loop(state) do
    round = state.turn + 1
    started_at = now()
    emit(state, %{type: :round_started, round: round, max_rounds: state.max_turns})

    case Chat.complete(state.chat, state.messages, state.schemas) do
      {:ok, %{tool_calls: calls} = reply} when is_list(calls) and calls != [] ->
        emit(state, %{
          type: :round_completed,
          round: round,
          outcome: :tool_calls,
          tool_calls: length(calls),
          usage: reply.usage,
          duration_ms: elapsed(started_at)
        })

        case dispatch(state, calls, reply, round) do
          {:waiting, messages, context} ->
            turn = state.turn + 1
            usage = merge_usage(state.usage, reply.usage)

            emit(state, %{
              type: :round_finished,
              round: round,
              outcome: :waiting,
              tool_calls: length(calls),
              duration_ms: elapsed(started_at)
            })

            emit(state, %{
              type: :run_completed,
              outcome: :waiting,
              rounds: turn,
              tool_calls: state.tool_calls + length(calls),
              usage: usage,
              duration_ms: elapsed(state.started_at)
            })

            {:waiting,
             result(%{
               state
               | messages: messages,
                 context: context,
                 turn: turn,
                 usage: usage,
                 assistant_text: text(reply.content),
                 tool_calls: state.tool_calls + length(calls)
             })}

          {messages, context} ->
            emit(state, %{
              type: :round_finished,
              round: round,
              outcome: :completed,
              tool_calls: length(calls),
              duration_ms: elapsed(started_at)
            })

            loop(%{
              state
              | messages: messages,
                context: context,
                turn: state.turn + 1,
                usage: merge_usage(state.usage, reply.usage),
                assistant_text: text(reply.content),
                tool_calls: state.tool_calls + length(calls)
            })
        end

      {:ok, reply} ->
        messages = state.messages ++ [assistant_message(reply)]
        usage = merge_usage(state.usage, reply.usage)
        turn = state.turn + 1

        emit(state, %{
          type: :round_completed,
          round: round,
          outcome: :final_response,
          tool_calls: 0,
          usage: reply.usage,
          duration_ms: elapsed(started_at)
        })

        emit(state, %{
          type: :round_finished,
          round: round,
          outcome: :completed,
          tool_calls: 0,
          duration_ms: elapsed(started_at)
        })

        next = %{
          state
          | messages: messages,
            turn: turn,
            usage: usage,
            assistant_text: text(reply.content)
        }

        nudge =
          cond do
            continue_counter?(next) -> counter_nudge(next)
            true -> custom_nudge(next)
          end

        if nudge do
          loop(%{
            next
            | messages: messages ++ [%{"role" => "user", "content" => nudge}]
          })
        else
          emit(state, %{
            type: :run_completed,
            outcome: :completed,
            rounds: turn,
            tool_calls: state.tool_calls,
            usage: usage,
            duration_ms: elapsed(state.started_at)
          })

          {:ok, result(next)}
        end

      {:error, reason} ->
        emit(state, %{
          type: :round_failed,
          round: round,
          reason: reason,
          duration_ms: elapsed(started_at)
        })

        emit(state, %{
          type: :run_failed,
          rounds: state.turn,
          tool_calls: state.tool_calls,
          usage: state.usage,
          reason: reason,
          duration_ms: elapsed(state.started_at)
        })

        {:error, {:chat, reason}}
    end
  end

  defp dispatch(state, calls, reply, round) do
    assistant = assistant_message(reply)

    {tool_messages, context, waiting?} =
      Enum.reduce(calls, {[], state.context, false}, fn call, {acc, context, waiting?} ->
        {name, args, id} = decode_call(call)
        started_at = now()
        metadata = tool_metadata(name, context)

        emit(
          state,
          Map.merge(metadata, %{
            type: :tool_started,
            round: round,
            name: name,
            path: tool_path(name, args),
            detail: tool_detail(name, args)
          })
        )

        {body, context, outcome} =
          case state.tool_executor.(name, args, context, state.tools) do
            {:ok, output, context} -> {output, context, :completed}
            {:error, reason, context} -> {format_tool_error(reason), context, {:error, reason}}
            {:wait, reason, context} -> {reason, context, :waiting}
          end

        delay_ms = state.context.options[:delay_ms] || 0

        if delay_ms > 0 and outcome != :waiting do
          emit(state, %{
            type: :tool_result_waiting,
            round: round,
            name: name,
            delay_ms: delay_ms
          })

          Process.sleep(delay_ms)
        end

        emit(
          state,
          Map.merge(metadata, %{
            type: :tool_completed,
            round: round,
            name: name,
            path: tool_path(name, args),
            detail: tool_detail(name, args),
            outcome: outcome,
            duration_ms: elapsed(started_at)
          })
        )

        acc =
          if outcome == :waiting do
            acc
          else
            acc ++
              [
                %{
                  "role" => "tool",
                  "tool_call_id" => id,
                  "content" => body
                }
              ]
          end

        {acc, context, waiting? or outcome == :waiting}
      end)

    messages = state.messages ++ [assistant] ++ tool_messages

    if waiting? do
      {:waiting, messages, context}
    else
      {messages, context}
    end
  end

  defp decode_call(call) do
    fn_block = call["function"] || call[:function] || %{}
    name = fn_block["name"] || fn_block[:name] || call["name"]
    raw = fn_block["arguments"] || fn_block[:arguments] || "{}"
    id = call["id"] || call[:id] || "tool"

    args =
      cond do
        is_map(raw) -> raw
        is_binary(raw) -> decode_json(raw)
        true -> %{}
      end

    {name, args, id}
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp assistant_message(reply) do
    msg = %{"role" => "assistant", "content" => reply.content || ""}

    case reply.tool_calls do
      calls when is_list(calls) and calls != [] -> Map.put(msg, "tool_calls", calls)
      _ -> msg
    end
  end

  defp text(nil), do: ""
  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => t} -> t
      %{text: t} -> t
      bin when is_binary(bin) -> bin
      _ -> ""
    end)
    |> IO.iodata_to_binary()
  end

  defp text(_), do: ""

  defp merge_usage(nil, incoming), do: incoming
  defp merge_usage(acc, nil), do: acc

  defp merge_usage(acc, incoming) when is_map(acc) and is_map(incoming) do
    %{
      "prompt_tokens" => n(acc, "prompt_tokens") + n(incoming, "prompt_tokens"),
      "completion_tokens" => n(acc, "completion_tokens") + n(incoming, "completion_tokens"),
      "total_tokens" => n(acc, "total_tokens") + n(incoming, "total_tokens")
    }
  end

  defp n(map, key), do: map[key] || map[String.to_atom(key)] || 0

  defp format_tool_error(:denied), do: "error: tool not allowed in this session"
  defp format_tool_error(:path_escape), do: "error: path escapes the worktree"
  defp format_tool_error(:old_text_not_found), do: "error: oldText not found in file"
  defp format_tool_error(:old_text_not_unique), do: "error: oldText is not unique in file"
  defp format_tool_error(:overlapping_edits), do: "error: overlapping edits"
  defp format_tool_error(:unsupported), do: "error: unsupported file type"
  defp format_tool_error(:enoent), do: "error: file not found"
  defp format_tool_error(reason), do: "error: #{inspect(reason)}"

  defp tool_detail(name, args) do
    value = args["path"] || args[:path] || args["pattern"] || args[:pattern]

    case value do
      value when is_binary(value) and value != "" -> "#{name} #{value}"
      _ -> to_string(name)
    end
  end

  defp tool_path(name, args) when name in ["grep", "find", "ls"],
    do: args["path"] || args[:path] || "."

  defp tool_path(_name, args), do: args["path"] || args[:path]

  defp tool_metadata("counter", context) do
    options = Omunculus.Tool.Context.tool_options(context, "counter")
    state = Omunculus.Tool.Context.tool_state(context, "counter", %{value: 0})
    increment = options[:increment] || options["increment"] || 1
    %{from: state.value, to: state.value + increment}
  end

  defp tool_metadata(_name, _context), do: %{}

  defp emit(state, event),
    do: state.reporter.(Map.put_new(event, :timestamp, DateTime.utc_now()))

  defp now, do: System.monotonic_time(:millisecond)
  defp elapsed(started_at), do: max(now() - started_at, 0)

  defp counter_target(["counter"], instruction) when is_binary(instruction) do
    case Regex.scan(~r/\d+/, instruction) do
      [] ->
        nil

      matches ->
        {n, _} = matches |> List.last() |> hd() |> Integer.parse()
        if n > 0, do: n, else: nil
    end
  end

  defp counter_target(_tools, _instruction), do: nil

  defp continue_counter?(%{counter_target: target} = state) when is_integer(target) do
    state.turn < state.max_turns and counter_value(state) < target
  end

  defp continue_counter?(_state), do: false

  defp counter_value(state) do
    case Omunculus.Tool.Context.tool_state(state.context, "counter", %{value: 0}) do
      %{value: n} when is_integer(n) -> n
      _ -> 0
    end
  end

  # Optional caller-provided continuation: receives a summary of the run so
  # far and returns a user message to push the model on, or nil to halt.
  defp custom_nudge(%{nudge: fun} = state) when is_function(fun, 1) do
    if state.turn < state.max_turns do
      fun.(%{
        turn: state.turn,
        tool_calls: state.tool_calls,
        tool_state: state.context.state,
        assistant_text: state.assistant_text
      })
    end
  end

  defp custom_nudge(_state), do: nil

  defp counter_nudge(state) do
    "Counter is #{counter_value(state)}. Target is #{state.counter_target}. Call the counter tool now. Do not write a reply."
  end

  defp result(state) do
    %{
      assistant_text: state.assistant_text || "",
      usage: state.usage,
      turns: state.turn,
      tool_calls: state.tool_calls,
      fs: state.context.fs,
      tool_state: state.context.state,
      messages: state.messages,
      schemas: state.schemas
    }
  end

  defp request_permission?(opts) do
    Keyword.get(opts, :request_permission, false) == true
  end

  defp schemas_for(tools, true) do
    Tools.schemas(tools) ++ [request_permission_schema()]
  end

  defp schemas_for(tools, _), do: Tools.schemas(tools)

  defp request_permission_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "request_permission",
        "description" => "Request permission for an additional tool.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Tool name to request."},
            "reason" => %{"type" => "string", "description" => "Why the tool is needed."}
          },
          "required" => ["name", "reason"]
        }
      }
    }
  end

  defp system_prompt(extra, fs) do
    cwd = Omunculus.FS.cwd(fs)

    base = """
    You are omunculus, a coding agent. Work only inside #{cwd}.
    Use the provided tools to inspect and edit files. There is no shell.
    Prefer edit over write for existing files. Stop when the task is done.
    Return a short summary of what changed.
    """

    case extra do
      text when is_binary(text) and text != "" -> base <> "\n" <> text
      _ -> base
    end
  end
end
