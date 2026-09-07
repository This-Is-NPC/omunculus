defmodule Omunculus.Interceptors.TeamGate do
  @moduledoc """
  Rejects `task.delegated` and `task.requested` deliveries when the payload
  names a team or agent that is not valid for the configured session.
  """
  @behaviour Omunculus.Interceptor

  alias Omunculus.EventCore.Store

  @impl true
  def intercept(%{type: "task.delegated", payload: payload} = env, options) do
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
    payload = env.payload
    team = payload["team"]
    agent = payload["agent"]

    with :ok <- validate_requester_authority(env, options),
         :ok <- validate_team(team, env, payload, options),
         :ok <- validate_agent(agent, team, options),
         :ok <- validate_target_present(payload) do
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
      negotiable = Map.get(tools, "negotiable", [])
      "request_work" in granted or "request_work" in negotiable
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
      teams_map != %{} and not team_known?(teams_map, team) and team != "default" ->
        {:error, "team not in session"}

      workspaces_map != %{} and not team_in_workspace?(team, env, payload, workspaces_map) ->
        {:error, "team not in workspace"}

      true ->
        :ok
    end
  end

  defp validate_team(_team, _env, _payload, _options), do: :ok

  defp validate_agent(agent, team, options) when is_binary(agent) and agent != "" do
    if is_binary(team) and team != "" do
      case lookup_team(fetch_opt(options, :teams) || %{}, team) do
        nil ->
          :ok

        team_spec ->
          members = fetch_field(team_spec, :members) || []
          lead = fetch_field(team_spec, :lead)

          cond do
            members != [] and agent not in members ->
              {:error, "agent not in team"}

            members == [] and agent != lead ->
              {:error, "agent not in team"}

            true ->
              :ok
          end
      end
    else
      {:error, "agent without team"}
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
