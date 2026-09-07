defmodule Omunculus.Interceptors.WorkspaceGate do
  @moduledoc """
  Rejects `task.requested` and `task.delegated` deliveries whose workspace
  is not attached to the session or is listed in `deny_targets`.
  """
  @behaviour Omunculus.Interceptor

  alias Omunculus.EventCore.Store

  @attached_sql """
  SELECT workspace_id FROM SESSION_WORKSPACES WHERE attached = 1
  """

  @impl true
  def intercept(%{type: "task.requested", payload: payload}, options) do
    attached = attached_list(options)
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
    attached = attached_list(options)
    workspace = payload["workspace"] || env.workspace_id

    with :ok <- check_deny_targets(workspace, options),
         :ok <- check_attached(workspace, attached, "workspace not in session") do
      :deliver
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  def intercept(_envelope, _options), do: :deliver

  defp attached_list(options) do
    from_options = normalize_attached(fetch_opt(options, :attached))
    from_conn = attached_from_conn(options)
    Enum.uniq(from_options ++ from_conn)
  end

  defp attached_from_conn(options) do
    conn = options[:conn] || options["conn"]

    if conn do
      try do
        Store.query(conn, @attached_sql, [])
        |> Enum.map(fn [ws_id] -> ws_id end)
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      []
    end
  end

  defp check_deny_targets(workspace, options) when is_binary(workspace) and workspace != "" do
    deny = normalize_attached(fetch_opt(options, :deny_targets))

    if workspace in deny, do: {:error, "workspace denied"}, else: :ok
  end

  defp check_deny_targets(_workspace, _options), do: :ok

  defp check_attached(workspace, attached, message)
       when is_binary(workspace) and workspace != "" do
    if attached != [] and workspace not in attached,
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
