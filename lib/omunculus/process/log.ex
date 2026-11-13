defmodule Omunculus.Process.Log do
  @moduledoc """
  The project's event log as process mining reads it, built from the rows
  `Omunculus.Store.Log` reads: objects (conversations, works, runs,
  requests, artifacts, jobs) and events, each event with the objects it
  touches.

  An event is `%{id, activity, at, objects, attrs, kind, case, run}`:
  `kind` is `:call` (a tool call, `activity` its name; `ok` false is a
  refusal), `:reply` (a model reply), `:stage` (a work entering a stage,
  `activity` `"enter <stage>"`), `:end` (a work done or cancelled), `:request`
  (a request raised, escalated or answered), `:artifact` or `:fire`;
  `case` is the work id, nil when the event is no work's. The `end` call of
  a run and the calls of the harness before the model's first reply are
  not the model's and are left out. A work's first stage is the `from` of
  its first `continue`, else the stage its first `reopen` names, else the
  stage it holds. A call's `duration` is the seconds since the previous
  event of its run, or the run's start.
  """

  alias Omunculus.Usage

  @type event :: %{
          id: String.t(),
          activity: String.t(),
          at: String.t(),
          kind: atom,
          case: String.t() | nil,
          run: String.t() | nil,
          objects: [{String.t(), String.t(), String.t()}],
          attrs: %{String.t() => term}
        }

  @spec build(map) :: %{events: [event], objects: [map], works: [map]}
  def build(raw) do
    runs = Map.new(raw.runs, &{&1.id, &1})
    works = Map.new(raw.works, &{&1.id, &1})
    by_run = Enum.group_by(raw.events, & &1.run_id)

    # Per run, the previous event's time; a call or reply lasts from it.
    previous =
      Enum.reduce(by_run, %{}, fn {run_id, events}, acc ->
        start = run_id && get_in(runs, [run_id, :started_at])

        events
        |> Enum.map_reduce(start, fn event, last -> {{event.id, last}, event.at} end)
        |> elem(0)
        |> Enum.reduce(acc, fn {id, last}, acc -> Map.put(acc, id, last) end)
      end)

    calls = calls(raw.events)

    events =
      raw.events
      |> Enum.flat_map(&translate(&1, %{runs: runs, previous: previous, calls: calls}))
      |> Enum.concat(stages(raw.events, works))
      |> Enum.concat(Enum.map(raw.fires, &fire/1))
      |> Enum.sort_by(& &1.seq)

    %{events: events, objects: objects(raw, events), works: works(raw.works, events)}
  end

  # The ids of the model's calls: those of a run after its first reply and
  # before its `end`.
  defp calls(events) do
    events
    |> Enum.filter(& &1.run_id)
    |> Enum.group_by(& &1.run_id)
    |> Enum.flat_map(fn {_run, list} ->
      list
      |> Enum.drop_while(&(&1.type != "model"))
      |> Enum.take_while(&(not (&1.type == "tool" and &1.name == "end")))
      |> Enum.filter(&(&1.type == "tool"))
      |> Enum.map(& &1.id)
    end)
    |> MapSet.new()
  end

  defp translate(%{type: "tool"} = event, ctx) do
    if MapSet.member?(ctx.calls, event.id) do
      [
        event(event, :call, event.name, ctx, %{
          "ok" => event.ok != 0,
          "duration" => duration(event, ctx)
        })
      ]
    else
      []
    end
  end

  defp translate(%{type: "model"} = event, ctx) do
    reply = Usage.reply(event.body)
    totals = Usage.sum([reply])

    attrs =
      %{
        "usd" => totals.cost * 1.0,
        "tokens" => round(totals.input + totals.output),
        "duration" => duration(event, ctx)
      }
      |> put_present("model", reply["model"])

    [event(event, :reply, "model reply", ctx, attrs)]
  end

  defp translate(%{type: "continue", to_stage: nil} = event, ctx),
    do: [event(event, :end, "work done", ctx, %{})]

  defp translate(%{type: "cancel"} = event, ctx),
    do: [event(event, :end, "work cancelled", ctx, %{})]

  defp translate(%{type: type} = event, ctx) when type in ~w(request escalate reply) do
    activity = %{
      "request" => "request raised",
      "escalate" => "request escalated",
      "reply" => "request answered"
    }

    [event(event, :request, activity[type], ctx, %{})]
  end

  defp translate(%{type: "artifact"} = event, ctx),
    do: [event(event, :artifact, "artifact written", ctx, put_present(%{}, "kind", event.kind))]

  defp translate(_event, _ctx), do: []

  defp event(row, kind, activity, ctx, attrs) do
    run = row.run_id && ctx.runs[row.run_id]
    attrs = if run, do: Map.put(attrs, "agent", run.agent), else: attrs

    %{
      id: row.id,
      seq: row.sequence,
      activity: activity,
      at: row.at,
      kind: kind,
      case: row.work_id,
      run: row.run_id,
      objects: touched(row),
      attrs: attrs
    }
  end

  defp touched(row) do
    [
      {"conversation", row.conversation_id, "in conversation"},
      {"work", row.work_id, "on work"},
      {"run", row.run_id, "by run"},
      {"request", row.request_id, "about request"}
    ]
    |> Enum.filter(fn {_type, id, _qualifier} -> is_binary(id) end)
    |> Enum.concat(artifact(row))
  end

  defp artifact(%{type: "artifact", name: name, conversation_id: conversation})
       when is_binary(name),
       do: [{"artifact", artifact_id(conversation, name), "writes artifact"}]

  defp artifact(_row), do: []

  defp artifact_id(conversation, name), do: "#{conversation}/#{name}"

  defp duration(event, ctx) do
    with last when is_binary(last) <- ctx.previous[event.id],
         {:ok, to, _} <- DateTime.from_iso8601(event.at),
         {:ok, from, _} <- DateTime.from_iso8601(last) do
      DateTime.diff(to, from, :microsecond) / 1.0e6
    else
      _ -> 0.0
    end
  end

  # Entering a stage: a work's first, at its creation, then each move.
  defp stages(events, works) do
    events
    |> Enum.filter(& &1.work_id)
    |> Enum.group_by(& &1.work_id)
    |> Enum.flat_map(fn {id, list} ->
      case works[id] do
        %{workflow: workflow} = work when is_binary(workflow) -> entries(work, list)
        _none -> []
      end
    end)
  end

  defp entries(work, events) do
    created = Enum.find(events, &(&1.type in ~w(work delegate)))
    moves = Enum.filter(events, &(&1.type in ~w(continue reopen)))

    first =
      case moves do
        [%{type: "continue", from_stage: from} | _] -> from
        [%{type: "reopen", stage: stage} | _] -> stage
        [] -> work.stage
      end

    entering = for event <- moves, stage = next_stage(event), do: {event, stage}
    start = if created && first, do: [{created, first}], else: []

    Enum.map(start ++ entering, fn {row, stage} ->
      event(row, :stage, "enter " <> stage, %{runs: %{}}, %{"stage" => stage})
    end)
  end

  defp next_stage(%{type: "continue", to_stage: to}), do: to
  defp next_stage(%{type: "reopen", stage: stage}), do: stage

  defp fire(row) do
    runs = decode(row.run_ids)

    %{
      id: row.id,
      seq: row.sequence,
      activity: "job fire " <> to_string(row.state),
      at: row.at,
      kind: :fire,
      case: nil,
      run: nil,
      objects:
        [
          {"job", row.job_id, "fires job"},
          {"conversation", row.conversation_id, "in conversation"}
        ] ++
          Enum.map(runs, &{"run", &1, "by run"}),
      attrs: put_present(%{}, "usd", row.usd && row.usd * 1.0)
    }
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp decode(_none), do: []

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp objects(raw, events) do
    conversations =
      for c <- raw.conversations, do: object("conversation", c.id, c.created_at, %{}, [])

    works =
      for w <- raw.works do
        rels =
          [{w.conversation_id, "in conversation"}] ++
            if(w.parent_id, do: [{w.parent_id, "child of"}], else: [])

        attrs =
          %{"title" => w.title, "state" => w.state}
          |> put_present("workflow", w.workflow)
          |> put_present("stage", w.stage)
          |> put_present("assignee", w.assignee)

        object("work", w.id, w.created_at, attrs, rels)
      end

    runs_list =
      for r <- raw.runs do
        rels =
          [{r.conversation_id, "in conversation"}] ++
            if(r.work_id, do: [{r.work_id, "runs work"}], else: [])

        attrs =
          %{"agent" => r.agent, "depth" => r.depth} |> put_present("via", r.via)

        object("run", r.id, r.started_at, attrs, rels)
      end

    requests =
      for r <- raw.requests do
        rels =
          [{r.conversation_id, "in conversation"}] ++
            if(r.work_id, do: [{r.work_id, "of work"}], else: []) ++
            if(r.run_id, do: [{r.run_id, "raised by run"}], else: [])

        object("request", r.id, r.created_at, %{"status" => r.status}, rels)
      end

    conversations ++ works ++ runs_list ++ requests ++ derived(events)
  end

  # Artifacts and jobs exist for the events that name them.
  defp derived(events) do
    events
    |> Enum.flat_map(fn event ->
      for {type, id, _} <- event.objects, type in ~w(artifact job), do: {type, id, event}
    end)
    |> Enum.uniq_by(fn {type, id, _event} -> {type, id} end)
    |> Enum.map(fn
      {"artifact", id, event} ->
        [conversation] = for {"conversation", c, _} <- event.objects, do: c

        object("artifact", id, event.at, put_present(%{}, "kind", event.attrs["kind"]), [
          {conversation, "in conversation"}
        ])

      {"job", id, event} ->
        object("job", id, event.at, %{}, [])
    end)
  end

  defp object(type, id, time, attrs, rels),
    do: %{type: type, id: id, time: time, attrs: attrs, rels: rels}

  @doc "The stage sequences of the works that went through `workflow`."
  @spec traces(%{works: [map]}, String.t()) :: [[String.t()]]
  def traces(%{works: works}, workflow),
    do: for(%{workflow: ^workflow, stages: [_ | _] = stages} <- works, do: stages)

  # The works as cases: the work, its stages in the order it entered them
  # and its events in order.
  defp works(works, events) do
    by_case = Enum.group_by(events, & &1.case)

    for work <- works do
      list = Map.get(by_case, work.id, [])

      work
      |> Map.put(:events, list)
      |> Map.put(:stages, for(%{kind: :stage, attrs: %{"stage" => stage}} <- list, do: stage))
    end
  end
end
