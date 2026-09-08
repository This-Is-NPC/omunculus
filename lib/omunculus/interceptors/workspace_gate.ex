defmodule Omunculus.Interceptors.WorkspaceGate do
  @moduledoc """
  Rejects `task.requested` and `task.delegated` deliveries whose workspace
  is not attached to the session or is listed in `deny_targets`.
  """
  @behaviour Omunculus.Interceptor

  alias Omunculus.EventCore.Store

  @impl true
  def intercept(%{type: "task.requested", payload: payload} = env, options) do
    attached = attached_list(options, env.session_id)
    workspace = payload["workspace"]

    with :ok <- check_deny_targets(workspace, options),
         :ok <- check_attached(workspace, attached, "workspace not attached") do
      :deliver
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  @impl true
  def intercept(%{type: "task.delegated", payload: payload} = env, options) do
    attached = attached_list(options, env.session_id)
    workspace = payload["workspace"] || env.workspace_id

    with :ok <- check_deny_targets(workspace, options),
         :ok <- check_attached(workspace, attached, "workspace not in session") do
      :deliver
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  def intercept(_envelope, _options), do: :deliver

  defp attached_list(options, session_id) do
    conn = fetch_opt(options, :conn)

    if conn do
      rows =
        Store.query(
          conn,
          """
          SELECT type, payload FROM EVENTS
          WHERE session_id IS ? AND type IN ('workspace.attached', 'workspace.detached') ORDER BY sequence
          """,
          [session_id]
        )

      if rows == [] do
        case if(session_id, do: [], else: normalize_attached(fetch_opt(options, :attached))) do
          [] -> if(session_id, do: [], else: :unrestricted)
          attached -> attached
        end
      else
        Enum.reduce(rows, MapSet.new(), fn [type, payload], attached ->
          workspace = Jason.decode!(payload)["workspace_id"]

          if type == "workspace.attached",
            do: MapSet.put(attached, workspace),
            else: MapSet.delete(attached, workspace)
        end)
        |> MapSet.to_list()
      end
    else
      case normalize_attached(fetch_opt(options, :attached)) do
        [] -> :unrestricted
        attached -> attached
      end
    end
  end

  defp check_deny_targets(workspace, options) when is_binary(workspace) and workspace != "" do
    deny = normalize_attached(fetch_opt(options, :deny_targets))

    if workspace in deny, do: {:error, "workspace denied"}, else: :ok
  end

  defp check_deny_targets(_workspace, _options), do: :ok

  defp check_attached(_workspace, :unrestricted, _message), do: :ok

  defp check_attached(workspace, attached, message)
       when is_binary(workspace) and workspace != "" do
    if workspace not in attached,
      do: {:error, message},
      else: :ok
  end

  defp check_attached(_workspace, _attached, _message), do: :ok

  defp normalize_attached(nil), do: []
  defp normalize_attached(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp fetch_opt(options, key) when is_atom(key) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key))
  end
end
