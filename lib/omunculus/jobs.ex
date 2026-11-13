defmodule Omunculus.Jobs do
  @moduledoc """
  Scheduled jobs: data in the project's store, never in the config (the
  TOML holds only the policy, `Omunculus.Jobs.Policy`). A job is what its
  events say, folded in order, as memory is: no table of its own, so a store
  made before jobs keeps working. Two event types carry them:

  - `job`: `create`, `change` (which bumps `version`) and `transition` (with
    its reason) of a job, each with its `origin`: the author, the channel
    (`cli`, `api`, `console`, `tool`, `pack` or `proposal`), the request that
    approved it and the run, work and conversation it came from;
  - `job_fire`: one event for each state a fire reaches, with what it cost
    (`record_fire/3`).

  A job is a map of string keys: `id`, `name`, `state` (`proposed`,
  `active`, `paused`, `ended`, `archived`), `version`, the fields of
  `Omunculus.Jobs.Fields`, `created_at`, `updated_at`, `anchor` (where its
  schedule counts from), `origin` (of the latest create or change),
  `state_reason`, and, for a read, `read_at` (when its thread was last read), `fires` (totals of the fires that
  finished), `last_fire` and `next_fire`.

  A fire acts as the job's `owner`; the scheduler that starts fires opens
  their runs with `via = "job"`, which is how a run that a fire opened, and
  every run below it, is told from any other: such a run may not create or
  change jobs.

  Reads: `list/1`, `get/2`, `history/3`, `fires/2`. For the scheduler:
  `due/2`, `pending/1`, `record_fire/3` and `transition/5`. The emits of
  the `jobs` and `propose_job` tools reach `write/3`.
  """

  alias Omunculus.{Id, Participant}
  alias Omunculus.Jobs.{Fields, Schedule}
  alias Omunculus.Store.{Connection, Events, Query, View}

  @states ~w(proposed active paused ended archived)
  @moves %{
    "proposed" => ~w(active archived),
    "active" => ~w(paused ended archived),
    "paused" => ~w(active ended archived),
    "ended" => ~w(archived),
    "archived" => []
  }
  @channels ~w(cli api console pack)

  @fire_moves %{
    "due" => ~w(skipped missed late running cancelled),
    "late" => ~w(running missed skipped cancelled),
    "running" => ~w(succeeded failed cancelled)
  }
  @finished ~w(skipped missed succeeded failed cancelled)
  @counters ~w(duration_ms calls input_tokens output_tokens)

  @doc "The states a job is in."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The states a fire passes through; those that end it are `finished_fire_states/0`."
  @spec fire_states() :: [String.t()]
  def fire_states, do: ["due", "late", "running" | @finished]

  @spec finished_fire_states() :: [String.t()]
  def finished_fire_states, do: @finished

  ## Reads

  @doc "The jobs of the store that are not archived, oldest first, each as a read gives it."
  @spec list(Connection.t()) :: {:ok, [map]} | {:error, term}
  def list(conn) do
    with {:ok, jobs} <- fold(conn),
         {:ok, totals} <- totals(conn) do
      jobs
      |> Map.values()
      |> Enum.reject(&(&1["state"] == "archived"))
      |> Enum.sort_by(&{&1["created_at"], &1["id"]})
      |> Enum.map(&read(conn, &1, totals))
      |> collect()
    end
  end

  @doc "The job named `ref` (its name, or its id), archived or not."
  @spec get(Connection.t(), String.t()) :: {:ok, map} | {:error, term}
  def get(conn, ref) do
    with {:ok, job} <- find(conn, ref),
         {:ok, totals} <- totals(conn),
         do: read(conn, job, totals)
  end

  @doc """
  The events of a job, oldest first: each `at`, `sequence`, `op` (`create`,
  `change`, `transition` or `fire`) and what that event holds. With `limit`,
  only the newest.
  """
  @spec history(Connection.t(), String.t(), pos_integer | nil) ::
          {:ok, [map]} | {:error, term}
  def history(conn, ref, limit \\ nil) do
    with {:ok, job} <- find(conn, ref),
         {:ok, rows} <-
           Query.all(
             conn,
             """
             SELECT sequence, at, type, body FROM events
             WHERE type = 'job' AND json_extract(body, '$.id') = ?1
             UNION ALL
             SELECT sequence, at, type, body FROM events
             WHERE type = 'job_fire' AND json_extract(body, '$.id') = ?1
             ORDER BY sequence DESC LIMIT ?2
             """,
             [job["id"], limit || -1]
           ) do
      {:ok, rows |> Enum.reverse() |> Enum.map(&entry/1)}
    end
  end

  defp entry(%{type: "job", body: body} = row),
    do: row |> Map.take([:sequence, :at]) |> stringify() |> Map.merge(Jason.decode!(body))

  defp entry(%{type: "job_fire", body: body} = row) do
    row
    |> Map.take([:sequence, :at])
    |> stringify()
    |> Map.merge(Jason.decode!(body))
    |> Map.put("op", "fire")
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @doc "The fires of a job, oldest first, each as its events leave it: the latest state with what earlier ones recorded."
  @spec fires(Connection.t(), String.t()) :: {:ok, [map]} | {:error, term}
  def fires(conn, ref) do
    with {:ok, job} <- find(conn, ref),
         {:ok, rows} <-
           Query.all(
             conn,
             "SELECT at, body FROM events WHERE type = 'job_fire' AND json_extract(body, '$.id') = ? ORDER BY sequence",
             [job["id"]]
           ) do
      {:ok, merge_fires(rows)}
    end
  end

  defp merge_fires(rows) do
    rows
    |> Enum.map(&Map.put(Jason.decode!(&1.body), "at", &1.at))
    |> Enum.reduce({[], %{}}, fn body, {order, fires} ->
      id = body["fire_id"]
      order = if Map.has_key?(fires, id), do: order, else: [id | order]
      {order, Map.update(fires, id, body, &Map.merge(&1, body))}
    end)
    |> then(fn {order, fires} -> order |> Enum.reverse() |> Enum.map(&Map.fetch!(fires, &1)) end)
  end

  @doc """
  The job's thread: a message for each fire that finished with a final
  `message` (the agent's last reply), oldest first. A message has the `id`
  of its fire, the `sender` (`%{"kind" => "job", "name" => name}`), the job's
  `id`, its `at`, `text`, `conversation_id` and `run_ids` (a reply to it is a
  normal conversation with the agent, which never changes the job) and
  `unread`: it came after the job's `read_at` (`mark_read`: the `read` op).
  A job whose `delivery` is not `owner_inbox` has no thread.
  """
  @spec messages(Connection.t(), String.t()) :: {:ok, [map]} | {:error, term}
  def messages(conn, ref) do
    with {:ok, %{"delivery" => "owner_inbox"} = job} <- find(conn, ref),
         {:ok, fires} <- fires(conn, job["id"]) do
      {:ok,
       for %{"message" => text} = fire <- fires do
         %{
           "id" => fire["fire_id"],
           "job_id" => job["id"],
           "sender" => %{"kind" => "job", "name" => job["name"]},
           "at" => fire["at"],
           "text" => text,
           "conversation_id" => fire["conversation_id"],
           "run_ids" => fire["run_ids"] || [],
           "unread" => is_nil(job["read_at"]) or fire["at"] > job["read_at"]
         }
       end}
    else
      {:ok, _no_delivery} -> {:ok, []}
      error -> error
    end
  end

  @doc "The fires that have not finished, oldest first: due, late or running."
  @spec pending(Connection.t()) :: {:ok, [map]} | {:error, term}
  def pending(conn) do
    with {:ok, rows} <-
           Query.all(
             conn,
             """
             SELECT fire.body FROM events fire
             WHERE fire.type = 'job_fire'
               AND json_extract(fire.body, '$.state') IN ('due', 'late', 'running')
               AND NOT EXISTS (
                 SELECT 1 FROM events next
                 WHERE next.type = 'job_fire'
                   AND json_extract(next.body, '$.fire_id') = json_extract(fire.body, '$.fire_id')
                   AND next.sequence > fire.sequence)
             ORDER BY fire.sequence
             """
           ) do
      {:ok, Enum.map(rows, &Jason.decode!(&1.body))}
    end
  end

  @doc """
  What is due at `now`: for each active job whose schedule has an instant
  after the last one it fired at (or since it began, or was resumed) and
  not after `now` or its `end_at`, `%{job: job, slots: slots}`, `slots` being
  those instants, oldest first, as a lazy stream. A manual fire (`run`) is
  not a slot: it is a `due` fire, found with `pending/1`. Claim a slot with
  `record_fire/3`; the next due call counts from it.
  """
  @spec due(Connection.t(), DateTime.t()) :: {:ok, [map]} | {:error, term}
  def due(conn, now) do
    with {:ok, jobs} <- fold(conn) do
      jobs
      |> Map.values()
      |> Enum.filter(&(&1["state"] == "active"))
      |> Enum.sort_by(&{&1["created_at"], &1["id"]})
      |> Enum.map(&due_job(conn, &1, now))
      |> collect()
      |> case do
        {:ok, due} -> {:ok, Enum.reject(due, &is_nil/1)}
        error -> error
      end
    end
  end

  defp due_job(conn, job, now) do
    with {:ok, schedule} <- schedule(job),
         {:ok, baseline} <- baseline(conn, job) do
      limit = earliest(now, job["end_at"])

      case Schedule.next_fires(schedule, 1, baseline) do
        [first] ->
          if DateTime.compare(first, limit) == :gt,
            do: {:ok, nil},
            else: {:ok, %{job: job, slots: slots(schedule, baseline, limit)}}

        [] ->
          {:ok, nil}
      end
    else
      {:error, {:jobs, {:unknown_timezone, _}}} -> {:ok, nil}
      error -> error
    end
  end

  defp slots(schedule, baseline, limit) do
    Stream.unfold(baseline, fn from ->
      with [slot] <- Schedule.next_fires(schedule, 1, from),
           :lt <- DateTime.compare(slot, DateTime.add(limit, 1, :microsecond)) do
        {slot, slot}
      else
        _ -> nil
      end
    end)
  end

  defp earliest(now, nil), do: now

  defp earliest(now, end_at) do
    {:ok, ending, _offset} = DateTime.from_iso8601(end_at)
    if DateTime.compare(ending, now) == :lt, do: ending, else: now
  end

  # Where counting resumes: the later of the job's anchor and its last slot.
  defp baseline(conn, job) do
    with {:ok, row} <-
           Query.one(
             conn,
             """
             SELECT json_extract(body, '$.scheduled_for') AS scheduled_for FROM events
             WHERE type = 'job_fire' AND json_extract(body, '$.id') = ?
               AND json_extract(body, '$.manual') IS NULL AND json_extract(body, '$.state') = 'due'
             ORDER BY sequence DESC LIMIT 1
             """,
             [job["id"]]
           ) do
      {:ok, anchor, _} = DateTime.from_iso8601(job["anchor"])

      case row do
        %{scheduled_for: text} when is_binary(text) ->
          {:ok, last, _} = DateTime.from_iso8601(text)
          {:ok, Enum.max([anchor, last], DateTime)}

        _none ->
          {:ok, anchor}
      end
    end
  end

  defp schedule(job), do: Fields.parse(job["schedule"], job["timezone"])

  defp read(conn, job, totals) do
    with {:ok, last} <- last_fire(conn, job),
         {:ok, next} <- next_fire(conn, job) do
      {:ok,
       job
       |> Map.put("fires", Map.get(totals, job["id"], empty_totals()))
       |> Map.put("last_fire", last)
       |> Map.put("next_fire", next)}
    end
  end

  defp collect(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp next_fire(conn, %{"state" => "active"} = job) do
    with {:ok, schedule} <- schedule(job),
         {:ok, baseline} <- baseline(conn, job) do
      case Schedule.next_fires(schedule, 1, baseline) do
        [slot] ->
          ending = job["end_at"]
          past = ending && DateTime.compare(slot, elem(DateTime.from_iso8601(ending), 1)) == :gt
          {:ok, if(past, do: nil, else: DateTime.to_iso8601(slot))}

        [] ->
          {:ok, nil}
      end
    else
      {:error, {:jobs, {:unknown_timezone, _}}} -> {:ok, nil}
      error -> error
    end
  end

  defp next_fire(_conn, _job), do: {:ok, nil}

  defp last_fire(conn, job) do
    with {:ok, row} <-
           Query.one(
             conn,
             "SELECT json_extract(body, '$.fire_id') AS fire_id FROM events WHERE type = 'job_fire' AND json_extract(body, '$.id') = ? ORDER BY sequence DESC LIMIT 1",
             [job["id"]]
           ) do
      case row do
        nil ->
          {:ok, nil}

        %{fire_id: fire_id} ->
          with {:ok, rows} <-
                 Query.all(
                   conn,
                   "SELECT at, body FROM events WHERE type = 'job_fire' AND json_extract(body, '$.fire_id') = ? ORDER BY sequence",
                   [fire_id]
                 ),
               do: {:ok, rows |> merge_fires() |> hd()}
      end
    end
  end

  defp empty_totals do
    (@finished ++ ["fires" | @counters])
    |> Map.new(&{&1, 0})
    |> Map.merge(%{"usd" => 0.0, "success_rate" => nil})
  end

  # What finished fires cost and how they ended, per job.
  defp totals(conn) do
    with {:ok, rows} <-
           Query.all(
             conn,
             """
             SELECT json_extract(body, '$.id') AS id, json_extract(body, '$.state') AS state,
               COUNT(*) AS fires, TOTAL(json_extract(body, '$.usd')) AS usd,
               TOTAL(json_extract(body, '$.duration_ms')) AS duration_ms,
               TOTAL(json_extract(body, '$.calls')) AS calls,
               TOTAL(json_extract(body, '$.input_tokens')) AS input_tokens,
               TOTAL(json_extract(body, '$.output_tokens')) AS output_tokens
             FROM events
             WHERE type = 'job_fire' AND json_extract(body, '$.state') IN ('skipped', 'missed', 'succeeded', 'failed', 'cancelled')
             GROUP BY id, state
             """
           ) do
      {:ok,
       rows
       |> Enum.group_by(& &1.id)
       |> Map.new(fn {id, states} -> {id, sum(states)} end)}
    end
  end

  defp sum(rows) do
    totals =
      Enum.reduce(rows, empty_totals(), fn row, acc ->
        acc
        |> Map.put(row.state, row.fires)
        |> Map.update!("fires", &(&1 + row.fires))
        |> Map.update!("usd", &(&1 + row.usd))
        |> then(fn acc ->
          Enum.reduce(
            @counters,
            acc,
            &Map.update!(&2, &1, fn n -> n + trunc(row[String.to_atom(&1)]) end)
          )
        end)
      end)

    ran = totals["succeeded"] + totals["failed"] + totals["cancelled"]
    %{totals | "success_rate" => if(ran > 0, do: totals["succeeded"] / ran)}
  end

  ## The fold

  defp fold(conn) do
    with {:ok, events} <-
           Query.all(conn, "SELECT at, body FROM events WHERE type = 'job' ORDER BY sequence") do
      {:ok, Enum.reduce(events, %{}, &apply_event/2)}
    end
  end

  defp apply_event(%{at: at, body: body}, jobs) do
    case Jason.decode!(body) do
      %{"op" => "create", "id" => id} = body ->
        job =
          body
          |> Map.take(["id", "name", "state", "version", "origin" | Fields.keys()])
          |> Map.merge(%{
            "created_at" => at,
            "updated_at" => at,
            "anchor" => at,
            "state_reason" => nil
          })

        Map.put(jobs, id, job)

      %{
        "op" => "change",
        "id" => id,
        "fields" => fields,
        "version" => version,
        "origin" => origin
      } ->
        Map.update!(jobs, id, fn job ->
          anchor =
            if Map.has_key?(fields, "schedule") or Map.has_key?(fields, "timezone"),
              do: at,
              else: job["anchor"]

          job
          |> Map.merge(fields)
          |> Map.merge(%{
            "version" => version,
            "updated_at" => at,
            "anchor" => anchor,
            "origin" => origin
          })
        end)

      %{"op" => "read", "id" => id} ->
        Map.update!(jobs, id, &Map.put(&1, "read_at", at))

      %{"op" => "transition", "id" => id, "to" => to} = body ->
        Map.update!(jobs, id, fn job ->
          anchor = if to == "active", do: at, else: job["anchor"]

          Map.merge(job, %{
            "state" => to,
            "state_reason" => body["reason"],
            "updated_at" => at,
            "anchor" => anchor
          })
        end)
    end
  end

  # A job by its name among those not archived, else by id.
  defp find(conn, ref) do
    with {:ok, jobs} <- fold(conn) do
      jobs = Map.values(jobs)

      case Enum.find(jobs, &(&1["name"] == ref and &1["state"] != "archived")) ||
             Enum.find(jobs, &(&1["id"] == ref)) do
        nil -> {:error, {:jobs, {:unknown, ref}}}
        job -> {:ok, job}
      end
    end
  end

  ## Writes

  @ops ~w(create duplicate change transition run read)

  @doc """
  Applies one `job` emit. `op` is `create` (`name` and the fields of
  `Omunculus.Jobs.Fields`, optionally `state`, `proposed` or `active`),
  `duplicate` (`job` and the new `name`; the copy starts `proposed`),
  `change` (`job` and the fields to change; the name and the
  conversation stay), `transition`
  (`job`, `to`, optionally `reason`) `run` (`job`: a manual fire) or `read` (`job`: its thread is read up to now).

  The `owner` of a create is its author unless named. The write is refused
  without a `[jobs]` table, in a run that a fire opened, past the limits, and
  for an agent unless the request that approved it is named (`request_id`:
  closed, with `approve` chosen, an option that calls `jobs`) or
  `[jobs] agent_may_create` lets a create through, owned by the agent itself.
  `ctx` is the store's: its `config`, the author and the run.
  """
  @spec write(Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def write(_conn, %{"op" => _op}, %{config: %{jobs: nil}}), do: {:error, {:jobs, :disabled}}

  def write(conn, %{"op" => op} = body, ctx) when op in @ops do
    with :ok <- outside_fires(conn, ctx.run_id),
         {:ok, origin} <- origin(conn, op, body, ctx) do
      operate(conn, op, body, origin, ctx.config)
    end
  end

  def write(_conn, _body, _ctx), do: {:error, {:jobs, {:invalid, "op"}}}

  defp operate(conn, "create", body, origin, config) do
    with {:ok, input} <- Fields.input(body, config),
         {:ok, owner} <- owner(input["owner"], origin),
         {:ok, fields} <-
           Fields.check(Map.merge(Fields.blank(), Map.put(input, "owner", owner)), config) do
      create(conn, body["name"], fields, body["state"] || "active", nil, origin, config)
    end
  end

  defp operate(conn, "duplicate", body, origin, config) do
    with {:ok, source} <- find(conn, body["job"]),
         {:ok, fields} <- Fields.check(Map.take(source, Fields.keys()), config) do
      create(conn, body["name"], fields, "proposed", source["id"], origin, config)
    end
  end

  defp operate(conn, "change", body, origin, config) do
    with {:ok, job} <- find(conn, body["job"]),
         :ok <-
           if(job["state"] == "archived",
             do: {:error, {:jobs, {:state, "archived", "change"}}},
             else: :ok
           ),
         {:ok, input} <- Fields.input(body, config),
         :ok <- fixed_conversation(job, input),
         {:ok, fields} <- Fields.check(Map.merge(Map.take(job, Fields.keys()), input), config),
         changed = Map.reject(fields, fn {key, value} -> job[key] == value end),
         :ok <- if(changed == %{}, do: {:error, {:jobs, :unchanged}}, else: :ok) do
      job_event(conn, origin, %{
        "op" => "change",
        "id" => job["id"],
        "version" => job["version"] + 1,
        "fields" => changed
      })
    end
  end

  defp operate(conn, "transition", body, origin, _config) do
    with {:ok, job} <- find(conn, body["job"]),
         {:ok, to} <- move(job, body["to"]) do
      job_event(conn, origin, %{
        "op" => "transition",
        "id" => job["id"],
        "from" => job["state"],
        "to" => to,
        "reason" => body["reason"]
      })
    end
  end

  defp operate(conn, "read", body, origin, _config) do
    with {:ok, job} <- find(conn, body["job"]),
         do: job_event(conn, origin, %{"op" => "read", "id" => job["id"]})
  end

  defp operate(conn, "run", body, _origin, _config) do
    with {:ok, job} <- find(conn, body["job"]),
         :ok <-
           if(job["state"] in ~w(active paused),
             do: :ok,
             else: {:error, {:jobs, {:state, job["state"], "run"}}}
           ),
         {:ok, event, _fire} <-
           fire(conn, job, %{
             "state" => "due",
             "manual" => true,
             "scheduled_for" => DateTime.to_iso8601(DateTime.utc_now())
           }) do
      {:ok, event}
    end
  end

  # Where a job's fires go is read where its conversation is: it stays.
  defp fixed_conversation(%{"conversation_id" => held}, %{"conversation_id" => id})
       when id != held,
       do: {:error, {:jobs, {:invalid, "conversation_id"}}}

  defp fixed_conversation(_job, _input), do: :ok

  defp create(conn, name, fields, state, from, origin, config) do
    with :ok <- Fields.name(name),
         :ok <-
           if(state in ~w(proposed active), do: :ok, else: {:error, {:jobs, {:invalid, "state"}}}),
         {:ok, jobs} <- fold(conn),
         live = jobs |> Map.values() |> Enum.reject(&(&1["state"] == "archived")),
         :ok <-
           if(Enum.any?(live, &(&1["name"] == name)),
             do: {:error, {:jobs, {:name_taken, name}}},
             else: :ok
           ),
         :ok <-
           if(length(live) >= config.jobs.max_jobs,
             do: {:error, {:jobs, {:too_many, config.jobs.max_jobs}}},
             else: :ok
           ),
         :ok <- conversation(conn, fields["conversation_id"]) do
      body =
        fields
        |> Map.merge(%{
          "op" => "create",
          "id" => Id.new(),
          "name" => name,
          "state" => state,
          "version" => 1
        })
        |> then(&if(from, do: Map.put(&1, "from", from), else: &1))

      job_event(conn, origin, body)
    end
  end

  defp conversation(_conn, nil), do: :ok

  defp conversation(conn, id) do
    case Query.one(conn, "SELECT 1 AS found FROM conversations WHERE id = ?", [id]) do
      {:ok, %{found: 1}} -> :ok
      {:ok, nil} -> {:error, {:jobs, {:unknown_conversation, id}}}
      error -> error
    end
  end

  # The owner a create names, or its author: who a fire acts as.
  defp owner(nil, %{"author" => %{"kind" => "harness"}}), do: {:error, {:jobs, :no_owner}}
  defp owner(nil, %{"author" => author}), do: {:ok, author}

  defp owner(named, %{"author" => %{"kind" => "agent"} = author, "request_id" => nil}),
    do: if(named == author, do: {:ok, named}, else: {:error, {:jobs, :owner_not_self}})

  defp owner(named, _origin), do: {:ok, named}

  defp move(job, to) do
    if to in Map.get(@moves, job["state"], []),
      do: {:ok, to},
      else: {:error, {:jobs, {:state, job["state"], to}}}
  end

  defp job_event(conn, origin, body) do
    Events.append(conn, %{
      type: "job",
      request_id: origin["request_id"],
      run_id: origin["run_id"],
      body: Jason.encode!(Map.put(body, "origin", origin))
    })
  end

  @doc """
  Moves the job named `ref` to the state `to` with the `reason`, as the
  scheduler does to end a job or pause it: its author is the harness unless
  `ctx` names another. The moves are `proposed` to `active` or `archived`,
  `active` and `paused` to each other, to `ended` or to `archived`, and `ended` to
  `archived`.
  """
  @spec transition(Connection.t(), String.t(), String.t(), String.t() | nil, map) ::
          {:ok, map} | {:error, term}
  def transition(conn, ref, to, reason, ctx \\ %{author: "harness"}) do
    Events.with_actor(conn, ctx, fn ->
      with {:ok, author} <- author(ctx),
           origin = %{
             "author" => author,
             "channel" => "scheduler",
             "request_id" => nil,
             "run_id" => nil
           },
           do:
             operate(
               conn,
               "transition",
               %{"job" => ref, "to" => to, "reason" => reason},
               origin,
               nil
             )
    end)
  end

  @doc """
  Records the state a fire reaches, as the scheduler's own event. A fire
  begins `due`, with its `scheduled_for` (an instant, one that no fire of
  the job has taken, or `manual` for a fire that is no slot) and gets its
  `fire_id`; each later state names that `fire_id` and follows the last:

      due -> skipped | missed | late | running | cancelled
      late -> running | missed | skipped | cancelled
      running -> succeeded | failed | cancelled

  `skipped` (the condition said no, no model spent), `missed`, `succeeded`,
  `failed` and `cancelled` finish a fire; `late` is a mark on one that goes
  on. A fire may carry `conversation_id`, `run_ids`, and, on the state that
  finishes it, `duration_ms`, `calls`, `input_tokens`, `output_tokens`,
  `usd`, a `reason` and, for a job that delivers, the final reply as `message`; the job's totals add those up. Returns the event's
  body, with the `fire_id` and the job's `version` the fire runs.
  """
  @spec record_fire(Connection.t(), String.t(), map) :: {:ok, map} | {:error, term}
  def record_fire(conn, ref, attrs) do
    Events.with_actor(conn, %{author: "harness"}, fn ->
      with {:ok, job} <- find(conn, ref),
           {:ok, _event, fire} <- fire(conn, job, attrs),
           do: {:ok, fire}
    end)
  end

  defp fire(conn, job, attrs) do
    with {:ok, attrs} <- fire_attrs(attrs),
         {:ok, fire} <- fire_state(conn, job, attrs),
         {:ok, event} <- Events.append(conn, %{type: "job_fire", body: Jason.encode!(fire)}) do
      {:ok, event, fire}
    end
  end

  defp fire_attrs(attrs) do
    case Enum.find(attrs, fn {key, value} -> not fire_value?(key, value) end) do
      nil when is_map_key(attrs, "state") -> {:ok, attrs}
      nil -> {:error, {:jobs, {:invalid, "state"}}}
      {key, _value} -> {:error, {:jobs, {:invalid, key}}}
    end
  end

  defp fire_value?("state", value), do: value in fire_states()
  defp fire_value?("fire_id", value), do: is_binary(value)
  defp fire_value?("manual", value), do: value == true
  defp fire_value?("run_ids", value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp fire_value?(key, value) when key in ~w(conversation_id reason message),
    do: is_binary(value)

  defp fire_value?("usd", value), do: is_number(value) and value >= 0
  defp fire_value?(key, value) when key in @counters, do: is_integer(value) and value >= 0

  defp fire_value?("scheduled_for", value),
    do: is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp fire_value?(_key, _value), do: false

  # A new fire starts `due` on a slot; a later state follows the fire's last.
  defp fire_state(conn, job, %{"state" => "due"} = attrs) when not is_map_key(attrs, "fire_id") do
    with :ok <- slot_free(conn, job, attrs) do
      {:ok,
       Map.merge(attrs, %{"id" => job["id"], "fire_id" => Id.new(), "version" => job["version"]})}
    end
  end

  defp fire_state(_conn, _job, attrs) when not is_map_key(attrs, "fire_id"),
    do: {:error, {:jobs, {:invalid, "fire_id"}}}

  defp fire_state(conn, job, %{"fire_id" => fire_id, "state" => state} = attrs) do
    with {:ok, row} <-
           Query.one(
             conn,
             "SELECT json_extract(body, '$.id') AS id, json_extract(body, '$.state') AS state, json_extract(body, '$.version') AS version FROM events WHERE type = 'job_fire' AND json_extract(body, '$.fire_id') = ? ORDER BY sequence DESC LIMIT 1",
             [fire_id]
           ) do
      cond do
        is_nil(row) or row.id != job["id"] ->
          {:error, {:jobs, {:unknown_fire, fire_id}}}

        state in Map.get(@fire_moves, row.state, []) ->
          {:ok, Map.merge(attrs, %{"id" => job["id"], "version" => row.version})}

        true ->
          {:error, {:jobs, {:fire_state, row.state, state}}}
      end
    end
  end

  defp slot_free(_conn, _job, %{"manual" => true}), do: :ok

  defp slot_free(_conn, _job, attrs) when not is_map_key(attrs, "scheduled_for"),
    do: {:error, {:jobs, {:invalid, "scheduled_for"}}}

  defp slot_free(conn, job, %{"scheduled_for" => slot}) do
    with {:ok, row} <-
           Query.one(
             conn,
             "SELECT 1 AS taken FROM events WHERE type = 'job_fire' AND json_extract(body, '$.id') = ? AND json_extract(body, '$.state') = 'due' AND json_extract(body, '$.manual') IS NULL AND json_extract(body, '$.scheduled_for') = ?",
             [job["id"], slot]
           ) do
      if row, do: {:error, {:jobs, {:slot_taken, slot}}}, else: :ok
    end
  end

  ## Origin

  # Who a write is by, how it came and what approved it, kept in its event.
  defp origin(conn, op, body, ctx) do
    with {:ok, author} <- author(ctx),
         {:ok, channel, request_id} <- channel(conn, op, body, ctx, author) do
      {:ok,
       %{
         "author" => author,
         "channel" => channel,
         "request_id" => request_id,
         "run_id" => ctx.run_id,
         "work_id" => ctx.work_id,
         "conversation_id" => Map.get(ctx, :conversation_id)
       }}
    end
  end

  defp author(%{author: "harness"}), do: {:ok, %{"kind" => "harness"}}

  defp author(ctx) do
    case Participant.from_context(ctx) do
      {:ok, identity} -> {:ok, identity}
      {:error, _reason} -> {:error, {:jobs, :no_author}}
    end
  end

  defp channel(conn, op, body, ctx, author) do
    case {body["request_id"], author["kind"]} do
      {nil, "agent"} -> unapproved(op, ctx)
      {nil, _human} -> named_channel(body["channel"])
      {request_id, _kind} -> approved(conn, request_id)
    end
  end

  defp unapproved("create", %{config: %{jobs: %{agent_may_create: true}}}), do: {:ok, "tool", nil}
  defp unapproved("create", _ctx), do: {:error, {:jobs, :approval_required}}
  defp unapproved(_op, _ctx), do: {:error, {:jobs, :agent_creates_only}}

  defp named_channel(nil), do: {:ok, "cli", nil}
  defp named_channel(channel) when channel in @channels, do: {:ok, channel, nil}
  defp named_channel(_channel), do: {:error, {:jobs, {:invalid, "channel"}}}

  # An approval is a closed request whose chosen option calls `jobs`.
  defp approved(conn, request_id) do
    with {:ok, request} <- View.view(conn, "request", request_id),
         %{status: "closed", answer: "approve", options: options} <- request,
         [_ | _] = calls <- Jason.decode!(options)["approve"],
         true <- Enum.any?(calls, &(&1["name"] == "jobs")) do
      {:ok, "proposal", request_id}
    else
      _ -> {:error, {:jobs, {:not_approved, request_id}}}
    end
  end

  # A run a fire opened has `via = "job"`; so does any run below it, which
  # `cause_id` links to the event of the run above.
  defp outside_fires(_conn, nil), do: :ok

  defp outside_fires(conn, run_id) do
    with {:ok, row} <-
           Query.one(
             conn,
             """
             WITH RECURSIVE chain(via, cause_id) AS (
               SELECT via, cause_id FROM runs WHERE id = ?
               UNION ALL
               SELECT runs.via, runs.cause_id FROM runs
               JOIN events ON events.run_id = runs.id
               JOIN chain ON chain.cause_id = events.id)
             SELECT 1 AS fired FROM chain WHERE via = 'job' LIMIT 1
             """,
             [run_id]
           ) do
      if row, do: {:error, {:jobs, :in_fire}}, else: :ok
    end
  end
end
