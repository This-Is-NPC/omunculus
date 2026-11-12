defmodule Omunculus.Server.Contract do
  @moduledoc "The versioned public representation of project state and events."

  @version 1

  @doc "The states a work is in, as the store keeps them."
  @spec work_states() :: [String.t()]
  def work_states, do: ~w(open waiting done cancelled)

  defp cursor(nil), do: nil
  defp cursor(sequence), do: Base.url_encode64(<<sequence::unsigned-64>>, padding: false)

  @spec decode_cursor(String.t() | nil) :: {:ok, non_neg_integer} | {:error, :invalid}
  def decode_cursor(nil), do: {:ok, 0}

  def decode_cursor(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<sequence::unsigned-64>>} -> {:ok, sequence}
      _ -> {:error, :invalid}
    end
  end

  def decode_cursor(_), do: {:error, :invalid}

  @doc "The versions of a conversation's artifacts, grouped by artifact."
  @spec artifacts([map]) :: [map]
  def artifacts(versions) do
    versions
    |> Omunculus.Artifacts.group()
    |> Enum.map(fn artifact ->
      Map.update!(artifact, "versions", fn versions ->
        Enum.map(versions, &Map.take(&1, ~w(version media_type bytes sha256 note at by work_id)))
      end)
    end)
  end

  @spec event(String.t(), map) :: map
  def event(project_id, event) do
    %{
      v: @version,
      cursor: cursor(event.sequence),
      project: project_id,
      conversation_id: event.conversation_id,
      type: event.type,
      at: event.at,
      actor: actor(event),
      origin: origin(event),
      run_id: event.run_id,
      work_id: event.work_id,
      request_id: event.request_id,
      released_by: event.released_by,
      inbox_id: event.inbox_id,
      prompt_id: event.prompt_id,
      comment_id: event.comment_id,
      body: body(event.body)
    }
  end

  @spec delta(String.t(), map) :: map
  def delta(project_id, delta) do
    %{
      v: @version,
      project: project_id,
      type: "run.delta",
      conversation_id: delta.conversation_id,
      run_id: delta.run_id,
      work_id: delta.work_id,
      text: delta.text
    }
  end

  @spec item(atom, map) :: map
  def item(:works, row),
    do:
      Map.take(
        row,
        ~w(id conversation_id parent_id workspace assignee title goal workflow stage state waiting created_at updated_at)a
      )

  def item(:runs, row),
    do:
      Map.take(
        row,
        ~w(id work_id agent depth via request_id status started_at finished_at origin_issuer origin_subject)a
      )

  def item(:prompts, row),
    do: Map.take(row, ~w(id kind body subject run_id created_at actor_issuer actor_subject)a)

  def item(:requests, row) do
    row
    |> Map.take(
      ~w(id run_id requester work_id options arbiter status created_at reason workflow stage origins interception)a
    )
    |> Map.update!(:options, &body/1)
    |> Map.update!(:requester, &body/1)
    |> Map.update!(:arbiter, &body/1)
    |> Map.update(:interception, nil, &interception/1)
    |> Map.update(
      :origins,
      %{},
      &Map.new(&1, fn {part, origin} -> {part, item(:requests, origin)} end)
    )
  end

  def item(:inbox, row),
    do: Map.take(row, ~w(id run_id agent work_id read_at created_at)a)

  defp interception(nil), do: nil

  defp interception(review),
    do: %{
      action: review.action,
      summary: review.summary,
      target: Omunculus.Store.Interception.target_label(review.target),
      args: Omunculus.Store.Interception.lines(review.emit),
      files: Omunculus.Store.Interception.files(review.emit),
      level: review.level,
      under: review.under,
      step: review.step + 1,
      of: length(review.reviewers)
    }

  def member(row), do: Map.take(row, ~w(issuer subject role updated_at)a)

  @doc """
  Usage per agent and per work, from the model `calls` of `Access.usage/3`.
  Each call is priced by the model it used, or by its agent's configured
  model in `models` when the reply names none; `prices` maps a model to its
  price or nil. An entry holds the totals, its `usd` (nil when no call has a
  price), the `models` used and those `unpriced`. A work has `own`, its
  calls, with each call's model and `usd` in `calls`, and `branch`, with the
  works below it, `parents` mapping a work to its parent. Work "" is the
  calls made outside any work.
  """
  def usage(calls, parents, models, prices) do
    calls =
      for call <- calls do
        model = call.model || models[call.agent]
        price = prices[model]
        Map.merge(call, %{model: model, usd: price && Omunculus.Usage.spend(call.totals, price)})
      end

    agents =
      calls
      |> Enum.group_by(& &1.agent)
      |> Enum.sort()
      |> Enum.map(fn {agent, own} -> Map.put(entry(own), :agent, agent) end)

    own = Enum.group_by(calls, & &1.work)

    branch =
      Enum.reduce(calls, %{}, fn call, acc ->
        call.work
        |> lineage(parents)
        |> Enum.reduce(acc, fn id, acc -> Map.update(acc, id, [call], &[call | &1]) end)
      end)

    works =
      for {id, below} <- Enum.sort(branch) do
        mine = Map.get(own, id, [])

        %{
          work: id,
          own: entry(mine),
          branch: entry(Enum.reverse(below)),
          calls:
            for call <- mine do
              call.totals
              |> Map.take([:fresh, :cache_write, :cached, :output])
              |> Map.merge(%{model: call.model, usd: call.usd})
            end
        }
      end

    total = entry(calls)
    %{agents: agents, works: works, total: %{total | usd: total.usd || 0.0}}
  end

  # A work and its ancestors; "" has none.
  defp lineage("", _parents), do: [""]

  defp lineage(id, parents),
    do: [id | if(parents[id], do: lineage(parents[id], parents), else: [])]

  defp entry(calls) do
    priced = Enum.filter(calls, & &1.usd)

    calls
    |> Enum.map(& &1.totals)
    |> Omunculus.Usage.total()
    |> Map.merge(%{
      usd: if(priced == [], do: nil, else: Enum.reduce(priced, 0.0, &(&1.usd + &2))),
      models: calls |> Enum.map(& &1.model) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      unpriced:
        calls
        |> Enum.reject(& &1.usd)
        |> Enum.map(& &1.model)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    })
  end

  def conversation(row),
    do: Map.take(row, ~w(id created_at created_issuer created_subject)a)

  def accepted(result) do
    result
    |> Map.update!("cursor", &cursor/1)
    |> Map.put("status", "accepted")
  end

  def created(%{id: id, cursor: sequence}), do: %{id: id, cursor: cursor(sequence)}

  def snapshot(%{conversation: conversation, items: items, cursor: sequence}) do
    %{
      v: @version,
      conversation: conversation(conversation),
      cursor: cursor(sequence),
      works: Enum.map(items.works, &item(:works, &1)),
      runs: Enum.map(items.runs, &item(:runs, &1)),
      prompts: Enum.map(items.prompts, &item(:prompts, &1)),
      requests: Enum.map(items.requests, &item(:requests, &1)),
      inbox: Enum.map(items.inbox, &item(:inbox, &1))
    }
  end

  defp actor(%{actor_kind: "human"} = event),
    do: %{kind: "human", issuer: event.actor_issuer, subject: event.actor_subject}

  defp actor(%{actor_kind: "agent"} = event), do: %{kind: "agent", id: event.actor_id}
  defp actor(%{actor_kind: "harness"}), do: %{kind: "harness"}
  defp actor(_), do: nil

  defp origin(%{origin_issuer: issuer, origin_subject: subject})
       when is_binary(issuer) and is_binary(subject),
       do: %{issuer: issuer, subject: subject}

  defp origin(_), do: nil

  defp body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end
end
