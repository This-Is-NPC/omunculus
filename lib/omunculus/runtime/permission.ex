defmodule Omunculus.Runtime.Permission do
  @moduledoc false

  alias Omunculus.{Config, EventCore, Policy}
  alias Omunculus.Event.Envelope

  def arbiter(tool, bands, parent_bands, depth) do
    human = bands["human"] || []
    negotiable = bands["negotiable"] || []
    forbidden = bands["forbidden"] || []
    parent_allowed = (parent_bands["granted"] || []) ++ (parent_bands["negotiable"] || [])

    cond do
      tool in forbidden ->
        :forbidden

      tool in human ->
        "human"

      tool in negotiable and depth > 0 and tool in parent_allowed ->
        "parent"

      tool in negotiable and depth == 0 ->
        "human"

      tool in negotiable ->
        :forbidden

      true ->
        :forbidden
    end
  end

  def parent_bands_from_log(core, work_item_id) do
    parent =
      case EventCore.query(
             core,
             "SELECT parent_work_item_id FROM WORK_ITEMS WHERE work_item_id = ?",
             [work_item_id]
           ) do
        [[pid]] when is_binary(pid) -> pid
        _ -> nil
      end

    with parent when is_binary(parent) <- parent,
         %Envelope{payload: payload} <-
           EventCore.stream(core, 0, work_item_id: parent, type: "run.started") |> List.last() do
      payload["tools"] || %{"granted" => [], "negotiable" => [], "human" => [], "forbidden" => []}
    else
      _ -> %{"granted" => [], "negotiable" => [], "human" => [], "forbidden" => []}
    end
  end

  def waiting_for_request(core, request_id) do
    rows =
      EventCore.query(
        core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE status IN ('waiting', 'running')",
        []
      )

    Enum.flat_map(rows, fn [wi, awaiting_json] ->
      case decode_awaiting(awaiting_json) do
        ids when is_list(ids) ->
          if request_id in ids, do: [{wi, request_id}], else: []

        _ ->
          []
      end
    end)
  end

  def waiting_for_policy(core) do
    rows =
      EventCore.query(
        core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE status IN ('waiting', 'running')",
        []
      )

    Enum.flat_map(rows, fn [wi, awaiting_json] ->
      case decode_awaiting(awaiting_json) do
        ids when is_list(ids) ->
          if "policy" in ids, do: [wi], else: []

        _ ->
          []
      end
    end)
  end

  def open_permission_requests(core) do
    EventCore.stream(core, 0, type: "permission.requested")
    |> Enum.reject(&resolved_request?(core, &1.payload["request_id"]))
  end

  def resolved_request?(core, request_id) when is_binary(request_id) do
    EventCore.stream(core, 0)
    |> Enum.any?(fn
      %{type: "permission.granted", payload: %{"request_id" => id}} -> id == request_id
      %{type: "permission.denied", payload: %{"request_id" => id}} -> id == request_id
      _ -> false
    end)
  end

  def tool_granted_by_policy?(config, spec, tool) do
    with {:ok, loaded} <- load_config(config),
         table when is_map(table) <- Policy.table(loaded),
         profile <- spec_profile(spec, config, loaded),
         workspace <- spec_workspace(spec, loaded),
         depth <- to_string(spec[:depth] || spec["depth"] || 0),
         {:ok, bands} <- Policy.line(table, profile, depth, workspace) do
      tool in (bands["granted"] || [])
    else
      _ -> false
    end
  end

  def observation(%{type: "permission.granted"}), do: "edit granted for this task"

  def observation(%{type: "permission.denied", payload: payload}) do
    "denied: #{payload["reason"]}"
  end

  def resolution_observation(core, request_id) when is_binary(request_id) do
    case resolution_event(core, request_id) do
      nil -> ""
      env -> observation(env)
    end
  end

  def permission_request_id?(id) when is_binary(id), do: String.starts_with?(id, "req_")
  def permission_request_id?(_), do: false

  defp resolution_event(core, request_id) do
    EventCore.stream(core, 0)
    |> Enum.find(fn
      %{type: type, payload: %{"request_id" => id}}
      when type in ["permission.granted", "permission.denied"] and id == request_id ->
        true

      _ ->
        false
    end)
  end

  defp spec_profile(_spec, config, loaded) do
    config[:profile] || loaded.defaults.preset || "coding"
  end

  defp spec_workspace(spec, loaded) do
    spec[:workspace] || spec.activation.payload["workspace"] ||
      case Map.keys(loaded.workspaces) do
        [only] -> only
        keys -> Enum.at(keys, 0, "default")
      end
  end

  defp load_config(config) when is_map(config) do
    Config.load(
      cwd: config[:cwd] || File.cwd!(),
      config_file: config[:config_file],
      env: config[:env] || %{}
    )
  end

  defp decode_awaiting(nil), do: nil
  defp decode_awaiting(""), do: nil
  defp decode_awaiting(ids) when is_list(ids), do: ids

  defp decode_awaiting(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, ids} -> ids
      _ -> nil
    end
  end
end
