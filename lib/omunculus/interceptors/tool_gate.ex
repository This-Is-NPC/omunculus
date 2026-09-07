defmodule Omunculus.Interceptors.ToolGate do
  @moduledoc """
  Rejects `tool.call.requested` deliveries whose tool is not in the Run's
  pinned granted list from `run.started` and has no active temporary lineage grant.

  Reads `run.started` through the Event Core store connection passed in
  interceptor options (`:conn`), never through `EventCore.stream/3`, so the
  lane stays deadlock-free while running inside `handle_call {:append, _}`.
  """
  @behaviour Omunculus.Interceptor

  alias Omunculus.EventCore.Store
  alias Omunculus.Permission

  @run_started_sql """
  SELECT payload FROM EVENTS
  WHERE type = 'run.started' AND run_id = ?
  ORDER BY sequence
  """

  @impl true
  def intercept(
        %{type: "tool.call.requested", payload: %{"tool" => tool}, run_id: run_id} = env,
        options
      )
      when is_binary(run_id) do
    conn = options[:conn] || options["conn"]
    work_item_id = env.work_item_id

    cond do
      is_nil(conn) ->
        {:reject, "no store connection"}

      match?({:error, :no_run_started}, pinned_granted(conn, run_id)) ->
        {:reject, "no run.started for run"}

      {:ok, granted} = pinned_granted(conn, run_id) ->
        if Permission.tool_allowed?(conn, work_item_id, tool, granted),
          do: :deliver,
          else: {:reject, "tool not in pinned granted"}
    end
  end

  def intercept(_envelope, _options), do: :deliver

  defp pinned_granted(conn, run_id) do
    case Store.query(conn, @run_started_sql, [run_id]) |> List.last() do
      nil ->
        {:error, :no_run_started}

      [payload_json] ->
        payload = Jason.decode!(payload_json)
        granted = get_in(payload, ["tools", "granted"]) || []
        {:ok, granted}
    end
  end
end
