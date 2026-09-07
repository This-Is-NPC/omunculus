defmodule Omunculus.Discovery do
  @moduledoc "Shared discovery boundary for directory reads and cross-lineage requests."

  alias Omunculus.EventCore.Store

  def run(conn, run_id) do
    case Store.query(
           conn,
           "SELECT payload, workspace_id, session_id, work_item_id FROM EVENTS WHERE type = 'run.started' AND run_id = ? ORDER BY sequence DESC LIMIT 1",
           [run_id]
         ) do
      [[payload, workspace, session, wi]] ->
        payload = Jason.decode!(payload)

        Map.merge(payload, %{
          "workspace" => payload["workspace"] || workspace,
          "session_id" => session,
          "work_item_id" => wi
        })

      _ ->
        nil
    end
  end

  def work_item(conn, wi) do
    case Store.query(
           conn,
           "SELECT run_id FROM EVENTS WHERE type = 'run.started' AND work_item_id = ? ORDER BY sequence DESC LIMIT 1",
           [wi]
         ) do
      [[run_id]] -> run(conn, run_id)
      _ -> nil
    end
  end

  def visible?(%{"directory_scope" => "session"} = source, target) do
    source["session_id"] == target["session_id"]
  end

  def visible?(source, target) do
    source["session_id"] == target["session_id"] and
      source["workspace"] == target["workspace"] and
      (source["team"] || "default") == (target["team"] || "default")
  end

  def target(source, payload) do
    %{
      "session_id" => source["session_id"],
      "workspace" => payload["workspace"] || source["workspace"],
      "team" => payload["team"] || source["team"] || "default"
    }
  end

  def validate_scope(conn, env) do
    case run(conn, env.run_id) do
      nil ->
        {:error, "unknown requesting run"}

      source ->
        if visible?(source, target(source, env.payload)),
          do: :ok,
          else: {:error, "target outside discovery scope"}
    end
  end
end
