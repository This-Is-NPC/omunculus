defmodule Omunculus.Interception do
  @moduledoc "Durable actor exchanges. Source envelopes are immutable; delivery context is derived from replies."
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Store
  @columns Envelope.columns() |> Enum.join(", ")

  def actor?(rule), do: is_binary(rule[:actor]) or is_binary(rule[:agent])

  @doc "Only the delivered comment can replace the current handoff context."
  def changed_comment(core, env) do
    {:ok, original} = Omunculus.EventCore.fetch(core, env.event_id)
    comment = env.payload["comment"]
    if is_binary(comment) and comment != original.payload["comment"], do: comment
  end

  def context_checkpoint(checkpoint, work_item, comment) do
    checkpoint = checkpoint || %{}

    if is_list(checkpoint["messages"]) and checkpoint["messages"] != [] do
      Map.update!(
        checkpoint,
        "messages",
        &(&1 ++
            [
              %{"role" => "user", "content" => Omunculus.WorkItem.render(work_item, comment)}
            ])
      )
    else
      checkpoint
    end
  end

  def rules(rules, env) do
    Enum.filter(rules, fn rule ->
      actor?(rule) and rule[:enabled] != false and env.type in rule.events and
        (rule[:workspaces] in [nil, []] or env.workspace_id in rule.workspaces) and
        Enum.all?(rule[:match] || %{}, fn {path, value} ->
          get_path(env.payload, path) == value
        end)
    end)
  end

  def plan(conn, env, rules, append) do
    matching = rules(rules, env)

    if matching != [] and not actor_work?(conn, env.work_item_id) do
      for rule <- matching do
        unless requests(conn, env.event_id, rule.name) != [] do
          request(env, rule, 0, nil) |> append.()
        end
      end
    end
  end

  defp request(source, rule, attempt, previous) do
    actor = rule[:actor] || "agent:" <> rule.agent
    id = stable_id("int", "#{source.event_id}:#{rule.name}:#{attempt}")
    rule = Map.drop(rule, [:module])
    timestamp = if previous, do: previous.occurred_at, else: source.occurred_at
    {:ok, requested_at, _} = DateTime.from_iso8601(timestamp)

    Envelope.event("interception.requested",
      event_id: id,
      occurred_at: timestamp,
      idempotency_key: id,
      correlation_id: source.correlation_id,
      causation_id: if(previous, do: previous.event_id, else: source.event_id),
      session_id: source.session_id,
      workspace_id: source.workspace_id,
      work_item_id: source.work_item_id,
      run_id: source.run_id,
      payload: %{
        source_event_id: source.event_id,
        name: rule.name,
        actor: actor,
        attempt: attempt,
        rule: rule,
        actor_work_item_id: stable_id("wi", id),
        deadline_at:
          if(is_integer(rule[:timeout_ms]),
            do:
              requested_at
              |> DateTime.add(rule.timeout_ms, :millisecond)
              |> DateTime.to_iso8601()
          )
      }
    )
  end

  def guard(conn, %{type: type} = env)
      when type in ["interception.responded", "interception.expired"] do
    p = env.payload
    req = fetch(conn, p["request_id"])

    cond do
      is_nil(req) or req.type != "interception.requested" ->
        {:error, :unknown_interception_request}

      p["actor"] != req.payload["actor"] ->
        {:error, :interception_actor_mismatch}

      env.session_id != req.session_id or env.correlation_id != req.correlation_id ->
        {:error, :interception_correlation_mismatch}

      responses(conn, req.event_id) != [] ->
        {:error, :interception_already_answered}

      type == "interception.responded" and expired?(req) ->
        {:error, :interception_deadline_elapsed}

      p["outcome"] not in ["completed", "failed"] ->
        {:error, :invalid_interception_outcome}

      p["outcome"] == "failed" and not nonempty?(p["error"]) ->
        {:error, :interception_error_required}

      p["outcome"] == "completed" and
          not valid_output?(req.payload["rule"]["response"], p["output"]) ->
        {:error, :invalid_interception_output}

      true ->
        :ok
    end
  end

  def guard(_, _), do: :ok

  def resolve(conn, %{type: type} = reply, append)
      when type in ["interception.responded", "interception.expired"] do
    handled =
      Store.query(
        conn,
        "SELECT 1 FROM EVENTS WHERE causation_id = ? AND type IN ('interception.requested', 'interception.resolved') LIMIT 1",
        [reply.event_id]
      )

    if handled == [] do
      resolve_pending(conn, reply, append)
    else
      req = fetch(conn, reply.payload["request_id"])
      fetch(conn, req.payload["source_event_id"])
    end
  end

  def resolve(_conn, _env, _append), do: nil

  defp resolve_pending(conn, reply, append) do
    req = fetch(conn, reply.payload["request_id"])
    # Only recover replies whose resulting interaction event was not committed.
    source = fetch(conn, req.payload["source_event_id"])
    rule = req.payload["rule"]
    attempt = req.payload["attempt"]

    if reply.payload["outcome"] == "completed" do
      resolved =
        Envelope.event("interception.resolved",
          idempotency_key: "resolve:" <> req.event_id,
          correlation_id: source.correlation_id,
          causation_id: reply.event_id,
          session_id: source.session_id,
          work_item_id: source.work_item_id,
          payload: %{
            request_id: req.event_id,
            source_event_id: source.event_id,
            name: req.payload["name"],
            bindings: rule["bindings"] || %{},
            output: reply.payload["output"]
          }
        )

      append.(resolved)
    else
      next_rule = Map.new(rule, fn {k, v} -> {String.to_existing_atom(k), v} end)

      if attempt < rule["max_retries"] do
        append.(request(source, next_rule, attempt + 1, reply))
      else
        # Escalation remains an unanswered interaction; no process waits on it.
        next_rule =
          next_rule
          |> Map.put(:actor, "human")
          |> Map.put(:agent, nil)
          |> Map.put(:timeout_ms, nil)

        append.(request(source, next_rule, attempt + 1, reply))
      end
    end

    source
  end

  def view(conn, env) do
    if Omunculus.Events.actor_boundary?(env.type),
      do: boundary_view(conn, env),
      else: {:ready, env}
  end

  defp boundary_view(conn, env) do
    reqs = requests(conn, env.event_id)
    groups = Enum.group_by(reqs, & &1.payload["name"])

    Enum.reduce_while(
      groups |> Enum.sort_by(fn {_, rs} -> hd(rs).sequence end),
      {:ready, env},
      fn {name, rs}, {:ready, current} ->
        rule = hd(rs).payload["rule"]
        resolution = resolved(conn, env.event_id, name)

        cond do
          rule["wait"] == false ->
            {:cont, {:ready, current}}

          is_nil(resolution) ->
            {:halt, :pending}

          true ->
            output = resolution.payload["output"]

            payload =
              Enum.reduce(resolution.payload["bindings"], current.payload, fn {target, from},
                                                                              acc ->
                put_path(acc, String.split(target, "."), get_path(output, from))
              end)

            {:cont, {:ready, %{current | payload: payload}}}
        end
      end
    )
  end

  def expire(conn, append) do
    requests =
      Store.query(
        conn,
        "SELECT #{@columns} FROM EVENTS WHERE type = 'interception.requested' ORDER BY sequence"
      )
      |> Enum.map(&Envelope.from_row/1)

    for req <- requests, expired?(req), responses(conn, req.event_id) == [] do
      append.(
        Envelope.event("interception.expired",
          idempotency_key: "expire:" <> req.event_id,
          causation_id: req.event_id,
          correlation_id: req.correlation_id,
          session_id: req.session_id,
          work_item_id: req.work_item_id,
          payload: %{
            request_id: req.event_id,
            actor: req.payload["actor"],
            outcome: "failed",
            error: "Configured actor response deadline elapsed"
          }
        )
      )
    end
  end

  defp expired?(%{payload: %{"deadline_at" => deadline}}) when is_binary(deadline) do
    {:ok, deadline, _} = DateTime.from_iso8601(deadline)
    DateTime.compare(DateTime.utc_now(), deadline) != :lt
  end

  defp expired?(_), do: false

  def valid_output?(schema, output) when is_map(schema) and is_map(output) do
    Enum.all?(schema, fn {key, type} ->
      value = Map.get(output, key)

      case type do
        "string" -> nonempty?(value)
        "boolean" -> is_boolean(value)
        "number" -> is_number(value)
        "object" -> is_map(value)
        "array" -> is_list(value)
        _ -> false
      end
    end)
  end

  def valid_output?(_, _), do: false
  defp nonempty?(v), do: is_binary(v) and String.trim(v) != ""

  def get_path(map, path),
    do: Enum.reduce(String.split(path, "."), map, fn k, v -> if is_map(v), do: v[k] end)

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value),
    do: Map.put(map, key, put_path(map[key] || %{}, rest, value))

  def requests(conn, source_id, name \\ nil) do
    all(conn, "interception.requested", "source_event_id", source_id)
    |> Enum.filter(&(is_nil(name) or &1.payload["name"] == name))
  end

  defp responses(conn, id),
    do:
      all(conn, "interception.responded", "request_id", id) ++
        all(conn, "interception.expired", "request_id", id)

  defp resolved(conn, id, name),
    do:
      all(conn, "interception.resolved", "source_event_id", id)
      |> Enum.find(&(&1.payload["name"] == name))

  defp all(conn, type, key, value) do
    Store.query(
      conn,
      "SELECT #{@columns} FROM EVENTS WHERE type = ? AND json_extract(payload, '$.#{key}') = ? ORDER BY sequence",
      [type, value]
    )
    |> Enum.map(&Envelope.from_row/1)
  end

  defp fetch(conn, id) do
    case Store.one(conn, "SELECT #{@columns} FROM EVENTS WHERE event_id = ?", [id]) do
      nil -> nil
      row -> Envelope.from_row(row)
    end
  end

  defp actor_work?(_conn, nil), do: false

  defp actor_work?(conn, wi) do
    own =
      Store.one(
        conn,
        "SELECT payload FROM EVENTS WHERE type = 'task.requested' AND work_item_id = ? ORDER BY sequence LIMIT 1",
        [wi]
      )

    case own do
      [payload] ->
        is_binary(Jason.decode!(payload)["interception_request_id"])

      nil ->
        case Store.one(
               conn,
               "SELECT work_item_id FROM EVENTS WHERE type IN ('task.delegated', 'task.requested') AND json_extract(payload, '$.child_work_item_id') = ? LIMIT 1",
               [wi]
             ) do
          [parent] when parent != wi -> actor_work?(conn, parent)
          _ -> false
        end
    end
  end

  def stable_id(prefix, key),
    do:
      prefix <>
        "-" <> (:crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 24))
end
