defmodule Omunculus.Tools.Session do
  @moduledoc """
  The conversation an agent's run continues. A session is one agent's turn
  on a work, or, without a work, in a conversation: its runs pause (an
  answer, a request, children working, a wait for the person, a retry) until one hands the work
  on with `continue` or `break`, or opens a root of its own. `history/2`
  rebuilds the session the last of the work's or the conversation's closed
  runs belongs to, from what the store
  recorded, when the call's run may continue it: that run is the agent's,
  paused, closed within `ttl_ms`, and every model call of the session has
  its recorded result. It starts at the session's first run — the context
  of its assembled prompt, which `split` parts from its instructions — and
  goes on with each recorded reply (its `usage` left out), the results of
  its calls in order, cut as the model got them, and, before each run
  that continued the one before, what that run was told had happened
  (its `session` event). The history ends with `since`. Over `max_bytes`,
  or anything it cannot rebuild exactly, there is no history: the run
  starts over.

  A history is a list of `%{"user" => text}` and `%{"model" => reply,
  "outputs" => [output]}`, the outputs in the order of the reply's calls.
  """

  alias Omunculus.Tools.{Out, Record}

  @type item :: %{String.t() => term}

  @doc """
  The session the closed `runs` (oldest first, with their record)
  end in, as `%{"continues" => run_id, "instructions" => text, "history" =>
  [item]}`, or nil: the session goes on under the instructions it started
  with, so its requests keep the same start.
  """
  @spec history([map], map) :: %{String.t() => term} | nil
  def history([], _given), do: nil

  def history(runs, given) do
    last = List.last(runs)
    by_id = Map.new(runs, &{&1.id, &1})

    with true <- last.agent == given.agent,
         true <- paused?(last),
         true <- recent?(last, given.now, given.ttl_ms),
         {:ok, [first | _] = chain} <- chain(last, by_id, []),
         {:ok, instructions, context} <- given.split.(first.assembled),
         {:ok, items} <- items(chain, context, given),
         items = items ++ [%{"user" => given.since}],
         true <- byte_size(Jason.encode!(items)) <= given.max_bytes do
      %{"continues" => last.id, "instructions" => instructions, "history" => items}
    else
      _starts_over -> nil
    end
  end

  # A run handed the work on with `continue` or `break`, or by opening a
  # root of its own, which its own run starts anew.
  defp paused?(run), do: not Enum.any?(run.events, &handed_on?/1)

  defp handed_on?(%{type: type}) when type in ["continue", "break"], do: true
  defp handed_on?(%{type: "work", body: body}), do: Jason.decode!(body)["start"] == true
  defp handed_on?(_event), do: false

  defp recent?(%{finished_at: finished}, now, ttl_ms) when is_binary(finished) do
    {:ok, at, _offset} = DateTime.from_iso8601(finished)
    DateTime.diff(now, at, :millisecond) <= ttl_ms
  end

  defp recent?(_run, _now, _ttl_ms), do: false

  # The session's runs, first to last: each `session` event names the run
  # its run continued.
  defp chain(run, by_id, acc) do
    case continued(run) do
      nil ->
        {:ok, [run | acc]}

      %{"continues" => id} ->
        case Map.fetch(by_id, id) do
          {:ok, previous} -> chain(previous, by_id, [run | acc])
          :error -> :error
        end
    end
  end

  defp continued(run) do
    Enum.find_value(run.events, fn
      %{type: "session", body: body} -> Jason.decode!(body)
      _other -> nil
    end)
  end

  defp items(chain, context, given) do
    Enum.reduce_while(chain, {:ok, [%{"user" => context}]}, fn run, {:ok, acc} ->
      told = if session = continued(run), do: [%{"user" => session["since"]}], else: []

      case turns(run.events, given.tool_output_bytes) do
        {:ok, turns} -> {:cont, {:ok, acc ++ told ++ turns}}
        :error -> {:halt, :error}
      end
    end)
  end

  # Each reply with the results of its calls: the recorded calls of the run
  # that no other call chained, in order, matched by name.
  defp turns(events, bytes) do
    events
    |> Enum.reduce_while({:ok, [], []}, fn event, {:ok, turns, pending} ->
      case {event.type, Jason.decode(event.body)} do
        {"model", {:ok, reply}} when is_map(reply) ->
          with [] <- pending,
               {:ok, calls} <- calls(reply) do
            turn = %{"model" => Map.delete(reply, "usage"), "outputs" => []}
            {:cont, {:ok, turns ++ [turn], calls}}
          else
            _unmatched_or_unknown -> {:halt, :error}
          end

        {"model", _not_a_reply} ->
          {:halt, :error}

        {"tool", {:ok, %{"name" => name} = call}} when not is_map_key(call, "via") ->
          case pending do
            [^name | rest] ->
              output = Out.cut(call["output"] || "", bytes)
              {:cont, {:ok, add_output(turns, output), rest}}

            _not_the_next_call ->
              {:cont, {:ok, turns, pending}}
          end

        _other ->
          {:cont, {:ok, turns, pending}}
      end
    end)
    |> case do
      {:ok, turns, []} -> {:ok, turns}
      _unmatched -> :error
    end
  end

  defp add_output(turns, output) do
    {last, earlier} = List.pop_at(turns, -1)
    earlier ++ [Map.update!(last, "outputs", &(&1 ++ [output]))]
  end

  # A call through the sandbox bridge leaves no result of its own to send back.
  defp calls(reply) do
    names = Record.calls(reply)
    if "__omunculus_execute" in names, do: :error, else: {:ok, names}
  end
end
