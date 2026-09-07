defmodule Omunculus.Tools.Directory do
  @moduledoc false
  @behaviour Omunculus.Tool

  alias Omunculus.EventCore.Store
  alias Omunculus.Tool.Context

  @impl true
  def name, do: "directory"

  @impl true
  def schema do
    %{
      "name" => "directory",
      "description" =>
        "Read-only discovery of workspaces, teams, agents, open work items, and comment results in the session projection.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Optional filter for work items or comments"
          }
        },
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(args, context) do
    query = args["query"] || args[:query]
    scope = directory_scope(context)
    team = current_team(context)

    {workspaces, teams, agents} = snapshot(context, scope, team)
    core = Map.get(context.options || %{}, :core)

    {work_items, comments} =
      if core do
        {:ok, rows} =
          Omunculus.EventCore.transaction(core, fn conn ->
            ctx = %{context | options: Map.put(context.options, :conn, conn)}
            {open_work_items(ctx, scope, team, query), comment_results(ctx, scope, team, query)}
          end)

        rows
      else
        {open_work_items(context, scope, team, query),
         comment_results(context, scope, team, query)}
      end

    body =
      Jason.encode!(%{
        "scope" => scope,
        "workspaces" => workspaces,
        "teams" => teams,
        "agents" => agents,
        "open_work_items" => work_items,
        "comments" => comments
      })

    {:ok, body, context}
  end

  defp snapshot(context, scope, team) do
    opts = context.options || %{}
    tool_opts = Context.tool_options(context, name())

    workspaces = lookup(opts, tool_opts, :workspaces) || %{}
    teams = lookup(opts, tool_opts, :teams) || %{}
    agents = lookup(opts, tool_opts, :agents) || %{}

    case scope do
      "session" ->
        {map_keys(workspaces), map_keys(teams), agents_snapshot(agents, teams)}

      _ ->
        team_names =
          if is_binary(team) and team != "" do
            [team]
          else
            []
          end

        ws_names =
          Enum.filter(map_keys(workspaces), fn ws ->
            ws == opts[:workspace_id]
          end)

        filtered_teams =
          teams
          |> Enum.filter(fn {name, _} -> to_string(name) in team_names end)
          |> Map.new()

        {ws_names, map_keys(filtered_teams), agents_snapshot(agents, filtered_teams)}
    end
  end

  defp open_work_items(context, scope, team, query) do
    with conn when not is_nil(conn) <- conn(context) do
      rows =
        Store.query(
          conn,
          """
          SELECT work_item_id, workspace_id, instruction, status, state
          FROM WORK_ITEMS
          WHERE status != 'completed'
          ORDER BY work_item_id
          """,
          []
        )

      rows
      |> Enum.map(fn
        [wi, ws, instruction, status, state] ->
          %{
            "work_item_id" => wi,
            "workspace_id" => ws,
            "instruction" => instruction,
            "status" => status,
            "state" => state
          }

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> filter_scope(context, scope, team)
      |> filter_query(query)
    else
      _ -> []
    end
  end

  defp comment_results(context, scope, team, query) do
    with conn when not is_nil(conn) <- conn(context) do
      rows =
        Store.query(
          conn,
          """
          SELECT work_item_id, kind, body
          FROM COMMENTS
          ORDER BY work_item_id, last_sequence
          """,
          []
        )

      rows
      |> Enum.map(fn
        [wi, kind, body] -> %{"work_item_id" => wi, "kind" => kind, "body" => body}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> filter_scope(context, scope, team)
      |> filter_query(query)
    else
      _ -> []
    end
  end

  defp filter_scope(items, context, scope, team) do
    opts = context.options || %{}

    source = %{
      "directory_scope" => scope,
      "team" => team,
      "workspace" => opts[:workspace_id],
      "session_id" => opts[:session_id]
    }

    Enum.filter(items, fn item ->
      case Omunculus.Discovery.work_item(conn(context), item["work_item_id"]) do
        nil -> false
        target -> Omunculus.Discovery.visible?(source, target)
      end
    end)
  end

  defp filter_query(items, nil), do: items
  defp filter_query(items, ""), do: items

  defp filter_query(items, query) when is_binary(query) do
    down = String.downcase(query)

    Enum.filter(items, fn item ->
      item
      |> Map.values()
      |> Enum.any?(fn
        value when is_binary(value) -> String.contains?(String.downcase(value), down)
        _ -> false
      end)
    end)
  end

  defp directory_scope(context) do
    opts = context.options || %{}
    tool_opts = Context.tool_options(context, name())
    lookup(opts, tool_opts, :directory_scope) || "subtree"
  end

  defp current_team(context) do
    opts = context.options || %{}
    tool_opts = Context.tool_options(context, name())
    lookup(opts, tool_opts, :team)
  end

  defp conn(context) do
    opts = context.options || %{}
    tool_opts = Context.tool_options(context, name())
    lookup(opts, tool_opts, :conn) || Map.get(opts, :conn)
  end

  defp lookup(opts, tool_opts, key) do
    Map.get(tool_opts, key) || Map.get(tool_opts, to_string(key)) ||
      Map.get(opts, key) || Map.get(opts, to_string(key))
  end

  defp map_keys(map) when is_map(map), do: Enum.map(map, fn {k, _} -> to_string(k) end)
  defp map_keys(_), do: []

  defp agents_snapshot(agents, teams) do
    Enum.map(teams, fn {team_name, team_cfg} ->
      lead = team_cfg[:lead] || team_cfg["lead"]
      members = team_cfg[:members] || team_cfg["members"] || []

      %{
        "team" => to_string(team_name),
        "lead" => lead,
        "members" => members,
        "prompts" =>
          Enum.map(Enum.uniq([lead | members]), fn agent ->
            cfg = Map.get(agents, agent) || Map.get(agents, String.to_atom(agent)) || %{}

            %{
              "agent" => agent,
              "prompt" => cfg[:prompt] || cfg["prompt"]
            }
          end)
      }
    end)
  end
end
