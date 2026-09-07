defmodule Omunculus.Tools.Workspaces do
  @moduledoc false
  @behaviour Omunculus.Tool

  alias Omunculus.Tool.Context

  @impl true
  def name, do: "workspaces"

  @impl true
  def schema do
    %{
      "name" => "workspaces",
      "description" =>
        "List workspaces attached to this session with their roots, teams, and team leads.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def call(_args, context) do
    {workspaces, teams, agents} = snapshot(context)

    body =
      if map_size(workspaces) == 0 do
        "No workspaces attached."
      else
        format_workspaces(workspaces, teams, agents)
      end

    {:ok, body, context}
  end

  defp snapshot(context) do
    opts = context.options || %{}
    tool_opts = Context.tool_options(context, name())

    {lookup(opts, tool_opts, :workspaces) || %{}, lookup(opts, tool_opts, :teams) || %{},
     lookup(opts, tool_opts, :agents) || %{}}
  end

  defp lookup(opts, tool_opts, key) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) ||
      Map.get(tool_opts, key) || Map.get(tool_opts, Atom.to_string(key))
  end

  defp format_workspaces(workspaces, teams, agents) do
    workspaces
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.map_join("\n", fn {ws_name, ws_config} ->
      ws = normalize_map(ws_config)
      roots = ws[:roots] || ws["roots"] || []
      team_names = ws[:teams] || ws["teams"] || []

      header =
        "workspace #{ws_name} roots=#{Enum.join(roots, ",")} teams=#{Enum.join(team_names, ",")}"

      team_lines =
        Enum.map(team_names, fn team_name ->
          team = team_config(teams, team_name)
          lead = team[:lead] || team["lead"] || "?"

          case lead_prompt(agents, lead) do
            nil -> "  team #{team_name} lead=#{lead}"
            prompt -> "  team #{team_name} lead=#{lead} prompt=#{prompt}"
          end
        end)

      Enum.join([header | team_lines], "\n")
    end)
  end

  defp team_config(teams, team_name) do
    teams
    |> Map.get(team_name)
    |> case do
      nil -> Map.get(teams, to_string(team_name)) || %{}
      team -> team
    end
    |> normalize_map()
  end

  defp lead_prompt(agents, _lead) when map_size(agents) == 0, do: nil

  defp lead_prompt(agents, lead) do
    agent = Map.get(agents, lead) || Map.get(agents, to_string(lead))

    case normalize_map(agent) do
      %{prompt: prompt} when is_binary(prompt) -> prompt
      %{"prompt" => prompt} when is_binary(prompt) -> prompt
      _ -> nil
    end
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}
end
