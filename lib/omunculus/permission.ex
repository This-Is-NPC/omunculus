defmodule Omunculus.Permission do
  @moduledoc false

  alias Omunculus.EventCore.Store
  alias Omunculus.Events

  @parent_sql "SELECT parent_work_item_id FROM WORK_ITEMS WHERE work_item_id = ?"
  @status_sql "SELECT status FROM WORK_ITEMS WHERE work_item_id = ?"

  @events_sql """
  SELECT type, payload, sequence FROM EVENTS
  WHERE work_item_id = ? AND type IN ('permission.requested', 'permission.granted', 'permission.denied', 'permission.revoked')
  ORDER BY sequence
  """

  def grant_root(conn, work_item_id) do
    Events.grant_root_work_item_id(conn, work_item_id)
  end

  def request_id(conn, work_item_id, tool) do
    Events.request_id(grant_root(conn, work_item_id), tool)
  end

  def tool_allowed?(conn, work_item_id, tool, pinned_granted) when is_list(pinned_granted) do
    tool in pinned_granted or lineage_granted?(conn, work_item_id, tool)
  end

  def active_lineage_tools(conn, work_item_id) do
    ancestor_chain(conn, work_item_id)
    |> Enum.flat_map(&requested_tools_for(conn, &1))
    |> Enum.uniq()
    |> Enum.filter(&lineage_granted?(conn, work_item_id, &1))
  end

  def already_granted?(conn, work_item_id, tool, policy_granted) when is_list(policy_granted) do
    tool in policy_granted or lineage_granted?(conn, work_item_id, tool)
  end

  def denied_for_task?(conn, work_item_id, tool) do
    match?({:ok, _}, denied_reason(conn, work_item_id, tool))
  end

  def denied_reason(conn, work_item_id, tool) do
    request_id = request_id(conn, work_item_id, tool)

    case latest_resolution(conn, request_id) do
      {:denied, %{"reason" => reason}} when is_binary(reason) -> {:ok, reason}
      {:denied, payload} when is_map(payload) -> {:ok, payload["reason"] || "denied"}
      _ -> :error
    end
  end

  def open_request_id?(conn, work_item_id, tool) do
    request_id = request_id(conn, work_item_id, tool)

    case latest_resolution(conn, request_id) do
      :open -> true
      _ -> false
    end
  end

  def lineage_granted?(conn, work_item_id, tool) do
    ancestor_chain(conn, work_item_id)
    |> Enum.any?(fn wi ->
      root = grant_root(conn, wi)
      request_id = Events.request_id(root, tool)
      active_temporary_grant?(conn, root, request_id)
    end)
  end

  defp active_temporary_grant?(conn, requester_wi, request_id) do
    requester_open?(conn, requester_wi) and
      case latest_grant(conn, request_id) do
        {:temporary, seq} -> not revoked_after?(conn, request_id, seq)
        _ -> false
      end
  end

  defp requested_tools_for(conn, work_item_id) do
    Store.query(conn, @events_sql, [work_item_id])
    |> Enum.flat_map(fn
      ["permission.requested", payload_json, _seq] ->
        payload = Jason.decode!(payload_json)
        [payload["tool"]]

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ancestor_chain(conn, work_item_id) do
    [work_item_id | parent_ancestors(conn, work_item_id)]
  end

  defp parent_ancestors(conn, work_item_id) do
    case parent_work_item_id(conn, work_item_id) do
      nil -> []
      parent -> [parent | parent_ancestors(conn, parent)]
    end
  end

  defp parent_work_item_id(conn, work_item_id) do
    case Store.query(conn, @parent_sql, [work_item_id]) |> List.last() do
      [parent] when is_binary(parent) -> parent
      _ -> nil
    end
  end

  defp requester_open?(conn, work_item_id) do
    case Store.query(conn, @status_sql, [work_item_id]) |> List.last() do
      ["completed"] -> false
      _ -> true
    end
  end

  defp latest_resolution(conn, request_id) do
    events = permission_events_for_request(conn, request_id)

    Enum.reduce(events, :open, fn
      ["permission.granted", payload_json, _seq], _acc ->
        payload = Jason.decode!(payload_json)

        if payload["kind"] == "temporary" do
          {:granted, :temporary}
        else
          {:granted, :permanent}
        end

      ["permission.denied", payload_json, _seq], acc ->
        if acc == :open, do: {:denied, Jason.decode!(payload_json)}, else: acc

      ["permission.revoked", _payload_json, _seq], {:granted, _} ->
        :open

      _, acc ->
        acc
    end)
  end

  defp latest_grant(conn, request_id) do
    events = permission_events_for_request(conn, request_id)

    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      ["permission.granted", payload_json, seq] ->
        payload = Jason.decode!(payload_json)

        if payload["kind"] == "temporary" do
          {:temporary, seq}
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp revoked_after?(conn, request_id, grant_seq) do
    permission_events_for_request(conn, request_id)
    |> Enum.any?(fn
      ["permission.revoked", _payload, seq] -> seq > grant_seq
      _ -> false
    end)
  end

  defp permission_events_for_request(conn, request_id) do
    Store.query(
      conn,
      """
      SELECT type, payload, sequence FROM EVENTS
      WHERE type IN ('permission.granted', 'permission.denied', 'permission.revoked')
        AND json_extract(payload, '$.request_id') = ?
      ORDER BY sequence
      """,
      [request_id]
    )
  end
end
