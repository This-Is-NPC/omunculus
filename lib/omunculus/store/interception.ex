defmodule Omunculus.Store.Interception do
  @moduledoc """
  Interception: the harness does not perform an action of an agent that an
  `[[interceptors]]` rule holds. It opens a request from the acting account
  to the rule's first reviewer, with the action as its content and the
  options `approve`, `edit` and `deny`, and the acting run waits on it like
  on any request it raised. The `interceptions` row of that request keeps
  the action as an emit, the actor, and the reviewers still to ask.

  A reply decides. `deny` returns the reviewer's reply to the actor as the
  answer and performs nothing. `approve` and `edit` send the action to the
  next reviewer as a new request, with the edit applied, until the last
  approves; then the action is performed as the actor, every event it writes
  carrying `released_by`, the review request. `edit` replaces the text of the
  action: the question's reason, a comment's body, an attachment's note;
  for a tool or a grant it approves with the reviewer's note. A released
  action is not held again by the rule that held it. A tool is run by the
  harness after the `release` event, which says so.
  """

  alias Omunculus.{Interceptors, Participant}
  alias Omunculus.Store.Actions
  alias Omunculus.Store.Actions.{Helpers, Requests}
  alias Omunculus.Store.{Destination, Events, Query, View}

  @options %{"approve" => [], "edit" => [], "deny" => []}
  @actor_keys ~w(run_id work_id author agent issuer subject origin_issuer origin_subject conversation_id request_id inbox_id tool)a
  @kinds %{
    "request" => "ask",
    "comment" => "comment",
    "attach" => "attach",
    "grant" => "grant",
    "reopen" => "grant",
    "tool" => "tool"
  }

  @doc """
  Holds `emit` (`%{"type", "body"}`; a tool is `%{"type" => "tool", "body" =>
  %{"name", "args"}}`) when a rule matches it, for the agent of `ctx`.
  `target` is the identity the action reaches, or a function giving it.
  """
  @spec hold(Omunculus.Store.Connection.t(), map, map, map | nil | (-> map | nil)) ::
          :pass | {:held, map} | {:error, term}
  def hold(conn, ctx, %{"type" => type, "body" => body} = emit, target) do
    action = Map.fetch!(@kinds, type)

    if Map.get(ctx, :author) == "agent" and is_binary(Map.get(ctx, :run_id)) and
         Interceptors.any?(ctx.config, action) do
      with {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id) do
        facts = %{
          tool: body["name"],
          workflow: work && work.workflow,
          stage: work && work.stage,
          target: if(is_function(target, 0), do: target.(), else: target),
          requester: Destination.requester_identity(conn, ctx)
        }

        passed = Map.get(ctx, :passed, [])

        case Interceptors.find(ctx.config, action, ctx.agent, facts, passed) do
          nil -> :pass
          {index, rule} -> start(conn, ctx, emit, action, index, rule, facts, passed)
        end
      end
    else
      :pass
    end
  end

  @doc "Holds the call of a tool a rule names: the `hold` emit of the harness."
  @spec hold_tool(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def hold_tool(conn, %{"tool" => tool, "args" => args}, ctx) do
    emit = %{"type" => "tool", "body" => %{"name" => tool, "args" => args}}

    case hold(conn, ctx, emit, nil) do
      {:held, event} -> {:ok, event}
      :pass -> {:error, {:hold, :invalid_emit}}
      {:error, _reason} = error -> error
    end
  end

  def hold_tool(_conn, _body, _ctx), do: {:error, {:hold, :invalid_emit}}

  defp start(conn, ctx, emit, action, index, rule, facts, passed) do
    meta = %{
      action: action,
      rule: index,
      reviewers: rule.accounts,
      step: 0,
      passed: passed,
      target: facts.target,
      summary: summary(emit, facts.target)
    }

    with {:ok, event} <- open(conn, ctx, emit, meta), do: {:held, event}
  end

  defp open(conn, ctx, emit, meta) do
    name = Enum.at(meta.reviewers, meta.step)

    with {:ok, run} <- View.view(conn, "run", ctx.run_id),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, participant} <- Participant.from_context(ctx),
         {:ok, arbiter, arbiter_work_id} <-
           Destination.resolve(conn, ctx, run, work, participant, name, [])
           |> reviewer(name),
         {:ok, event} <-
           Requests.create(
             conn,
             ctx,
             run,
             work,
             participant,
             reason(participant, meta.summary),
             @options,
             arbiter,
             arbiter_work_id,
             not Requests.waiting_on_children?(work),
             %{
               interception: %{
                 action: meta.action,
                 summary: meta.summary,
                 step: meta.step + 1,
                 of: length(meta.reviewers)
               }
             }
           ),
         :ok <-
           Query.insert(conn, :interceptions, %{
             request_id: event.request_id,
             rule: meta.rule,
             action: meta.action,
             summary: meta.summary,
             target: meta.target && Jason.encode!(meta.target),
             reviewers: Jason.encode!(meta.reviewers),
             step: meta.step,
             passed: Jason.encode!(meta.passed),
             actor:
               ctx |> Map.take(@actor_keys) |> Map.reject(&is_nil(elem(&1, 1))) |> Jason.encode!(),
             emit: Jason.encode!(emit)
           }) do
      {:ok, event}
    end
  end

  defp reviewer({:error, _reason}, name), do: {:error, {:interception, {:reviewer, name}}}
  defp reviewer(ok, _name), do: ok

  defp reason(participant, summary) do
    "#{Participant.label(participant)} would #{summary}. It waits for your review.\n\n" <>
      "approve lets it go ahead as written. edit lets it go ahead with your reply in " <>
      "place of its text; for a tool or a grant, which have none, edit approves with your " <>
      "note. deny stops it, and your reply goes back as the answer."
  end

  defp summary(%{"type" => "request", "body" => body}, target),
    do: ~s(ask #{label(target)}: "#{body["reason"]}")

  defp summary(%{"type" => "comment", "body" => body}, nil), do: ~s(comment: "#{body["body"]}")

  defp summary(%{"type" => "comment", "body" => body}, target),
    do: ~s(comment for #{label(target)}: "#{body["body"]}")

  defp summary(%{"type" => "attach", "body" => body}, _target) do
    names = Enum.map_join(body["attachments"], ", ", & &1["name"])
    if body["note"], do: ~s(attach #{names}: "#{body["note"]}"), else: "attach #{names}"
  end

  defp summary(%{"type" => "grant", "body" => body}, target),
    do: "grant #{body["name"]} (#{body["kind"]}) to #{label(target)}"

  defp summary(%{"type" => "reopen", "body" => body}, target) do
    names = Enum.map_join(body["grant"], ", ", & &1["name"])
    "reopen a work for #{label(target)} and give it #{names}"
  end

  defp summary(%{"type" => "tool", "body" => body}, _target),
    do: "run the tool #{body["name"]} with #{Jason.encode!(body["args"])}"

  defp label(nil), do: "someone"
  defp label(identity), do: Participant.label(identity)

  @doc "The reply of a review names one of its options."
  @spec validate_reply(map, map) :: :ok | {:error, term}
  def validate_reply(%{interception: nil}, _body), do: :ok

  def validate_reply(%{interception: _review}, %{"option" => option})
      when option in ~w(approve edit deny),
      do: :ok

  def validate_reply(%{interception: _review}, _body), do: {:error, {:reply, :review_option}}

  @doc """
  What a reply to a review does: nothing for a deny, the next review or the
  release for an approval. Returns the events it wrote.
  """
  @spec settle(Omunculus.Store.Connection.t(), map, map, map) :: {:ok, [map]} | {:error, term}
  def settle(_conn, _ctx, %{interception: nil}, _body), do: {:ok, []}
  def settle(_conn, _ctx, _request, %{"option" => "deny"}), do: {:ok, []}

  def settle(conn, ctx, %{id: id, interception: review} = request, body) do
    emit = if body["option"] == "edit", do: edited(review.emit, body["body"]), else: review.emit
    actor = actor_ctx(review.actor, ctx)

    if review.step + 1 < length(review.reviewers) do
      forward(conn, actor, id, review, emit)
    else
      release(conn, ctx, actor, request, review, emit, body["option"])
    end
  end

  defp forward(conn, actor, id, review, emit) do
    meta = %{
      action: review.action,
      rule: review.rule,
      reviewers: review.reviewers,
      step: review.step + 1,
      passed: review.passed,
      target: review.target,
      summary: summary(emit, review.target)
    }

    Events.with_actor(conn, actor, fn ->
      with {:ok, event} <- open(conn, actor, emit, meta),
           :ok <-
             Query.exec(conn, "UPDATE interceptions SET next_id = ? WHERE request_id = ?", [
               event.request_id,
               id
             ]),
           do: {:ok, [event]}
    end)
  end

  defp release(conn, ctx, actor, request, review, emit, option) do
    released =
      Map.merge(actor, %{released_by: request.id, passed: review.passed ++ [review.rule]})

    with {:ok, event} <-
           Events.append(conn, %{
             type: "release",
             run_id: ctx.run_id,
             request_id: request.id,
             work_id: request.work_id,
             conversation_id: request.conversation_id,
             body: Jason.encode!(release_body(review, emit, option, released))
           }),
         {:ok, performed} <- perform(conn, emit, released) do
      {:ok, [event | performed]}
    end
  end

  defp release_body(review, %{"type" => "tool", "body" => tool}, option, released),
    do: %{
      action: review.action,
      option: option,
      summary: review.summary,
      tool: tool["name"],
      args: tool["args"],
      passed: released.passed
    }

  defp release_body(review, _emit, option, released),
    do: %{action: review.action, option: option, summary: review.summary, passed: released.passed}

  # The harness runs a tool: it is not a store action.
  defp perform(_conn, %{"type" => "tool"}, _released), do: {:ok, []}
  defp perform(conn, emit, released), do: Actions.run(conn, [emit], released)

  defp actor_ctx(actor, ctx),
    do: Map.merge(Map.take(ctx, [:config, :groups]), actor)

  defp edited(%{"type" => "request"} = emit, text), do: put_in(emit, ["body", "reason"], text)
  defp edited(%{"type" => "comment"} = emit, text), do: put_in(emit, ["body", "body"], text)
  defp edited(%{"type" => "attach"} = emit, text), do: put_in(emit, ["body", "note"], text)
  defp edited(emit, _text), do: emit
end
