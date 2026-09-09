defmodule Omunculus.Interception.Agents do
  @moduledoc "Configured agent Runs answer interception contracts without task assessment or retries."
  alias Omunculus.{EventCore, Interception}
  alias Omunculus.Event.Envelope

  def contract(core, work_item_id) do
    activation =
      EventCore.stream(core, 0, work_item_id: work_item_id, type: "task.requested")
      |> List.first()

    if activation && activation.payload["interception_request_id"] do
      {:ok, request} = EventCore.fetch(core, activation.payload["interception_request_id"])
      request.payload["rule"]["response"]
    end
  end

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
          &(&1.work_item_id == wi and
              (&1.type == "run.failed" or
                 (&1.type == "run.completed" and &1.payload["outcome"] == "responded")))
        )

      activation = Enum.find(events, &(&1.type == "task.requested" and &1.work_item_id == wi))

      cond do
        response ->
          :ok

        terminal ->
          if terminal.type == "run.completed" do
            EventCore.append!(
              state.core,
              Envelope.event("task.completed",
                idempotency_key: "actor-finished:" <> request.event_id,
                correlation_id: terminal.correlation_id,
                causation_id: terminal.event_id,
                session_id: terminal.session_id,
                work_item_id: wi,
                payload: %{result: Jason.encode!(terminal.payload["output"]), depth: 0}
              )
            )
          end

          reply(state.core, request, terminal)

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
          comment: Jason.encode!(Omunculus.Interception.Delivery.event(source, rule)),
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
      if terminal.type == "run.completed",
        do: %{
          request_id: request.event_id,
          actor: request.payload["actor"],
          outcome: "completed",
          output: terminal.payload["output"]
        },
        else: %{
          request_id: request.event_id,
          actor: request.payload["actor"],
          outcome: "failed",
          error: terminal.payload["reason"]
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
