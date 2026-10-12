defmodule Omunculus.Server.Contract do
  @moduledoc "The versioned public representation of project state and events."

  @version 1

  @spec cursor(non_neg_integer | nil) :: String.t() | nil
  def cursor(nil), do: nil
  def cursor(sequence), do: Base.url_encode64(<<sequence::unsigned-64>>, padding: false)

  @spec decode_cursor(String.t() | nil) :: {:ok, non_neg_integer} | {:error, :invalid}
  def decode_cursor(nil), do: {:ok, 0}

  def decode_cursor(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<sequence::unsigned-64>>} -> {:ok, sequence}
      _ -> {:error, :invalid}
    end
  end

  def decode_cursor(_), do: {:error, :invalid}

  @spec event(String.t(), map) :: map
  def event(project_id, event) do
    %{
      v: @version,
      cursor: cursor(event.sequence),
      project: project_id,
      type: event.type,
      at: event.at,
      actor: actor(event),
      origin: origin(event),
      run_id: event.run_id,
      work_id: event.work_id,
      request_id: event.request_id,
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
        ~w(id parent_id workspace assignee title goal stage state waiting created_at updated_at)a
      )

  def item(:runs, row),
    do:
      Map.take(
        row,
        ~w(id work_id agent depth via request_id status started_at finished_at origin_issuer origin_subject)a
      )

  def item(:prompts, row),
    do: Map.take(row, ~w(id kind body run_id created_at actor_issuer actor_subject)a)

  def item(:requests, row) do
    row
    |> Map.take(~w(id run_id requester work_id options arbiter status created_at)a)
    |> Map.update!(:options, &body/1)
    |> Map.update!(:requester, &body/1)
    |> Map.update!(:arbiter, &body/1)
  end

  def item(:inbox, row),
    do: Map.take(row, ~w(id run_id agent work_id read_at created_at)a)

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
