defmodule Omunculus.Interception.Agents do
  @moduledoc "Adapter from actor requests to ordinary configured agent Work Items and Runs."
  alias Omunculus.{EventCore, Interception}
  alias Omunculus.Event.Envelope

  def advance(state) do
    opts = if state[:session_id], do: [session_id: state.session_id], else: []
    requests = EventCore.stream(state.core, 0, Keyword.put(opts, :type, "interception.requested"))
    events = if requests == [], do: [], else: EventCore.stream(state.core, 0, opts)

    for request <- requests, is_binary(request.payload["rule"]["agent"]) do
      response =
        Enum.find(
          events,
          &(&1.type in ["interception.responded", "interception.expired"] and
              &1.payload["request_id"] == request.event_id)
        )

      wi = request.payload["actor_work_item_id"]

      terminal =
        Enum.find(
          events,
          &(&1.work_item_id == wi and &1.type in ["task.completed", "task.break"])
        )

      activation = Enum.find(events, &(&1.type == "task.requested" and &1.work_item_id == wi))

      cond do
        response ->
          close_break(state.core, terminal, response)

        terminal ->
          case reply(state.core, request, terminal) do
            {:ok, response} -> close_break(state.core, terminal, response)
            {:error, _} -> :ok
          end

        is_nil(activation) ->
          start(state.core, request)

        not Enum.any?(events, &(&1.type == "run.started" and &1.work_item_id == wi)) ->
          EventCore.redeliver(state.core, activation.event_id)

        true ->
          :ok
      end
    end

    state
  end

  defp close_break(core, %{type: "task.break"} = terminal, response) do
    EventCore.append!(
      core,
      Envelope.event("task.assessment_resolved",
        idempotency_key: "actor-break:" <> terminal.event_id,
        correlation_id: terminal.correlation_id,
        causation_id: response.event_id,
        session_id: terminal.session_id,
        work_item_id: terminal.work_item_id,
        payload: %{request_id: terminal.event_id, comment: terminal.payload["comment"]}
      )
    )
  end

  defp close_break(_core, _terminal, _response), do: :ok

  defp start(core, request) do
    {:ok, source} = EventCore.fetch(core, request.payload["source_event_id"])
    rule = request.payload["rule"]
    # The actor decides what to do with the event; its instruction and role come from config.
    EventCore.append!(
      core,
      Envelope.command("task.requested",
        idempotency_key: "actor-task:" <> request.event_id,
        correlation_id: Interception.stable_id("corr", request.event_id),
        causation_id: request.event_id,
        session_id: source.session_id,
        workspace_id: source.workspace_id,
        work_item_id: request.payload["actor_work_item_id"],
        payload: %{
          instruction: rule["work_item"]["instruction"],
          agent: rule["agent"],
          interception_request_id: request.event_id,
          comment: Jason.encode!(Envelope.to_map(source)),
          execution: execution(core, source.work_item_id) |> Map.put("profile", "coding")
        }
      )
    )
  end

  defp execution(core, wi) do
    events = EventCore.stream(core, 0)

    case Enum.find(events, &(&1.type == "task.requested" and &1.work_item_id == wi)) do
      nil ->
        case Enum.find(
               events,
               &(&1.type == "task.delegated" and &1.payload["child_work_item_id"] == wi)
             ) do
          nil -> %{}
          parent -> execution(core, parent.work_item_id)
        end

      root ->
        Map.drop(root.payload["execution"] || %{}, ["tools"])
    end
  end

  defp reply(core, request, terminal) do
    payload =
      if terminal.type == "task.completed",
        do: %{
          request_id: request.event_id,
          actor: request.payload["actor"],
          outcome: "completed",
          output: %{comment: terminal.payload["result"], completed: true}
        },
        else: %{
          request_id: request.event_id,
          actor: request.payload["actor"],
          outcome: "failed",
          error: terminal.payload["comment"]
        }

    EventCore.append(
      core,
      Envelope.command("interception.responded",
        idempotency_key: "actor-reply:" <> request.event_id,
        correlation_id: request.correlation_id,
        causation_id: terminal.event_id,
        session_id: request.session_id,
        work_item_id: request.work_item_id,
        payload: payload
      )
    )
  end
end
