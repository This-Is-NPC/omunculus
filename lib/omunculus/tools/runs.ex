defmodule Omunculus.Tools.Runs do
  @moduledoc """
  Builtin `runs` tool: the project's last closed runs, as the `recent` view
  reads them, newest first. Each is summed up in a few lines — its agent,
  its work and the workflow stage, how long it took, what made it due when
  it was a retry, how it ended (the tool that chained `end`) or that it
  stopped without `end`, its calls by name, each failed or refused call
  with the start of its output, and the model's replies with the tokens
  and cost their providers reported. `agent` keeps that agent's runs,
  `limit` fewer of them; `run` gives one run whole, call by call, each
  model reply's text and each call's arguments and output, cut short.
  """

  alias Omunculus.Tools.Out

  @output_chars 240
  @text_chars 400

  @spec run(map) :: map
  def run(%{args: args, view: view}) do
    runs = view["recent"] || []

    case args["run"] do
      id when is_binary(id) and id != "" ->
        case Enum.find(runs, &(&1.id == id or String.starts_with?(&1.id, id))) do
          nil -> Out.fail("no run #{id} among the last #{length(runs)} closed runs")
          found -> Out.ok(Enum.join([header(found) | details(found.events)], "\n"))
        end

      _ ->
        runs
        |> Enum.filter(&(args["agent"] in [nil, ""] or &1.agent == args["agent"]))
        |> Enum.take(limit(args["limit"], length(runs)))
        |> render()
    end
  end

  defp limit(limit, _count) when is_integer(limit) and limit > 0, do: limit

  defp limit(limit, count) when is_binary(limit) do
    case Integer.parse(limit) do
      {number, ""} when number > 0 -> number
      _ -> count
    end
  end

  defp limit(_limit, count), do: count

  defp render([]), do: Out.ok("No closed run.")

  defp render(runs) do
    Out.ok(
      "#{length(runs)} runs, newest first.\n\n" <>
        Enum.map_join(runs, "\n\n", &summary/1)
    )
  end

  defp summary(run) do
    tools = calls(run.events)
    failed = Enum.filter(tools, &(&1["ok"] == false))

    [
      header(run),
      "  ended: " <> ended(run.events),
      "  calls: #{length(tools)}" <> counts(tools),
      Enum.map(
        failed,
        &("  failed: " <> &1["name"] <> " — " <> cut(&1["output"], @output_chars))
      ),
      "  model: " <> usage(run.events)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp header(run) do
    work =
      if run[:work_title],
        do:
          ~s(work "#{run.work_title}" [#{run.work_state}]) <>
            if(run.work_workflow,
              do: " · #{run.work_workflow}, stage #{run.work_stage}",
              else: ""
            ),
        else: "no work"

    Enum.join(
      [
        "run #{run.id} · #{run.agent} · depth #{run.depth}",
        "#{run.started_at} · #{seconds(run.started_at, run.finished_at)}",
        work,
        run.via && "via #{run.via}"
      ]
      |> Enum.reject(&is_nil/1),
      " · "
    )
  end

  defp seconds(from, to) do
    with {:ok, start, _} <- DateTime.from_iso8601(from || ""),
         {:ok, finish, _} <- DateTime.from_iso8601(to || "") do
      "#{DateTime.diff(finish, start)} s"
    else
      _ -> "unfinished"
    end
  end

  # The model's calls: after its first reply, before the run ended; the
  # assembly before and the hooks of end after are the harness's. The end
  # step itself is left out.
  defp calls(events) do
    events
    |> Enum.drop_while(&(&1.type != "model"))
    |> Enum.take_while(&(&1.type != "end"))
    |> Enum.filter(&(&1.type == "tool"))
    |> Enum.map(&Jason.decode!(&1.body))
    |> Enum.reject(&(&1["name"] == "end"))
  end

  # The tool whose chain reached end, or that the model stopped without it.
  defp ended(events) do
    ending =
      events
      |> Enum.filter(&(&1.type == "tool"))
      |> Enum.map(&Jason.decode!(&1.body))
      |> Enum.find(&(&1["name"] == "end"))

    case ending do
      %{"via" => via} when is_binary(via) -> via
      %{} -> "end"
      nil -> "stopped without end"
    end
  end

  defp counts([]), do: ""

  defp counts(tools) do
    " — " <>
      (tools
       |> Enum.frequencies_by(& &1["name"])
       |> Enum.sort_by(fn {name, count} -> {-count, name} end)
       |> Enum.map_join(", ", fn
         {name, 1} -> name
         {name, count} -> "#{name}×#{count}"
       end))
  end

  defp usage(events) do
    replies = for event <- events, event.type == "model", do: reply(event.body)

    totals =
      Enum.reduce(replies, %{input: 0, cached: 0, output: 0, cost: 0.0}, fn reply, acc ->
        usage = reply["usage"] || %{}

        %{
          input:
            acc.input + number(usage["input_tokens"] || usage["prompt_tokens"]) +
              number(usage["cache_creation_input_tokens"]) +
              number(usage["cache_read_input_tokens"]),
          cached:
            acc.cached + number(usage["cache_read_input_tokens"]) +
              number(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
          output: acc.output + number(usage["output_tokens"] || usage["completion_tokens"]),
          cost: acc.cost + number(usage["cost"])
        }
      end)

    "#{length(replies)} replies · #{totals.input} tokens in (#{totals.cached} cached) · " <>
      "#{totals.output} out" <>
      if(totals.cost > 0,
        do: " · $" <> :erlang.float_to_binary(totals.cost * 1.0, decimals: 4),
        else: ""
      )
  end

  defp number(value) when is_number(value), do: value
  defp number(_value), do: 0

  defp details(events) do
    events
    |> Enum.filter(&(&1.type in ["model", "tool"]))
    |> Enum.with_index(1)
    |> Enum.map(fn {event, at} -> "#{at}. " <> detail(event.type, decoded(event)) end)
  end

  defp decoded(%{type: "model", body: body}), do: reply(body)
  defp decoded(%{body: body}), do: Jason.decode!(body)

  # A model event's body is the reply as JSON, or plain text, as the
  # harness records a run the server's restart interrupted.
  defp reply(body) do
    case Jason.decode(body) do
      {:ok, reply} when is_map(reply) -> reply
      _text -> %{"content" => body}
    end
  end

  defp detail("model", reply) do
    case text(reply) do
      "" -> "model: (calls only)"
      said -> "model: " <> cut(said, @text_chars)
    end
  end

  defp detail("tool", call) do
    "#{call["name"]} #{cut(Jason.encode!(call["args"] || %{}), @output_chars)} → " <>
      if(call["ok"] == false, do: "failed: ", else: "ok: ") <> cut(call["output"], @output_chars)
  end

  # The text a reply carries: a plain string, an OpenAI message or Anthropic content.
  defp text(%{"content" => content}) when is_binary(content), do: content

  defp text(%{"content" => content}) when is_list(content),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  defp text(%{"choices" => [%{"message" => message} | _]}), do: text(message)
  defp text(_reply), do: ""

  defp cut(nil, _chars), do: ""

  defp cut(text, chars) when is_binary(text) do
    flat = String.replace(text, ~r/\s+/, " ")
    if String.length(flat) > chars, do: String.slice(flat, 0, chars) <> "…", else: flat
  end

  defp cut(other, chars), do: cut(inspect(other), chars)
end
