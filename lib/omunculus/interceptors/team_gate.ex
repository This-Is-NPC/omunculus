defmodule Omunculus.Interceptors.TeamGate do
  @moduledoc """
  Rejects `task.delegated` and `task.requested` deliveries when the payload
  names a team or agent that is not valid for the configured session.
  """
  @behaviour Omunculus.Interceptor

  alias Omunculus.EventCore.Store

  @impl true
  def intercept(%{type: "task.delegated", payload: payload} = env, options) do
    conn = fetch_opt(options, :conn)
    source = if conn, do: Omunculus.Discovery.run(conn, env.run_id), else: nil
    options = Map.merge((source || %{})["discovery"] || %{}, options)
    team = payload["team"]
    agent = payload["agent"]

    with :ok <- validate_team(team, env, payload, options),
         :ok <- validate_agent(agent, team, options) do
      :deliver
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  def intercept(%{type: "task.requested", payload: %{"requested_by" => _}} = env, options) do
    conn = fetch_opt(options, :conn)
    source = if conn, do: Omunculus.Discovery.run(conn, env.run_id), else: nil
    options = Map.merge((source || %{})["discovery"] || %{}, options)
    payload = env.payload
    team = payload["team"] || (source || %{})["team"]
    agent = payload["agent"]

    with :ok <- validate_requester_authority(env, options),
         :ok <- validate_team(team, env, payload, options),
         :ok <- validate_agent(agent, team, options),
         :ok <- validate_workspace(payload, source, options),
         :ok <- validate_target_present(payload),
         :ok <- Omunculus.Discovery.validate_scope(fetch_opt(options, :conn), env) do
      :deliver
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  def intercept(%{type: "task.requested", payload: payload} = env, options) do
    case payload["team"] do
      team when is_binary(team) and team != "" ->
        case validate_team(team, env, payload, options) do
          :ok -> :deliver
          {:error, reason} -> {:reject, reason}
        end

      _ ->
        :deliver
    end
  end

  def intercept(_envelope, _options), do: :deliver

  defp validate_workspace(payload, source, options) do
    workspaces = fetch_opt(options, :workspaces) || %{}
    workspace = payload["workspace"] || (source || %{})["workspace"]

    if workspaces != %{} and not Map.has_key?(workspaces, workspace),
      do: {:error, "workspace not in session"},
      else: :ok
  end

  defp validate_target_present(payload) do
    if target_present?(payload),
      do: :ok,
      else: {:error, "request_work requires workspace, team, or agent"}
  end

  defp target_present?(payload) do
    Enum.any?(["workspace", "team", "agent"], fn key ->
      case payload[key] do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end
    end)
  end

  defp validate_requester_authority(env, options) do
    conn = fetch_opt(options, :conn)

    if conn && requester_has_request_work?(conn, env) do
      :ok
    else
      {:error, "requester lacks request_work authority"}
    end
  end

  defp requester_has_request_work?(conn, env) do
    run_id = env.run_id || parse_run_id(env.payload["requested_by"])

    with run_id when is_binary(run_id) <- run_id,
         [[payload_json]] <-
           Store.query(
             conn,
             "SELECT payload FROM EVENTS WHERE run_id = ? AND type = 'run.started' ORDER BY sequence DESC LIMIT 1",
             [run_id]
           ),
         %{"tools" => tools} <- Jason.decode!(payload_json) do
      granted = Map.get(tools, "granted", [])
      Omunculus.Permission.tool_allowed?(conn, env.work_item_id, "request_work", granted)
    else
      _ -> false
    end
  end

  defp parse_run_id("run:" <> run_id), do: run_id
  defp parse_run_id(run_id) when is_binary(run_id), do: run_id
  defp parse_run_id(_), do: nil

  defp validate_team(team, env, payload, options) when is_binary(team) and team != "" do
    teams_map = fetch_opt(options, :teams) || %{}
    workspaces_map = fetch_opt(options, :workspaces) || %{}

    cond do
      not team_known?(teams_map, team) and team != "default" ->
        {:error, "team not in session"}

      workspaces_map != %{} and not team_in_workspace?(team, env, payload, workspaces_map) ->
        {:error, "team not in workspace"}

      true ->
        :ok
    end
  end

  defp validate_team(_team, _env, _payload, _options), do: :ok

  defp validate_agent(agent, team, options) when is_binary(agent) and agent != "" do
    agents = Map.merge(Omunculus.Runtime.Agents.defaults(), fetch_opt(options, :agents) || %{})
    teams = fetch_opt(options, :teams) || %{}

    cond do
      not Map.has_key?(agents, agent) ->
        {:error, "agent not in session"}

      team in [nil, "", "default"] and teams == %{} ->
        :ok

      true ->
        case lookup_team(teams, team) do
          nil ->
            {:error, "agent without team"}

          spec ->
            members = fetch_field(spec, :members) || []
            allowed = if members == [], do: [fetch_field(spec, :lead)], else: members
            if agent in allowed, do: :ok, else: {:error, "agent not in team"}
        end
    end
  end

  defp validate_agent(_agent, _team, _options), do: :ok

  defp team_known?(teams_map, team), do: lookup_team(teams_map, team) != nil

  defp lookup_team(teams_map, team) do
    Enum.find_value(teams_map, fn {key, spec} ->
      if to_string(key) == team, do: spec
    end)
  end

  defp team_in_workspace?(team, env, payload, workspaces_map) do
    case resolve_workspace(env, payload, workspaces_map) do
      nil ->
        true

      ws_key ->
        ws = lookup_workspace(workspaces_map, ws_key)
        ws_teams = if ws, do: fetch_field(ws, :teams) || [], else: []

        ws_teams == [] or team in ws_teams or team == "default"
    end
  end

  defp resolve_workspace(env, payload, workspaces_map) do
    cond do
      is_binary(payload["workspace"]) and payload["workspace"] != "" ->
        payload["workspace"]

      is_binary(env.workspace_id) and env.workspace_id != "" ->
        env.workspace_id

      map_size(workspaces_map) == 1 ->
        workspaces_map |> Map.keys() |> hd() |> to_string()

      true ->
        nil
    end
  end

  defp lookup_workspace(workspaces_map, ws_key) do
    Enum.find_value(workspaces_map, fn {key, spec} ->
      if to_string(key) == ws_key, do: spec
    end)
  end

  defp fetch_opt(options, key) when is_atom(key) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key))
  end

  defp fetch_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
