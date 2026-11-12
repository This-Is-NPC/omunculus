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
      summary: summary(emit, facts.target, ctx.agent),
      lines: lines(emit)
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
             reason(meta.summary, Map.fetch!(meta, :lines)),
             @options,
             arbiter,
             arbiter_work_id,
             not Requests.waiting_on_children?(work),
             %{
               interception: %{
                 action: meta.action,
                 summary: meta.summary,
                 target: target_label(meta.target),
                 args: meta.lines,
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

  defp reason(summary, lines) do
    held = Enum.map_join(lines, "", &"\n#{&1["name"]}: #{&1["value"]}")

    "#{summary}.#{held}\n\nIt waits for your review.\n\n" <>
      "approve lets it go ahead as written. edit lets it go ahead with your reply in " <>
      "place of its text; for a tool or a grant, which have none, edit approves with your " <>
      "note. deny stops it, and your reply goes back as the answer."
  end

  defp summary(%{"type" => "request", "body" => body}, target, who),
    do: ~s(#{who} wants to ask #{label(target)}: "#{body["reason"]}")

  defp summary(%{"type" => "comment", "body" => body}, nil, who),
    do: ~s(#{who} wants to comment: "#{body["body"]}")

  defp summary(%{"type" => "comment", "body" => body}, target, who),
    do: ~s(#{who} wants to comment for #{label(target)}: "#{body["body"]}")

  defp summary(%{"type" => "attach", "body" => body}, _target, who) do
    names = Enum.map_join(body["attachments"], ", ", & &1["name"])

    if body["note"],
      do: ~s(#{who} wants to attach #{names}: "#{body["note"]}"),
      else: "#{who} wants to attach #{names}"
  end

  defp summary(%{"type" => "grant", "body" => body}, target, who),
    do: "#{who} wants to grant #{body["name"]} (#{body["kind"]}) to #{label(target)}"

  defp summary(%{"type" => "reopen", "body" => body}, target, who) do
    names = Enum.map_join(body["grant"], ", ", & &1["name"])
    "#{who} wants to reopen a work for #{label(target)} and give it #{names}"
  end

  defp summary(%{"type" => "tool", "body" => body}, _target, who),
    do: "#{who} wants to run #{body["name"]}"

  defp label(nil), do: "someone"
  defp label(identity), do: Participant.label(identity)

  @doc """
  The arguments of a held tool as `%{"name", "value"}` lines for a reader:
  strings as they are, a nested map or list flattened one level into one
  line, any other value as text. Other actions have none: their text is in
  the summary.
  """
  @spec lines(map) :: [%{String.t() => String.t()}]
  def lines(%{"type" => "tool", "body" => %{"args" => args}}) when is_map(args),
    do: for({name, value} <- Enum.sort(args), do: %{"name" => name, "value" => readable(value)})

  def lines(_emit), do: []

  defp readable(value) when is_binary(value), do: value
  defp readable(nil), do: "none"

  defp readable(value) when is_map(value),
    do: Enum.map_join(Enum.sort(value), ", ", fn {k, v} -> "#{k}: #{scalar(v)}" end)

  defp readable(value) when is_list(value), do: Enum.map_join(value, ", ", &scalar/1)
  defp readable(value), do: to_string(value)

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp scalar(value), do: readable(value)

  @doc """
  The files a held action carries, as `%{"name", "bytes"}`: the attachments of
  an attach, the artifact a `put_artifact` call writes. None for other actions.
  """
  @spec files(map) :: [%{String.t() => String.t() | non_neg_integer}]
  def files(%{"type" => "attach", "body" => %{"attachments" => list}}),
    do: for(%{"name" => name, "bytes" => bytes} <- list, do: %{"name" => name, "bytes" => bytes})

  def files(%{
        "type" => "tool",
        "body" => %{"name" => "put_artifact", "args" => %{"name" => name} = args}
      }) do
    case args do
      %{"content" => content} when is_binary(content) ->
        [%{"name" => name, "bytes" => byte_size(content)}]

      %{"base64" => data} ->
        case Omunculus.Attachments.decode(data) do
          {:ok, bytes} -> [%{"name" => name, "bytes" => byte_size(bytes)}]
          {:error, _invalid} -> []
        end

      %{"data" => data} when is_map(data) ->
        [%{"name" => name, "bytes" => data |> Jason.encode!() |> byte_size()}]

      _none ->
        []
    end
  end

  def files(_emit), do: []

  @doc "The identity an action reaches, as a reader names it; nil when none."
  @spec target_label(map | nil) :: String.t() | nil
  def target_label(nil), do: nil
  def target_label(identity), do: Participant.label(identity)

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
      summary: summary(emit, review.target, review.actor.agent),
      lines: lines(emit)
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

  @doc """
  The tool a review released that has not run yet: the body of its `release`
  event (`"tool"`, `"args"`, `"passed"`), or nil.
  """
  @spec released_call(Omunculus.Store.Connection.t(), String.t()) ::
          {:ok, map | nil} | {:error, term}
  def released_call(conn, request_id) do
    with {:ok, row} <-
           Query.one(
             conn,
             """
             SELECT body FROM events
             WHERE type = 'release' AND request_id = ?
               AND NOT EXISTS (SELECT 1 FROM events WHERE released_by = ? AND type = 'tool')
             """,
             [request_id, request_id]
           ) do
      case row && Jason.decode!(row.body) do
        %{"tool" => tool} = body when is_binary(tool) -> {:ok, body}
        _other -> {:ok, nil}
      end
    end
  end

  # The actor's next run runs a tool: it is not a store action.
  defp perform(_conn, %{"type" => "tool"}, _released), do: {:ok, []}
  defp perform(conn, emit, released), do: Actions.run(conn, [emit], released)

  defp actor_ctx(actor, ctx),
    do: Map.merge(Map.take(ctx, [:config, :groups]), actor)

  defp edited(%{"type" => "request"} = emit, text), do: put_in(emit, ["body", "reason"], text)
  defp edited(%{"type" => "comment"} = emit, text), do: put_in(emit, ["body", "body"], text)
  defp edited(%{"type" => "attach"} = emit, text), do: put_in(emit, ["body", "note"], text)
  defp edited(emit, _text), do: emit
end
